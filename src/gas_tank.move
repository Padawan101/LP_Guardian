/// 這個模組負責管理每個保護倉位的 Gas Tank，處理多幣種的充值、
/// 費用扣除、餘額警告和充值推薦。
/// 它整合了外部預言機來確保價格的準確性，並將所有收取的費用
/// 安全地轉移到協議金庫。
module lp_guardian::gas_tank {
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin as APT;
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use lp_guardian::errors;

    // --- 外部模組依賴 ---
    // 在實際開發中，需要替換為真實的模組路徑。
    // 這裡我們使用佔位符來代表這些外部依賴。
    use lp_guardian::price_oracle;
    use lp_guardian::tapp_points::{Self, TappPoints};
    // 假設 USDC 是一個已在生態中註冊的代幣類型
    use some_protocol::usdc::USDC;

    // ==============================
    // Constants
    // ==============================

    /// 協議金庫地址，用於接收所有費用
    const TREASURY_ADDRESS: address = @0xLP_GUARDIAN_TREASURY;

    /// 支付代幣類型枚舉
    const PAYMENT_TYPE_TAPP_POINTS: u8 = 1;
    const PAYMENT_TYPE_APT: u8 = 2;
    const PAYMENT_TYPE_USDC: u8 = 3;

    /// 單次充值上限
    const MAX_SINGLE_REFILL_POINTS: u64 = 10000;
    const MAX_SINGLE_REFILL_APT: u64 = 10_00000000; // 10 APT
    const MAX_SINGLE_REFILL_USDC: u64 = 1000_000000; // 1000 USDC

    /// 累計餘額上限
    const MAX_BALANCE_POINTS: u64 = 50000;
    const MAX_BALANCE_APT: u64 = 50_00000000; // 50 APT
    const MAX_BALANCE_USDC: u64 = 5000_000000; // 5000 USDC

    /// 預設低餘額警告閾值 (30%)
    const DEFAULT_LOW_BALANCE_THRESHOLD_BPS: u64 = 3000;

    /// Tapp Points 支付的折扣等級
    const TIER_1_STAKED_THRESHOLD: u64 = 1000;
    const TIER_2_STAKED_THRESHOLD: u64 = 5000;
    const TIER_1_DISCOUNT_BPS: u64 = 2000; // 20%
    const TIER_2_DISCOUNT_BPS: u64 = 4000; // 40%

    /// 縮放因子
    const BPS_SCALE: u64 = 10000;
    const USD_SCALE: u64 = 1_000_000; // 1e6
    const APT_DECIMALS_SCALE: u64 = 100_000_000; // 1e8

    // ==============================
    // Structs
    // ==============================

    /// 嵌入在每個 Position 中的 Gas Tank 結構
    struct GasTank has store {
        tapp_points_balance: u64,
        apt_balance: Coin<APT>,
        usdc_balance: Coin<USDC>,
        preferred_payment: u8,
        total_spent_points: u64,
        total_spent_apt: u64,
        total_spent_usdc: u64,
        low_balance_threshold_bps: u64,
        last_refill_time: u64,
    }

    /// Gas 扣除操作的結果
    struct DeductionResult has copy, drop {
        token_used: u8,
        amount_deducted: u64,
        remaining_balance: u64,
        triggered_warning: bool,
    }

    /// 基於倉位分析的推薦充值金額
    struct RefillRecommendation has copy, drop {
        recommended_points: u64,
        recommended_apt: u64,
        recommended_usdc: u64,
        estimated_operations: u64,
        position_size_factor: u64,
    }

    // ==============================
    // Events
    // ==============================

    #[event]
    struct GasTankRefilled has drop, store {
        position_id: u64,
        token_type: u8,
        amount: u64,
        new_balance: u64,
        timestamp: u64,
    }

    #[event]
    struct LowGasWarning has drop, store {
        position_id: u64,
        current_balance_usd: u64,
        threshold_usd: u64,
        timestamp: u64,
    }

    #[event]
    struct GasDeducted has drop, store {
        position_id: u64,
        token_type: u8,
        amount: u64,
        remaining_balance: u64,
        operation_type: u8,
        timestamp: u64,
    }

