/// `execution_logic` 模組是 LP Guardian 協議的執行引擎。
/// 它由 Keepers 觸發，負責原子性地執行止損和對沖等保護策略。
/// 此模組協調了多個內部模組（position_manager, virtual_tracker, risk_calculator, gas_tank）
/// 以及外部協議（Tapp Exchange, Echo Protocol）的交互，確保策略執行的安全性、
/// 原子性和準確性。
module lp_guardian::execution_logic {
    use std::option::{Self, Option};
    use std::signer;
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::type_info::{Self, TypeInfo};
    use aptos_std::table::{Self, Table};

    // 內部依賴
    use lp_guardian::position_manager::{Self, Position, PositionStore, HedgeInfo};
    use lp_guardian::virtual_tracker::{Self, HedgeSnapshot};
    use lp_guardian::risk_calculator;
    use lp_guardian::gas_tank::{Self, GasTank};
    use lp_guardian::errors;
    use lp_guardian::price_oracle;

    // 外部協議依賴 (假設的 API)
    use tapp_exchange::router as tapp_router;
    use echo_protocol::lending_pool as echo_lending;
    use echo_protocol::account as echo_account;

    // ======== Constants ========

    const MIN_TIME_BETWEEN_OPS: u64 = 3600; // 1小時
    const STRATEGY_STOP_LOSS: u8 = 1;
    const STRATEGY_HEDGE: u8 = 2;
    const STRATEGY_HYBRID: u8 = 3;
    const STATUS_ACTIVE: u8 = 1;
    const STATUS_PROTECTED: u8 = 2;
    const DEFAULT_HEDGE_RATIO_BPS: u64 = 7500; // 75%
    const BPS_SCALE: u64 = 10000;

    /// 健康因子閾值
    const HF_GREEN: u128 = 1_500_000_000_000_000_000;  // 1.5
    const HF_YELLOW: u128 = 1_300_000_000_000_000_000; // 1.3
    const HF_ORANGE: u128 = 1_150_000_000_000_000_000; // 1.15

    /// 健康度監控決策
    const HF_ACTION_NONE: u8 = 0;
    const HF_ACTION_WARN: u8 = 1;
    const HF_ACTION_REDUCE: u8 = 2;
    const HF_ACTION_EMERGENCY_CLOSE: u8 = 3;

    // ======== Structs ========

    /// 健康因子檢查結果
    struct HealthFactorAction has copy, drop {
        action_type: u8,
        param: u64, // e.g., reduction percentage
    }

    // ======== Events ========

    #[event]
    struct ProtectionExecuted has drop, store {
        position_id: u64,
        owner: address,
        execution_type: u8,
        current_il_bps: u64,
        gas_cost_usd: u64,
        executor: address,
        timestamp: u64,
    }

    #[event]
    struct HedgeRebalanced has drop, store {
        position_id: u64,
        old_borrow_amount: u64,
        new_borrow_amount: u64,
        new_health_factor: u128,
        timestamp: u64,
    }

    #[event]
    struct HealthFactorAlert has drop, store {
        position_id: u64,
        health_factor: u128,
        alert_level: u8, // 1=Yellow, 2=Orange, 3=Red
        action_taken: u8,
        timestamp: u64,
    }

    // ======== Public Entry Functions (Called by Keepers) ========

    public entry fun try_execute_protection(
        keeper: &signer,
        position_id: u64,
    ) acquires PositionStore, virtual_tracker::VirtualPositionStore {
        let keeper_addr = signer::address_of(keeper);
        assert!(position_manager::is_authorized_keeper(keeper_addr), errors::E_NOT_AUTHORIZED_KEEPER);

        let position = position_manager::get_position(position_id);
        let now = timestamp::now_seconds();

        if (!position.is_active || position.current_status != STATUS_ACTIVE) { return };
        if (now < position.last_operation_time + MIN_TIME_BETWEEN_OPS) { return };

        let (price_x_vs_y, _) = price_oracle::get_verified_price(position.pool_address);
        let initial_price_x_vs_y = (position.initial_price_x as u128) * 100_000_000 / (position.initial_price_y as u128);
        let current_il_bps = risk_calculator::calculate_il((initial_price_x_vs_y as u64), price_x_vs_y);

        let success = false;
        let gas_cost_usd = 0;

        if (current_il_bps >= position.il_threshold_bps) {
            gas_cost_usd = estimate_gas_cost_usd(position.strategy_type);
            let gas_tank_ref = position_manager::borrow_position_gas_tank(position_id);

            if (gas_tank::get_balance_usd(gas_tank_ref) >= gas_cost_usd) {
                if (position.strategy_type == STRATEGY_STOP_LOSS) {
                    execute_stop_loss_internal(keeper_addr, position_id, current_il_bps, gas_cost_usd, price_x_vs_y);
                    success = true;
                } else if (position.strategy_type == STRATEGY_HEDGE || position.strategy_type == STRATEGY_HYBRID) {
                    execute_hedge_internal(keeper_addr, position_id, current_il_bps, gas_cost_usd, price_x_vs_y);
                    success = true;
                };
            } else {
                gas_tank::emit_low_gas_warning(gas_tank_ref, position_id);
            };
        };

        position_manager::record_keeper_execution(keeper_addr, success, if (success) { gas_cost_usd } else { 0 });
    }

