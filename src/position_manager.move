/// `position_manager` 是 LP Guardian 協議的核心模組。
/// 它負責管理所有保護倉位的生命週期，維護協議的全域配置和狀態，
/// 並處理管理員和 Keeper 的權限。
module lp_guardian::position_manager {
    use std::signer;
    use std::vector;
    use std::option::{Self, Option};
    use std::string::String;
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::table::{Self, Table};
    use aptos_std::type_info::{Self, TypeInfo};
    use lp_guardian::errors;
    use lp_guardian::gas_tank::{Self, GasTank};

    // ======== Constants ========

    /// 倉位狀態碼
    const STATUS_ACTIVE: u8 = 1;
    const STATUS_PROTECTED: u8 = 2;
    const STATUS_LIQUIDATED: u8 = 3;
    const STATUS_DISABLED: u8 = 4;

    /// 策略類型
    const STRATEGY_STOP_LOSS: u8 = 1;
    const STRATEGY_HEDGE: u8 = 2;
    const STRATEGY_HYBRID: u8 = 3;

    /// 再平衡配置
    const PROFILE_CONSERVATIVE: u8 = 1;
    const PROFILE_BALANCED: u8 = 2;
    const PROFILE_AGGRESSIVE: u8 = 3;

    /// IL 閾值上下限 (基點)
    const MIN_IL_THRESHOLD_BPS: u64 = 200;  // 2%
    const MAX_IL_THRESHOLD_BPS: u64 = 2000; // 20%

    /// 預設全域參數
    const DEFAULT_PERFORMANCE_FEE_BPS: u64 = 2500; // 25%
    const DEFAULT_MAX_PRICE_DEVIATION_BPS: u64 = 500; // 5%

    // ======== Structs ========

    /// [架構重構] 用於儲存所有 Position 的中心化容器
    struct PositionStore has key {
        positions: Table<u64, Position>,
        /// [新增] LP Token ID 到 Position ID 的索引，確保唯一性
        lp_token_to_position_id: Table<u64, u64>,
    }

    /// 核心倉位數據結構
    struct Position has store {
        owner: address,
        position_id: u64,
        pool_address: address,
        lp_token_id: u64,
        initial_token_x: u64,
        initial_token_y: u64,
        initial_price_x: u64,
        initial_price_y: u64,
        initial_lp_value: u64,
        il_threshold_bps: u64,
        strategy_type: u8,
        rebalance_profile: u8,
        gas_tank: GasTank,
        keeper_authorized: bool,
        is_active: bool,
        current_status: u8,
        last_check_time: u64,
        last_operation_time: u64,
        operation_count: u64,
        created_at: u64,
        updated_at: u64,
    }

    /// 用戶倉位註冊表，儲存在用戶帳戶下，作為索引
    struct PositionRegistry has key {
        position_ids: vector<u64>,
    }

    /// 全域配置和統計數據
    struct GlobalConfig has key {
        admin: address,
        pending_admin: Option<address>,
        min_il_threshold_bps: u64,
        max_il_threshold_bps: u64,
        performance_fee_bps: u64,
        max_price_deviation_bps: u64,
        keeper_registry: Table<address, KeeperInfo>,
        total_positions: u64,
        active_positions: u64,
        total_protected_value: u64,
        total_performance_fees_collected: u64,
        is_paused: bool,
        next_position_id: u64,
    }

    /// Keeper 資訊和統計數據
    struct KeeperInfo has store {
        keeper_address: address,
        staked_amount: u64,
        total_executions: u64,
        successful_executions: u64,
        failed_executions: u64,
        total_gas_earned: u64,
        is_active: bool,
        registered_at: u64,
        last_activity: u64,
    }

    // ======== Events ========

    #[event]
    struct PositionRegistered has drop, store {
        owner: address,
        position_id: u64,
        pool_address: address,
        lp_token_id: u64,
        il_threshold_bps: u64,
        strategy_type: u8,
        timestamp: u64,
    }

    #[event]
    struct PositionUpdated has drop, store {
        owner: address,
        position_id: u64,
        il_threshold_bps: Option<u64>,
        rebalance_profile: Option<u8>,
        timestamp: u64,
    }

    #[event]
    struct PositionDisabled has drop, store {
        owner: address,
        position_id: u64,
        timestamp: u64,
    }

    #[event]
    struct PositionStatusChanged has drop, store {
        owner: address,
        position_id: u64,
        old_status: u8,
        new_status: u8,
        timestamp: u64,
    }

    #[event]
    struct KeeperRegistered has drop, store {
        keeper_address: address,
        staked_amount: u64,
        timestamp: u64,
    }
    
    #[event]
    struct KeeperDeregistered has drop, store {
        keeper_address: address,
        timestamp: u64,
    }

    #[event]
    struct EmergencyPauseTriggered has drop, store {
        admin: address,
        reason: String,
        timestamp: u64,
    }
    
