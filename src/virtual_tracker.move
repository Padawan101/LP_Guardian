/// `virtual_tracker` 模組是 LP Guardian 的核心計費引擎。
/// 它通過創建保護操作的「反事實」快照（虛擬倉位），來精確計算
/// 如果沒有協議保護，用戶將會面臨的無常損失。基於此計算出的
/// 「避免的損失」，協議可以公平、透明地收取績效費。
module lp_guardian::virtual_tracker {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info::{Self, TypeInfo};

    use lp_guardian::errors;
    use lp_guardian::risk_calculator;
    use lp_guardian::position_manager;
    use lp_guardian::gas_tank::{Self, GasTank};

    // ======== Constants ========

    /// 結算週期：24 小時（秒）
    const SETTLEMENT_PERIOD_SECONDS: u64 = 86400; // 24 * 60 * 60

    /// 保護類型
    const PROTECTION_TYPE_STOP_LOSS: u8 = 1;
    const PROTECTION_TYPE_HEDGE: u8 = 2;

    /// 縮放因子
    const BPS_SCALE: u64 = 10000;

    // ======== Structs ========

    /// 對沖倉位在保護觸發時的快照
    struct HedgeSnapshot has store, drop, copy {
        borrowed_asset: TypeInfo,
        borrowed_amount: u64,
        sold_for_stable: u64,
        hedge_ratio_bps: u64,
        health_factor: u64,
    }

    /// [架構重構] 用於儲存所有 VirtualPosition 的中心化容器
    struct VirtualPositionStore has key {
        positions: Table<u64, VirtualPosition>,
    }

    /// 虛擬倉位，用於追蹤反事實表現
    struct VirtualPosition has store {
        position_id: u64,
        owner: address,
        // T0 快照 (保護觸發時)
        snapshot_time: u64,
        initial_price_x_vs_y: u64, // T0 時 x 相對於 y 的價格 (scaled 1e8)
        initial_lp_value: u64,
        initial_il_bps: u64,
        // 保護操作資訊
        protection_type: u8,
        hedge_details: Option<HedgeSnapshot>,
        // T1 結算數據 (24 小時後)
        settlement_time: Option<u64>,
        final_virtual_il_bps: Option<u64>,
        avoided_loss: Option<u64>,
        performance_fee: Option<u64>,
        is_settled: bool,
    }

    /// [移除] 不再需要 PerformanceHistory，歷史記錄通過事件由鏈下索引
    // struct PerformanceHistory has key { ... }

    // ======== Events ========

    #[event]
    struct VirtualPositionCreated has drop, store {
        owner: address,
        position_id: u64,
        protection_type: u8,
        initial_il_bps: u64,
        initial_lp_value: u64,
        timestamp: u64,
    }

    #[event]
    struct PerformanceFeeSettled has drop, store {
        position_id: u64,
        virtual_il_bps: u64,
        avoided_loss: u64,
        performance_fee: u64,
        timestamp: u64,
    }

    #[event]
    struct NoPerformanceFee has drop, store {
        position_id: u64,
        reason: String,
        timestamp: u64,
    }

    // ======== Initialization ========