    // ======== Internal Execution Logic ========

    fun execute_stop_loss_internal(
        keeper_addr: address,
        position_id: u64,
        current_il_bps: u64,
        gas_cost_usd: u64,
        current_price_x_vs_y: u64,
    ) acquires PositionStore, virtual_tracker::VirtualPositionStore {
        let position = position_manager::get_position(position_id);

        virtual_tracker::create_stop_loss_snapshot(
            position.owner, position_id, current_price_x_vs_y, current_il_bps, position.initial_lp_value
        );

        // tapp_router::remove_liquidity_with_capability(...);

        let gas_tank = position_manager::borrow_position_gas_tank_mut(position_id);
        gas_tank::deduct_fee_as_protocol(gas_tank, position_id, gas_cost_usd, keeper_addr);

        position_manager::update_position_status(position_id, STATUS_PROTECTED);

        event::emit(ProtectionExecuted {
            position_id, owner: position.owner, execution_type: STRATEGY_STOP_LOSS,
            current_il_bps, gas_cost_usd, executor: keeper_addr, timestamp: timestamp::now_seconds(),
        });
    }

    fun execute_hedge_internal(
        keeper_addr: address,
        position_id: u64,
        current_il_bps: u64,
        gas_cost_usd: u64,
        price_x_vs_y: u64,
    ) acquires PositionStore, virtual_tracker::VirtualPositionStore {
        let position = position_manager::get_position(position_id);
        
        // 假設 X 是波動資產 (如 APT)，Y 是穩定幣 (如 USDC)
        let (delta_x, _) = risk_calculator::calculate_delta(
            position.initial_lp_value, position.initial_price_x, position.initial_price_y,
            5000, 5000, 100_000_000, 1_000_000
        );
        let hedge_amount = ((delta_x as u128) * (DEFAULT_HEDGE_RATIO_BPS as u128) / (BPS_SCALE as u128)) as u64;

        // echo_lending::supply_with_capability(...);
        // let actual_borrowed = echo_lending::borrow_with_capability(...);
        let actual_borrowed = hedge_amount; // 假設全部借出
        // let usdc_received = tapp_router::swap_exact_input_with_capability(...);
        let usdc_received = ((actual_borrowed as u128) * (price_x_vs_y as u128) / 100) as u64; // 價格從 1e8 -> 1e6
        // let health_factor = echo_account::get_health_factor(position.owner);
        let health_factor = 2_000000000000000000;

        let hedge_snapshot = HedgeSnapshot {
            borrowed_asset: type_info::type_of<aptos_framework::aptos_coin::AptosCoin>(),
            borrowed_amount: actual_borrowed, sold_for_stable: usdc_received,
            hedge_ratio_bps: DEFAULT_HEDGE_RATIO_BPS, health_factor,
        };

        virtual_tracker::create_hedge_snapshot(
            position.owner, position_id, price_x_vs_y, current_il_bps, position.initial_lp_value, hedge_snapshot
        );
        
        let hedge_info = HedgeInfo {
            borrowed_asset: type_info::type_of<aptos_framework::aptos_coin::AptosCoin>(),
            borrowed_amount: actual_borrowed, health_factor,
            opened_at: timestamp::now_seconds(), last_rebalance_time: timestamp::now_seconds(),
        };
        position_manager::add_hedge_info_to_position(position_id, hedge_info);

        let gas_tank = position_manager::borrow_position_gas_tank_mut(position_id);
        gas_tank::deduct_fee_as_protocol(gas_tank, position_id, gas_cost_usd, keeper_addr);

        position_manager::update_position_status(position_id, STATUS_PROTECTED);

        event::emit(ProtectionExecuted {
            position_id, owner: position.owner, execution_type: STRATEGY_HEDGE,
            current_il_bps, gas_cost_usd, executor: keeper_addr, timestamp: timestamp::now_seconds(),
        });
    }