    // ==============================
    // Public Functions
    // ==============================

    /// /// 初始化一個新的 Gas Tank 實例。
    /// @return: 一個擁有預設值的全新 `GasTank` 結構。
    public fun initialize_gas_tank(): GasTank {
        GasTank {
            tapp_points_balance: 0,
            apt_balance: coin::zero<APT>(),
            usdc_balance: coin::zero<USDC>(),
            preferred_payment: PAYMENT_TYPE_TAPP_POINTS,
            total_spent_points: 0,
            total_spent_apt: 0,
            total_spent_usdc: 0,
            low_balance_threshold_bps: DEFAULT_LOW_BALANCE_THRESHOLD_BPS,
            last_refill_time: timestamp::now_seconds(),
        }
    }

    /// /// [已修正] 使用 Tapp Points 充值 Gas Tank。
    /// 此函數會從用戶帳戶實際轉移積分。
    /// @param user: 充值用戶的簽名者。
    /// @param gas_tank: 需要被充值的 `GasTank` 的可變引用。
    /// @param position_id: 相關的倉位 ID，用於發送事件。
    /// @param amount: 要充值的 Tapp Points 數量。
    public fun refill_with_points(
        user: &signer,
        gas_tank: &mut GasTank,
        position_id: u64,
        amount: u64,
    ) {
        assert!(amount > 0, errors::E_INVALID_PARAMETER);
        assert!(amount <= MAX_SINGLE_REFILL_POINTS, errors::E_REFILL_AMOUNT_TOO_LARGE);
        let new_balance = gas_tank.tapp_points_balance + amount;
        assert!(new_balance <= MAX_BALANCE_POINTS, errors::E_BALANCE_EXCEEDS_LIMIT);

        // [關鍵修正] 呼叫 Tapp Points 模組進行實際的積分轉移
        tapp_points::transfer(user, TREASURY_ADDRESS, amount);

        gas_tank.tapp_points_balance = new_balance;
        gas_tank.last_refill_time = timestamp::now_seconds();

        event::emit(GasTankRefilled {
            position_id,
            token_type: PAYMENT_TYPE_TAPP_POINTS,
            amount,
            new_balance,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// /// 使用 APT 充值 Gas Tank。
    /// @param gas_tank: 需要被充值的 `GasTank` 的可變引用。
    /// @param position_id: 相關的倉位 ID。
    /// @param apt_coin: 包含要充值的 APT 的 `Coin` 物件。
    public fun refill_with_apt(
        gas_tank: &mut GasTank,
        position_id: u64,
        apt_coin: Coin<APT>,
    ) {
        let amount = coin::value(&apt_coin);
        assert!(amount > 0, errors::E_INVALID_PARAMETER);
        assert!(amount <= MAX_SINGLE_REFILL_APT, errors::E_REFILL_AMOUNT_TOO_LARGE);
        let current_balance = coin::value(&gas_tank.apt_balance);
        let new_balance = current_balance + amount;
        assert!(new_balance <= MAX_BALANCE_APT, errors::E_BALANCE_EXCEEDS_LIMIT);

        coin::merge(&mut gas_tank.apt_balance, apt_coin);
        gas_tank.last_refill_time = timestamp::now_seconds();

        event::emit(GasTankRefilled {
            position_id,
            token_type: PAYMENT_TYPE_APT,
            amount,
            new_balance,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// /// 使用 USDC 充值 Gas Tank。
    /// @param gas_tank: 需要被充值的 `GasTank` 的可變引用。
    /// @param position_id: 相關的倉位 ID。
    /// @param usdc_coin: 包含要充值的 USDC 的 `Coin` 物件。
    public fun refill_with_usdc(
        gas_tank: &mut GasTank,
        position_id: u64,
        usdc_coin: Coin<USDC>,
    ) {
        let amount = coin::value(&usdc_coin);
        assert!(amount > 0, errors::E_INVALID_PARAMETER);
        assert!(amount <= MAX_SINGLE_REFILL_USDC, errors::E_REFILL_AMOUNT_TOO_LARGE);
        let current_balance = coin::value(&gas_tank.usdc_balance);
        let new_balance = current_balance + amount;
        assert!(new_balance <= MAX_BALANCE_USDC, errors::E_BALANCE_EXCEEDS_LIMIT);

        coin::merge(&mut gas_tank.usdc_balance, usdc_coin);
        gas_tank.last_refill_time = timestamp::now_seconds();

        event::emit(GasTankRefilled {
            position_id,
            token_type: PAYMENT_TYPE_USDC,
            amount,
            new_balance,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// /// [已修正] 根據指定的美元費用，使用自動回退機制扣款。
    /// 支付優先級: Tapp Points (享折扣) -> APT -> USDC。
    /// @param user_signer: 用戶的簽名者，用於授權轉出資金。
    /// @param gas_tank: `GasTank` 的可變引用。
    /// @param position_id: 相關倉位 ID。
    /// @param base_cost_usd: 需要扣除的基礎費用，以美元計價 (縮放 1e6)。
    /// @param user_staked_points: 用戶質押的 Tapp Points 數量，用於計算折扣。
    /// @param operation_type: 標識操作類型的 u8 值。
    /// @return: 一個 `DeductionResult` 結構，包含本次扣款的詳細資訊。
    public fun deduct_with_fallback(
        user_signer: &signer,
        gas_tank: &mut GasTank,
        position_id: u64,
        base_cost_usd: u64,
        user_staked_points: u64,
        operation_type: u8,
    ): DeductionResult {
        // 1. 嘗試 Tapp Points
        let points_cost = convert_usd_to_points(base_cost_usd);
        let discounted_cost = apply_discount(points_cost, user_staked_points);
        if (gas_tank.tapp_points_balance >= discounted_cost) {
            return deduct_points_internal(gas_tank, position_id, discounted_cost, operation_type);
        }

        // 2. 嘗試 APT
        let apt_cost = convert_usd_to_apt(base_cost_usd);
        if (coin::value(&gas_tank.apt_balance) >= apt_cost) {
            return deduct_apt_internal(user_signer, gas_tank, position_id, apt_cost, operation_type);
        }

        // 3. 嘗試 USDC (USDC 的 value 本身就是 1e6 scaled USD)
        if (coin::value(&gas_tank.usdc_balance) >= base_cost_usd) {
            return deduct_usdc_internal(user_signer, gas_tank, position_id, base_cost_usd, operation_type);
        }

        abort errors::E_INSUFFICIENT_GAS
    }

    /// /// [已修正] 根據倉位參數計算推薦的充值金額，與 SRS (FR-002.2) 保持一致。
    /// @param position_value_usd: 倉位總價值，以美元計價 (縮放 1e6)。
    /// @param strategy_type: 倉位採用的策略類型。
    /// @param protection_days: 期望的保護天數。
    /// @return: 一個 `RefillRecommendation` 結構。
    public fun calculate_refill_recommendation(
        position_value_usd: u64,
        strategy_type: u8,
        protection_days: u64,
    ): RefillRecommendation {
        // SRS 公式: 1 + (position_value_usd / 50000 USD) * 0.5
        // 為避免浮點數，放大 100 倍進行計算
        let position_size_factor_x100 = 100 + (position_value_usd / (50000 * USD_SCALE)) * 50;

        let ops_per_month = estimate_operations_per_month(strategy_type);
        let expected_ops = (protection_days * ops_per_month) / 30;
        let buffered_ops = expected_ops * 2; // 安全緩衝係數 2.0

        // 假設平均每次操作成本為 $0.5 USD
        let avg_op_cost_usd = 500_000; // 0.5 * 1e6

        let total_cost_usd = (buffered_ops * avg_op_cost_usd * position_size_factor_x100) / 100;

        RefillRecommendation {
            recommended_points: convert_usd_to_points(total_cost_usd),
            recommended_apt: convert_usd_to_apt(total_cost_usd),
            recommended_usdc: total_cost_usd,
            estimated_operations: buffered_ops,
            position_size_factor: position_size_factor_x100,
        }
    }

    /// /// 檢查 Gas Tank 是否有足夠餘額執行一次操作。
    /// @param gas_tank: `GasTank` 的引用。
    /// @param required_cost_usd: 此次操作所需的美元費用 (縮放 1e6)。
    /// @param user_staked_points: 用戶質押的積分，用於計算折扣。
    /// @return: 如果餘額充足則返回 `true`，否則返回 `false`。
    public fun has_sufficient_gas(
        gas_tank: &GasTank,
        required_cost_usd: u64,
        user_staked_points: u64,
    ): bool {
        // 1. 檢查 Tapp Points
        let points_cost = convert_usd_to_points(required_cost_usd);
        let discounted_cost = apply_discount(points_cost, user_staked_points);
        if (gas_tank.tapp_points_balance >= discounted_cost) return true;

        // 2. 檢查 APT
        let apt_cost = convert_usd_to_apt(required_cost_usd);
        if (coin::value(&gas_tank.apt_balance) >= apt_cost) return true;

        // 3. 檢查 USDC
        if (coin::value(&gas_tank.usdc_balance) >= required_cost_usd) return true;

        false
    }

    /// /// 更新用戶偏好的支付方式。
    /// @param gas_tank: `GasTank` 的可變引用。
    /// @param payment_type: 新的支付方式代碼。
    public fun set_preferred_payment(
        gas_tank: &mut GasTank,
        payment_type: u8,
    ) {
        assert!(
            payment_type == PAYMENT_TYPE_TAPP_POINTS ||
            payment_type == PAYMENT_TYPE_APT ||
            payment_type == PAYMENT_TYPE_USDC,
            errors::E_INVALID_PAYMENT_TOKEN
        );
        gas_tank.preferred_payment = payment_type;
    }

    /// /// 更新低餘額警告的觸發閾值。
    /// @param gas_tank: `GasTank` 的可變引用。
    /// @param threshold_bps: 新的閾值，以基點表示 (例如 3000 表示 30%)。
    public fun set_low_balance_threshold(
        gas_tank: &mut GasTank,
        threshold_bps: u64,
    ) {
        assert!(threshold_bps <= BPS_SCALE, errors::E_INVALID_PARAMETER);
        gas_tank.low_balance_threshold_bps = threshold_bps;
    }

    // ==============================
    // View Functions
    // ==============================

    /// /// 獲取 Gas Tank 中所有代幣的當前餘額。
    /// @param gas_tank: `GasTank` 的引用。
    /// @return: 一個元組 `(points_balance, apt_balance, usdc_balance)`。
    public fun get_balances(gas_tank: &GasTank): (u64, u64, u64) {
        (
            gas_tank.tapp_points_balance,
            coin::value(&gas_tank.apt_balance),
            coin::value(&gas_tank.usdc_balance)
        )
    }

    /// /// 獲取 Gas Tank 中所有代幣的累計花費。
    /// @param gas_tank: `GasTank` 的引用。
    /// @return: 一個元組 `(total_spent_points, total_spent_apt, total_spent_usdc)`。
    public fun get_spending_stats(gas_tank: &GasTank): (u64, u64, u64) {
        (
            gas_tank.total_spent_points,
            gas_tank.total_spent_apt,
            gas_tank.total_spent_usdc
        )
    }

    /// /// 獲取最後一次充值的時間戳。
    /// @param gas_tank: `GasTank` 的引用。
    /// @return: UNIX 時間戳。
    public fun get_last_refill_time(gas_tank: &GasTank): u64 {
        gas_tank.last_refill_time
    }

    // ==============================
    // Internal Helper Functions
    // ==============================

    /// 根據用戶質押的積分應用費用折扣
    fun apply_discount(base_cost: u64, user_staked_points: u64): u64 {
        let discount_bps = if (user_staked_points >= TIER_2_STAKED_THRESHOLD) {
            TIER_2_DISCOUNT_BPS
        } else if (user_staked_points >= TIER_1_STAKED_THRESHOLD) {
            TIER_1_DISCOUNT_BPS
        } else {
            0
        };
        let discount_amount = (base_cost * discount_bps) / BPS_SCALE;
        base_cost - discount_amount
    }

    /// 扣除 Tapp Points 的內部函數
    fun deduct_points_internal(
        gas_tank: &mut GasTank,
        position_id: u64,
        amount: u64,
        operation_type: u8,
    ): DeductionResult {
        gas_tank.tapp_points_balance = gas_tank.tapp_points_balance - amount;
        gas_tank.total_spent_points = gas_tank.total_spent_points + amount;

        let remaining = gas_tank.tapp_points_balance;
        let triggered_warning = check_low_balance_warning_internal(gas_tank, position_id);

        event::emit(GasDeducted {
            position_id, token_type: PAYMENT_TYPE_TAPP_POINTS, amount,
            remaining_balance: remaining, operation_type, timestamp: timestamp::now_seconds(),
        });

        DeductionResult {
            token_used: PAYMENT_TYPE_TAPP_POINTS, amount_deducted: amount,
            remaining_balance: remaining, triggered_warning,
        }
    }

    /// [已修正] 扣除 APT 的內部函數，將資金轉入金庫
    fun deduct_apt_internal(
        user_signer: &signer,
        gas_tank: &mut GasTank,
        position_id: u64,
        amount: u64,
        operation_type: u8,
    ): DeductionResult {
        let payment = coin::extract(&mut gas_tank.apt_balance, amount);
        coin::deposit(TREASURY_ADDRESS, payment);

        gas_tank.total_spent_apt = gas_tank.total_spent_apt + amount;
        let remaining = coin::value(&gas_tank.apt_balance);
        let triggered_warning = check_low_balance_warning_internal(gas_tank, position_id);

        event::emit(GasDeducted {
            position_id, token_type: PAYMENT_TYPE_APT, amount,
            remaining_balance: remaining, operation_type, timestamp: timestamp::now_seconds(),
        });

        DeductionResult {
            token_used: PAYMENT_TYPE_APT, amount_deducted: amount,
            remaining_balance: remaining, triggered_warning,
        }
    }

    /// [已修正] 扣除 USDC 的內部函數，將資金轉入金庫
    fun deduct_usdc_internal(
        user_signer: &signer,
        gas_tank: &mut GasTank,
        position_id: u64,
        amount: u64,
        operation_type: u8,
    ): DeductionResult {
        let payment = coin::extract(&mut gas_tank.usdc_balance, amount);
        coin::deposit(TREASURY_ADDRESS, payment);

        gas_tank.total_spent_usdc = gas_tank.total_spent_usdc + amount;
        let remaining = coin::value(&gas_tank.usdc_balance);
        let triggered_warning = check_low_balance_warning_internal(gas_tank, position_id);

        event::emit(GasDeducted {
            position_id, token_type: PAYMENT_TYPE_USDC, amount,
            remaining_balance: remaining, operation_type, timestamp: timestamp::now_seconds(),
        });

        DeductionResult {
            token_used: PAYMENT_TYPE_USDC, amount_deducted: amount,
            remaining_balance: remaining, triggered_warning,
        }
    }

    /// [新增] 使用預言機將美元價值轉換為 APT 數量
    fun convert_usd_to_apt(amount_usd: u64): u64 {
        let apt_price_usd = price_oracle::get_price_scaled(b"APT/USD"); // 假設返回價格，scaled 1e8
        assert!(apt_price_usd > 0, errors::E_ORACLE_UNAVAILABLE);
        let numerator = (amount_usd as u128) * (APT_DECIMALS_SCALE as u128);
        let denominator = (apt_price_usd as u128);
        (numerator / denominator) as u64
    }

    /// [新增] 將美元價值轉換為 Tapp Points 數量
    fun convert_usd_to_points(amount_usd: u64): u64 {
        let point_price_usd = price_oracle::get_price_scaled(b"TAPP/USD"); // 假設返回價格, scaled 1e8
        assert!(point_price_usd > 0, errors::E_ORACLE_UNAVAILABLE);
        let numerator = (amount_usd as u128) * 100_000_000; // 乘以 1e8 以匹配價格精度
        let denominator = (point_price_usd as u128);
        (numerator / denominator) as u64
    }
    
    /// 使用預言機將 APT 數量轉換為美元價值
    fun convert_apt_to_usd(amount_apt: u64): u64 {
        if (amount_apt == 0) return 0;
        let apt_price_usd = price_oracle::get_price_scaled(b"APT/USD");
        assert!(apt_price_usd > 0, errors::E_ORACLE_UNAVAILABLE);
        let value = ((amount_apt as u128) * (apt_price_usd as u128)) / (APT_DECIMALS_SCALE as u128);
        (value as u64)
    }
    
    /// 使用預言機將 Tapp Points 數量轉換為美元價值
    fun convert_points_to_usd(amount_points: u64): u64 {
        if (amount_points == 0) return 0;
        let point_price_usd = price_oracle::get_price_scaled(b"TAPP/USD");
        assert!(point_price_usd > 0, errors::E_ORACLE_UNAVAILABLE);
        let value = ((amount_points as u128) * (point_price_usd as u128)) / 100_000_000;
        (value as u64)
    }

    /// 估算每月操作次數
    fun estimate_operations_per_month(strategy_type: u8): u64 {
        if (strategy_type == 1) { 5 }      // 止損策略: 操作較少
        else if (strategy_type == 2) { 20 } // 對沖策略: 需頻繁再平衡
        else { 15 }                         // 混合策略: 介於兩者之間
    }
    
    /// [已修正] 內部低餘額警告檢查邏輯，使其更健壯
    fun check_low_balance_warning_internal(gas_tank: &GasTank, position_id: u64): bool {
        let current_balance_usd = get_total_balance_usd_internal(gas_tank);

        // 計算最大容量的美元價值
        let max_points_usd = convert_points_to_usd(MAX_BALANCE_POINTS);
        let max_apt_usd = convert_apt_to_usd(MAX_BALANCE_APT);
        let max_usdc_usd = MAX_BALANCE_USDC; // USDC is already scaled 1e6
        let max_total_balance_usd = max_points_usd + max_apt_usd + max_usdc_usd;

        if (max_total_balance_usd == 0) return false;

        // 計算警告閾值的美元價值
        let threshold_usd = ((max_total_balance_usd as u128) * (gas_tank.low_balance_threshold_bps as u128) / (BPS_SCALE as u128)) as u64;

        let should_warn = current_balance_usd < threshold_usd;

        if (should_warn) {
            event::emit(LowGasWarning {
                position_id,
                current_balance_usd,
                threshold_usd,
                timestamp: timestamp::now_seconds(),
            });
        };

        should_warn
    }
    
    /// [新增] 使用預言機獲取 Gas Tank 中所有資產的總美元價值
    fun get_total_balance_usd_internal(gas_tank: &GasTank): u64 {
        let points_value_usd = convert_points_to_usd(gas_tank.tapp_points_balance);
        let apt_value_usd = convert_apt_to_usd(coin::value(&gas_tank.apt_balance));
        let usdc_value_usd = coin::value(&gas_tank.usdc_balance);

        points_value_usd + apt_value_usd + usdc_value_usd
    }

    // ==============================
    // Test Helper Functions
    // ==============================

    #[test_only]
    public fun create_test_gas_tank(
        points: u64,
        apt_value: u64,
        usdc_value: u64,
    ): GasTank {
        GasTank {
            tapp_points_balance: points,
            apt_balance: coin::mint<APT>(apt_value),
            usdc_balance: coin::mint<USDC>(usdc_value),
            preferred_payment: PAYMENT_TYPE_TAPP_POINTS,
            total_spent_points: 0, total_spent_apt: 0, total_spent_usdc: 0,
            low_balance_threshold_bps: DEFAULT_LOW_BALANCE_THRESHOLD_BPS,
            last_refill_time: timestamp::now_seconds(),
        }
    }

    #[test_only]
    public fun destroy_gas_tank_for_testing(gas_tank: GasTank) {
        let GasTank {
            tapp_points_balance: _, apt_balance, usdc_balance,
            preferred_payment: _, total_spent_points: _, total_spent_apt: _,
            total_spent_usdc: _, low_balance_threshold_bps: _, last_refill_time: _,
        } = gas_tank;
        coin::destroy_zero(apt_balance);
        coin::destroy_zero(usdc_balance);
    }
}