    /// 由 `position_manager::initialize` 呼叫，創建中心化儲存資源
    public(friend) fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<VirtualPositionStore>(admin_addr), errors::E_INITIALIZATION_FAILED);

        move_to(admin, VirtualPositionStore {
            positions: table::new(),
        });
    }

    // ======== Public Functions (Called by other modules) ========

    /// [架構重構] 創建止損保護的虛擬快照
    /// 應由 `execution_logic` 在執行止損操作時呼叫
    public(friend) fun create_stop_loss_snapshot(
        position_owner: address,
        position_id: u64,
        initial_price_x_vs_y: u64,
        initial_il_bps: u64,
        initial_lp_value: u64,
    ) acquires VirtualPositionStore {
        let store = borrow_global_mut<VirtualPositionStore>(@lp_guardian);
        assert!(!table::contains(&store.positions, position_id), errors::E_VIRTUAL_POSITION_NOT_FOUND);

        let vpos = VirtualPosition {
            position_id,
            owner: position_owner,
            snapshot_time: timestamp::now_seconds(),
            initial_price_x_vs_y,
            initial_il_bps,
            initial_lp_value,
            protection_type: PROTECTION_TYPE_STOP_LOSS,
            hedge_details: option::none(),
            settlement_time: option::none(),
            final_virtual_il_bps: option::none(),
            avoided_loss: option::none(),
            performance_fee: option::none(),
            is_settled: false,
        };

        table::add(&mut store.positions, position_id, vpos);

        event::emit(VirtualPositionCreated {
            owner: position_owner, position_id, protection_type: PROTECTION_TYPE_STOP_LOSS,
            initial_il_bps, initial_lp_value, timestamp: timestamp::now_seconds(),
        });
    }

    // [架構重構] 創建對沖保護的虛擬快照
    // 應由 `execution_logic` 在執行對沖操作時呼叫
    public(friend) fun create_hedge_snapshot(
        position_owner: address,
        position_id: u64,
        initial_price_x_vs_y: u64,
        initial_il_bps: u64,
        initial_lp_value: u64,
        hedge_snapshot: HedgeSnapshot,
    ) acquires VirtualPositionStore {
        let store = borrow_global_mut<VirtualPositionStore>(@lp_guardian);
        assert!(!table::contains(&store.positions, position_id), errors::E_VIRTUAL_POSITION_NOT_FOUND);

        let vpos = VirtualPosition {
            position_id,
            owner: position_owner,
            snapshot_time: timestamp::now_seconds(),
            initial_price_x_vs_y,
            initial_il_bps,
            initial_lp_value,
            protection_type: PROTECTION_TYPE_HEDGE,
            hedge_details: option::some(hedge_snapshot),
            settlement_time: option::none(),
            final_virtual_il_bps: option::none(),
            avoided_loss: option::none(),
            performance_fee: option::none(),
            is_settled: false,
        };
        table::add(&mut store.positions, position_id, vpos);
        event::emit(VirtualPositionCreated { /* ... */ });
    }

    // ======== Public Entry Functions (Called by Keepers) ========

    /// /// 結算一個虛擬倉位的績效費。
    /// 由 Keeper 在虛擬倉位創建 24 小時後呼叫。
    /// @param keeper: Keeper 的簽名者，用於授權交易。
    /// @param position_id: 要結算的倉位 ID。
    /// @param current_price_x_vs_y: T1 時刻 x 相對於 y 的當前價格 (scaled 1e8)。
    public entry fun settle_performance_fee(
        keeper: &signer,
        position_id: u64,
        current_price_x_vs_y: u64,
    ) acquires VirtualPositionStore, position_manager::PositionStore {
        // TODO: Add keeper authorization check from position_manager
        let protocol_addr = @lp_guardian;
        let store = borrow_global_mut<VirtualPositionStore>(protocol_addr);
        assert!(table::contains(&store.positions, position_id), errors::E_VIRTUAL_POSITION_NOT_FOUND);

        let vpos = table::borrow_mut(&mut store.positions, position_id);
        assert!(!vpos.is_settled, errors::E_ALREADY_SETTLED);

        let now = timestamp::now_seconds();
        assert!(now >= vpos.snapshot_time + SETTLEMENT_PERIOD_SECONDS, errors::E_SETTLEMENT_NOT_DUE);

        let virtual_il_bps = risk_calculator::calculate_il(vpos.initial_price_x_vs_y, current_price_x_vs_y);

        let avoided_loss = if (virtual_il_bps > vpos.initial_il_bps) {
            let il_difference_bps = virtual_il_bps - vpos.initial_il_bps;
            ((vpos.initial_lp_value as u128) * (il_difference_bps as u128) / (BPS_SCALE as u128)) as u64
        } else {
            0
        };
        
        // [關鍵修正] 獲取績效費率並計算費用
        let fee_bps = position_manager::get_performance_fee_bps();
        let performance_fee = ((avoided_loss as u128) * (fee_bps as u128) / (BPS_SCALE as u128)) as u64;

        // 更新虛擬倉位狀態
        vpos.settlement_time = option::some(now);
        vpos.final_virtual_il_bps = option::some(virtual_il_bps);
        vpos.avoided_loss = option::some(avoided_loss);
        vpos.performance_fee = option::some(performance_fee);
        vpos.is_settled = true;

        if (performance_fee > 0) {
            // [關鍵修正] 從 Gas Tank 中實際扣除績效費
            let gas_tank = position_manager::borrow_position_gas_tank_mut(position_id);
            // 假設 keeper signer 可以代理用戶 signer 進行扣款，或 keeper 支付後從獎勵池報銷
            // 這裡簡化為 keeper 代付
            gas_tank::deduct_with_fallback(keeper, gas_tank, position_id, performance_fee, 0, 5); // 5 = SettleFee

            event::emit(PerformanceFeeSettled {
                position_id, virtual_il_bps, avoided_loss, performance_fee, timestamp: now,
            });
        } else {
            event::emit(NoPerformanceFee {
                position_id, reason: String::utf8(b"No value created - IL improved or unchanged"), timestamp: now,
            });
        }
        
        // 結算後，可以從 Table 中移除以節省狀態空間
        table::remove(&mut store.positions, position_id);
    }

    // ======== View Functions ========

    /// /// 檢查一個虛擬倉位是否存在且已到結算時間。
    /// @param position_id: 要檢查的倉位 ID。
    /// @return: 如果可以結算，返回 `true`。
    public fun is_ready_for_settlement(position_id: u64): bool acquires VirtualPositionStore {
        let store = borrow_global<VirtualPositionStore>(@lp_guardian);
        if (!table::contains(&store.positions, position_id)) {
            return false
        };

        let vpos = table::borrow(&store.positions, position_id);
        if (vpos.is_settled) {
            return false
        };

        timestamp::now_seconds() >= vpos.snapshot_time + SETTLEMENT_PERIOD_SECONDS
    }

    /// /// 獲取一個用戶所有未結算的虛擬倉位 ID。
    /// 注意：此函數有 O(n) 的複雜度，應謹慎使用或由鏈下服務替代。
    /// @param owner: 用戶地址。
    /// @return: 一個包含所有未結算倉位 ID 的向量。
    public fun get_unsettled_positions(owner: address): vector<u64> acquires position_manager::PositionRegistry, VirtualPositionStore {
        let unsettled = vector::empty<u64>();
        if (position_manager::has_positions(owner)) {
            let ids = position_manager::get_user_positions(owner);
            let store = borrow_global<VirtualPositionStore>(@lp_guardian);
            let i = 0;
            let len = vector::length(&ids);
            while (i < len) {
                let id = *vector::borrow(&ids, i);
                if (table::contains(&store.positions, id)) {
                    let vpos = table::borrow(&store.positions, id);
                    if (!vpos.is_settled) {
                        vector::push_back(&mut unsettled, id);
                    };
                };
                i = i + 1;
            };
        };
        unsettled
    }
}