    // ======== Hedge Management Functions ========

    public entry fun check_and_manage_hedge(
        keeper: &signer,
        position_id: u64,
    ) acquires PositionStore {
        let keeper_addr = signer::address_of(keeper);
        assert!(position_manager::is_authorized_keeper(keeper_addr), errors::E_NOT_AUTHORIZED_KEEPER);

        let action = check_hedge_health_internal(position_id);

        if (action.action_type == HF_ACTION_REDUCE) {
            rebalance_hedge_internal(keeper_addr, position_id, action.param);
        } else if (action.action_type == HF_ACTION_EMERGENCY_CLOSE) {
            emergency_close_hedge_internal(keeper_addr, position_id);
        };
    }

    fun check_hedge_health_internal(position_id: u64): HealthFactorAction {
        let position = position_manager::get_position(position_id);
        assert!(option::is_some(&position.hedge_info), errors::E_POSITION_NOT_ACTIVE);

        // let current_hf = echo_account::get_health_factor(position.owner);
        let current_hf = 1_200_000_000_000_000_000; // 模擬 HF 降至 1.2

        let (action_type, param, alert_level) = if (current_hf > HF_GREEN) {
            (HF_ACTION_NONE, 0, 0)
        } else if (current_hf > HF_YELLOW) {
            (HF_ACTION_WARN, 0, 1)
        } else if (current_hf > HF_ORANGE) {
            (HF_ACTION_REDUCE, 30, 2) // 減少 30%
        } else {
            (HF_ACTION_EMERGENCY_CLOSE, 100, 3) // 關閉 100%
        };

        if (alert_level > 0) {
            event::emit(HealthFactorAlert {
                position_id, health_factor: current_hf, alert_level,
                action_taken: action_type, timestamp: timestamp::now_seconds(),
            });
        };

        HealthFactorAction { action_type, param }
    }

    fun rebalance_hedge_internal(
        keeper_addr: address,
        position_id: u64,
        reduction_percent: u64
    ) acquires PositionStore {
        let position = position_manager::get_position(position_id);
        let hedge_info = option::extract(&mut position_manager::borrow_position_mut(position_id).hedge_info);

        let repay_amount = ((hedge_info.borrowed_amount as u128) * (reduction_percent as u128) / 100) as u64;

        // 實際執行還款
        // 1. 購買需要還款的資產
        // 2. 呼叫 echo_lending::repay_with_capability(...)

        let old_borrow_amount = hedge_info.borrowed_amount;
        hedge_info.borrowed_amount = old_borrow_amount - repay_amount;
        // let new_hf = echo_account::get_health_factor(position.owner);
        let new_hf = 1_400_000_000_000_000_000; // 假設 HF 回升至 1.4
        hedge_info.health_factor = new_hf;
        hedge_info.last_rebalance_time = timestamp::now_seconds();

        event::emit(HedgeRebalanced {
            position_id, old_borrow_amount, new_borrow_amount: hedge_info.borrowed_amount, new_health_factor: new_hf,
            timestamp: timestamp::now_seconds(),
        });
        
        position_manager::update_position_hedge_info(position_id, hedge_info);
    }
    
    fun emergency_close_hedge_internal(keeper_addr: address, position_id: u64) acquires PositionStore {
        let position = position_manager::get_position(position_id);
        let hedge_info = option::extract(&mut position_manager::borrow_position_mut(position_id).hedge_info);

        // 1. 還清所有債務
        // echo_lending::repay_with_capability(..., u64::max_value());
        // 2. 取回所有抵押品
        // echo_lending::withdraw_with_capability(...);

        // 移除對沖資訊，倉位恢復 Active
        position_manager::remove_hedge_info_from_position(position_id);
        position_manager::update_position_status(position_id, STATUS_ACTIVE);
    }

    // ======== Internal Helper Functions ========

    fun estimate_gas_cost_usd(strategy_type: u8): u64 {
        if (strategy_type == STRATEGY_STOP_LOSS) {
            300_000 // $0.3
        } else if (strategy_type == STRATEGY_HEDGE) {
            800_000 // $0.8
        } else {
            500_000 // $0.5
        }
    }
}