    #[event]
    struct SystemResumed has drop, store {
        admin: address,
        timestamp: u64,
    }

    // ======== Initialization Functions ========

    public entry fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<GlobalConfig>(admin_addr), errors::E_INITIALIZATION_FAILED);
        assert!(!exists<PositionStore>(admin_addr), errors::E_INITIALIZATION_FAILED);

        move_to(admin, GlobalConfig {
            admin: admin_addr,
            pending_admin: option::none(),
            min_il_threshold_bps: MIN_IL_THRESHOLD_BPS,
            max_il_threshold_bps: MAX_IL_THRESHOLD_BPS,
            performance_fee_bps: DEFAULT_PERFORMANCE_FEE_BPS,
            max_price_deviation_bps: DEFAULT_MAX_PRICE_DEVIATION_BPS,
            keeper_registry: table::new(),
            total_positions: 0,
            active_positions: 0,
            total_protected_value: 0,
            total_performance_fees_collected: 0,
            is_paused: false,
            next_position_id: 1,
        });

        move_to(admin, PositionStore {
            positions: table::new(),
            lp_token_to_position_id: table::new(),
        });
    }

    // ======== Position Management Functions ========

    public entry fun register_position(
        user: &signer,
        pool_address: address,
        lp_token_id: u64,
        il_threshold_bps: u64,
        strategy_type: u8,
        rebalance_profile: u8,
    ) acquires GlobalConfig, PositionStore, PositionRegistry {
        let user_addr = signer::address_of(user);
        let protocol_addr = @lp_guardian;

        let config = borrow_global<GlobalConfig>(protocol_addr);
        assert!(!config.is_paused, errors::E_SYSTEM_PAUSED);

        assert!(il_threshold_bps >= config.min_il_threshold_bps && il_threshold_bps <= config.max_il_threshold_bps, errors::E_INVALID_THRESHOLD);
        assert!(strategy_type == STRATEGY_STOP_LOSS || strategy_type == STRATEGY_HEDGE || strategy_type == STRATEGY_HYBRID, errors::E_INVALID_STRATEGY_TYPE);
        assert!(rebalance_profile == PROFILE_CONSERVATIVE || rebalance_profile == PROFILE_BALANCED || rebalance_profile == PROFILE_AGGRESSIVE, errors::E_INVALID_PARAMETER);

        let position_store = borrow_global_mut<PositionStore>(protocol_addr);
        assert!(!table::contains(&position_store.lp_token_to_position_id, lp_token_id), errors::E_POSITION_ALREADY_EXISTS);

        let config_mut = borrow_global_mut<GlobalConfig>(protocol_addr);
        let position_id = config_mut.next_position_id;
        config_mut.next_position_id = position_id + 1;
        config_mut.total_positions = config_mut.total_positions + 1;
        config_mut.active_positions = config_mut.active_positions + 1;

        let (initial_token_x, initial_token_y) = get_lp_token_amounts(pool_address, lp_token_id);
        let (initial_price_x, initial_price_y) = get_current_prices(pool_address);
        let initial_lp_value = calculate_lp_value(initial_token_x, initial_token_y, initial_price_x, initial_price_y);

        let position = Position {
            owner: user_addr,
            position_id,
            pool_address,
            lp_token_id,
            initial_token_x,
            initial_token_y,
            initial_price_x,
            initial_price_y,
            initial_lp_value,
            il_threshold_bps,
            strategy_type,
            rebalance_profile,
            gas_tank: gas_tank::initialize_gas_tank(),
            keeper_authorized: true,
            is_active: true,
            current_status: STATUS_ACTIVE,
            last_check_time: timestamp::now_seconds(),
            last_operation_time: 0,
            operation_count: 0,
            created_at: timestamp::now_seconds(),
            updated_at: timestamp::now_seconds(),
        };

        table::add(&mut position_store.positions, position_id, position);
        table::add(&mut position_store.lp_token_to_position_id, lp_token_id, position_id);

        if (!exists<PositionRegistry>(user_addr)) {
            move_to(user, PositionRegistry { position_ids: vector::singleton(position_id) });
        } else {
            let registry = borrow_global_mut<PositionRegistry>(user_addr);
            vector::push_back(&mut registry.position_ids, position_id);
        };

        event::emit(PositionRegistered {
            owner: user_addr, position_id, pool_address, lp_token_id,
            il_threshold_bps, strategy_type, timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun update_position(
        user: &signer,
        position_id: u64,
        new_il_threshold: Option<u64>,
        new_rebalance_profile: Option<u8>,
    ) acquires GlobalConfig, PositionStore {
        let user_addr = signer::address_of(user);
        let protocol_addr = @lp_guardian;
        let config = borrow_global<GlobalConfig>(protocol_addr);
        assert!(!config.is_paused, errors::E_SYSTEM_PAUSED);

        let position_store = borrow_global_mut<PositionStore>(protocol_addr);
        assert!(table::contains(&position_store.positions, position_id), errors::E_POSITION_NOT_FOUND);
        let position = table::borrow_mut(&mut position_store.positions, position_id);

        assert!(position.owner == user_addr, errors::E_NOT_POSITION_OWNER);
        assert!(position.current_status == STATUS_ACTIVE || position.current_status == STATUS_PROTECTED, errors::E_POSITION_NOT_ACTIVE);

        if (option::is_some(&new_il_threshold)) {
            let threshold = *option::borrow(&new_il_threshold);
            assert!(threshold >= config.min_il_threshold_bps && threshold <= config.max_il_threshold_bps, errors::E_INVALID_THRESHOLD);
            position.il_threshold_bps = threshold;
        };
        
        if (option::is_some(&new_rebalance_profile)) {
            let profile = *option::borrow(&new_rebalance_profile);
            assert!(profile == PROFILE_CONSERVATIVE || profile == PROFILE_BALANCED || profile == PROFILE_AGGRESSIVE, errors::E_INVALID_PARAMETER);
            position.rebalance_profile = profile;
        };

        position.updated_at = timestamp::now_seconds();

        event::emit(PositionUpdated {
            owner: user_addr, position_id, il_threshold_bps: new_il_threshold,
            rebalance_profile: new_rebalance_profile, timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun disable_position(
        user: &signer,
        position_id: u64,
    ) acquires GlobalConfig, PositionStore {
        let user_addr = signer::address_of(user);
        let protocol_addr = @lp_guardian;

        let position_store = borrow_global_mut<PositionStore>(protocol_addr);
        assert!(table::contains(&position_store.positions, position_id), errors::E_POSITION_NOT_FOUND);
        let position = table::borrow_mut(&mut position_store.positions, position_id);

        assert!(position.owner == user_addr, errors::E_NOT_POSITION_OWNER);
        // TODO: Integrate with virtual_tracker to check for unsettled fees before disabling.

        let old_status = position.current_status;
        position.current_status = STATUS_DISABLED;
        position.is_active = false;
        position.keeper_authorized = false;
        position.updated_at = timestamp::now_seconds();

        // 移除 LP Token 索引，使其可以被重新註冊
        table::remove(&mut position_store.lp_token_to_position_id, position.lp_token_id);

        if (old_status == STATUS_ACTIVE || old_status == STATUS_PROTECTED) {
            let config = borrow_global_mut<GlobalConfig>(protocol_addr);
            config.active_positions = config.active_positions - 1;
        };

        event::emit(PositionDisabled { owner: user_addr, position_id, timestamp: timestamp::now_seconds() });
        event::emit(PositionStatusChanged { owner: user_addr, position_id, old_status, new_status: STATUS_DISABLED, timestamp: timestamp::now_seconds() });
    }

    // ======== Keeper Management Functions ========

    public entry fun register_keeper(
        admin: &signer,
        keeper_address: address,
        staked_amount: u64,
    ) acquires GlobalConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<GlobalConfig>(@lp_guardian);
        assert!(config.admin == admin_addr, errors::E_NOT_ADMIN);
        assert!(!table::contains(&config.keeper_registry, keeper_address), errors::E_UNAUTHORIZED); // Reuse error code

        let keeper_info = KeeperInfo {
            keeper_address, staked_amount, total_executions: 0,
            successful_executions: 0, failed_executions: 0, total_gas_earned: 0,
            is_active: true, registered_at: timestamp::now_seconds(), last_activity: timestamp::now_seconds(),
        };
        table::add(&mut config.keeper_registry, keeper_address, keeper_info);

        event::emit(KeeperRegistered { keeper_address, staked_amount, timestamp: timestamp::now_seconds() });
    }
    
    public entry fun deregister_keeper(
        admin: &signer,
        keeper_address: address,
    ) acquires GlobalConfig {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global_mut<GlobalConfig>(@lp_guardian);
        assert!(config.admin == admin_addr, errors::E_NOT_ADMIN);
        assert!(table::contains(&config.keeper_registry, keeper_address), errors::E_UNAUTHORIZED);

        // In a real scenario, this would trigger an unstaking period.
        // For simplicity, we just remove it.
        table::remove(&mut config.keeper_registry, keeper_address);
        event::emit(KeeperDeregistered { keeper_address, timestamp: timestamp::now_seconds() });
    }

    public fun record_keeper_execution(
        keeper_addr: address,
        success: bool,
        gas_earned: u64,
    ) acquires GlobalConfig {
        let config = borrow_global_mut<GlobalConfig>(@lp_guardian);
        if (table::contains(&config.keeper_registry, keeper_addr)) {
            let keeper_info = table::borrow_mut(&mut config.keeper_registry, keeper_addr);
            keeper_info.total_executions = keeper_info.total_executions + 1;
            if (success) {
                keeper_info.successful_executions = keeper_info.successful_executions + 1;
                keeper_info.total_gas_earned = keeper_info.total_gas_earned + gas_earned;
            } else {
                keeper_info.failed_executions = keeper_info.failed_executions + 1;
            };
            keeper_info.last_activity = timestamp::now_seconds();
        };
    }

    // ======== Status Update Functions ========

    public fun update_position_status(
        position_id: u64,
        new_status: u8,
    ) acquires PositionStore, GlobalConfig {
        let protocol_addr = @lp_guardian;
        let position_store = borrow_global_mut<PositionStore>(protocol_addr);
        assert!(table::contains(&position_store.positions, position_id), errors::E_POSITION_NOT_FOUND);
        let position = table::borrow_mut(&mut position_store.positions, position_id);

        let old_status = position.current_status;
        position.current_status = new_status;
        position.last_operation_time = timestamp::now_seconds();
        position.operation_count = position.operation_count + 1;
        position.updated_at = timestamp::now_seconds();

        if ((old_status == STATUS_ACTIVE || old_status == STATUS_PROTECTED) && (new_status == STATUS_DISABLED || new_status == STATUS_LIQUIDATED)) {
            position.is_active = false;
            let config = borrow_global_mut<GlobalConfig>(protocol_addr);
            if (config.active_positions > 0) {
                config.active_positions = config.active_positions - 1;
            };
        };

        event::emit(PositionStatusChanged {
            owner: position.owner, position_id, old_status, new_status, timestamp: timestamp::now_seconds(),
        });
    }

    // ======== Admin Functions ========

    public entry fun emergency_pause(admin: &signer, reason: String) acquires GlobalConfig {
        let config = borrow_global_mut<GlobalConfig>(@lp_guardian);
        assert!(config.admin == signer::address_of(admin), errors::E_NOT_ADMIN);
        assert!(!config.is_paused, errors::E_SYSTEM_PAUSED);
        
        config.is_paused = true;
        
        event::emit(EmergencyPauseTriggered {
            admin: signer::address_of(admin), reason, timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun unpause(admin: &signer) acquires GlobalConfig {
        let config = borrow_global_mut<GlobalConfig>(@lp_guardian);
        assert!(config.admin == signer::address_of(admin), errors::E_NOT_ADMIN);
        assert!(config.is_paused, errors::E_POSITION_NOT_ACTIVE); // Re-use error code
        
        config.is_paused = false;
        
        event::emit(SystemResumed { admin: signer::address_of(admin), timestamp: timestamp::now_seconds() });
    }

    // ======== View Functions ========

    public fun get_position(position_id: u64): &Position acquires PositionStore {
        let position_store = borrow_global<PositionStore>(@lp_guardian);
        assert!(table::contains(&position_store.positions, position_id), errors::E_POSITION_NOT_FOUND);
        table::borrow(&position_store.positions, position_id)
    }

    public fun borrow_position_gas_tank_mut(position_id: u64): &mut GasTank acquires PositionStore {
        let position_store = borrow_global_mut<PositionStore>(@lp_guardian);
        assert!(table::contains(&position_store.positions, position_id), errors::E_POSITION_NOT_FOUND);
        let position = table::borrow_mut(&mut position_store.positions, position_id);
        &mut position.gas_tank
    }

    public fun get_user_positions(owner: address): vector<u64> acquires PositionRegistry {
        if (exists<PositionRegistry>(owner)) {
            *&borrow_global<PositionRegistry>(owner).position_ids
        } else {
            vector::empty()
        }
    }

    public fun is_authorized_keeper(keeper_addr: address): bool acquires GlobalConfig {
        let config = borrow_global<GlobalConfig>(@lp_guardian);
        if (table::contains(&config.keeper_registry, keeper_addr)) {
            table::borrow(&config.keeper_registry, keeper_addr).is_active
        } else {
            false
        }
    }

    // ======== Internal Helper Functions ========

    fun get_lp_token_amounts(_pool: address, _token_id: u64): (u64, u64) {
        // Placeholder - Production: Call Tapp Exchange contract
        (1000000000, 1000000000)
    }

    fun get_current_prices(_pool: address): (u64, u64) {
        // Placeholder - Production: Call price_oracle module
        (1000000000, 100000000)
    }

    fun calculate_lp_value(token_x: u64, token_y: u64, price_x: u64, price_y: u64): u64 {
        // Note: Assumes token amounts and prices have compatible decimals
        let value_x = (token_x as u128) * (price_x as u128) / 100000000;
        let value_y = (token_y as u128) * (price_y as u128) / 100000000;
        ((value_x + value_y) / 100) as u64 // Convert to USD 1e6 scale
    }
}


