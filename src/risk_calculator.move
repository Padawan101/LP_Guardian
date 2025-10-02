module lp_guardian::risk_calculator {
    use std::vector;
    use std::option::{Self, Option};
    use aptos_framework::timestamp;
    use aptos_std::math64;

    // [修正] 移除了未使用的 table 模組
    // use aptos_std::table::{Self, Table};

    // Import project-specific error codes
    use lp_guardian::errors;
    // Import interfaces for external protocols (paths are assumed)
    use tapp_exchange::oracle as tapp_oracle;
    use switchboard::aggregator;

    // ==============================
    // Constants
    // ==============================

    /// 基點 (Basis point) 的縮放因子 (10000 = 100%)
    const BPS_SCALE: u64 = 10000;
    /// 價格的縮放因子 (1e8)
    const PRICE_SCALE: u64 = 100_000_000;
    /// 美元價值的縮放因子 (1e6)
    const USD_SCALE: u64 = 1_000_000;
    /// 價格數據最大可接受的延遲時間（秒）
    const MAX_PRICE_AGE: u64 = 60;
    /// 預言機與 TWAP 價格之間的最大可接受偏差（基點, 500 = 5%）
    const MAX_PRICE_DEVIATION_BPS: u64 = 500;
    /// 用於價格驗證的 TWAP 時間窗口（600 秒 = 10 分鐘）
    const TWAP_WINDOW: u64 = 600;
    /// 健康因子的縮放因子 (1e18)
    const HEALTH_FACTOR_SCALE: u128 = 1_000_000_000_000_000_000;
    /// [修正] 為 IL 計算提供更高精度的 u128 縮放因子
    const PRECISION_SCALE: u128 = 1_000_000_000_000_000_000; // 1e18

    // 風險評分各項權重 (總和必須為 100)
    const WEIGHT_IL_PROXIMITY: u64 = 30;
    const WEIGHT_VAR_95: u64 = 25;
    const WEIGHT_CVAR_95: u64 = 25;
    const WEIGHT_VOLATILITY: u64 = 10;
    const WEIGHT_HEALTH_FACTOR: u64 = 10;

    // ==============================
    // Structs
    // ==============================

    // [修正] 移除了未使用的 PriceCache 結構

    /// 在價格驗證過程中生成的安全報告
    struct PriceSafetyReport has copy, drop, store {
        oracle_price: u64,
        twap_price: u64,
        spot_price: u64,
        deviation_bps: u64,
        safety_level: u8, // 0=SAFE, 1=WARNING, 2=CRITICAL
        timestamp: u64,
    }

    // ==============================
    // Initialization
    // ==============================

    // [修正] 由於 PriceCache 已移除，此函數不再需要
    // public fun initialize(admin: &signer) { ... }

    // ==============================
    // Core Risk Calculations
    // ==============================

    /// [新增] 計算無常損失 (IL)。
    /// IL 是指流動性提供者 (LP) 與單純持有資產 (HODL) 相比的價值損失百分比。
    /// @param initial_price: 建立倉位時的資產價格，縮放 `1e8`。
    /// @param current_price: 當前資產價格，縮放 `1e8`。
    /// @return: 以基點 (bps) 表示的無常損失值 (例如 572 表示 5.72%)。
    public fun calculate_il(
        initial_price: u64,
        current_price: u64
    ): u64 {
        assert!(initial_price > 0, errors::E_INVALID_PRICE);
        assert!(current_price > 0, errors::E_INVALID_PRICE);

        if (initial_price == current_price) {
            return 0
        };

        // [修正] 使用更直接且精度更高的算法
        // 公式: IL = (2 * sqrt(P) / (1 + P)) - 1
        // 為避免負數，轉換為: (1 + P - 2 * sqrt(P)) / (1 + P)
        // 所有計算都在 u128 下進行以防止溢出並保持精度
        let price_ratio = ((current_price as u128) * PRECISION_SCALE) / (initial_price as u128);
        let sqrt_ratio = math64::sqrt((price_ratio as u64)) as u128; // 使用 u64 的 sqrt 更省 gas
        let sqrt_ratio = sqrt_ratio * 1_000_000_000; // 調整精度以匹配 PRECISION_SCALE

        let two_sqrt_p = 2 * sqrt_ratio;
        let one_plus_p = PRECISION_SCALE + price_ratio;

        // 由於價格變動可能導致 IL，我們預期 1+P >= 2*sqrt(P)
        assert!(one_plus_p >= two_sqrt_p, errors::E_ARITHMETIC_OVERFLOW);

        let numerator = one_plus_p - two_sqrt_p;
        let denominator = one_plus_p;

        let il_bps = (numerator * (BPS_SCALE as u128)) / denominator;

        (il_bps as u64)
    }

    /// [新增] 計算流動性倉位的 Delta 風險敞口。
    /// Delta 表示倉位價值對標的資產價格變動的敏感度，這裡返回需要對沖的資產數量。
    /// @param lp_value_usd: LP 倉位總價值，縮放 `1e6`。
    /// @param price_x_usd: 資產 X 的美元價格，縮放 `1e8`。
    /// @param price_y_usd: 資產 Y 的美元價格，縮放 `1e8`。
    /// @param weight_x_bps: 資產 X 在池中的權重（基點）。
    /// @param weight_y_bps: 資產 Y 在池中的權重（基點）。
    /// @param decimals_x_scale: 資產 X 的小數位縮放因子 (例如 `1e8` for APT)。
    /// @param decimals_y_scale: 資產 Y 的小數位縮放因子 (例如 `1e6` for USDC)。
    /// @return: 一個元組，包含 (需要對沖的 X 資產數量, 需要對沖的 Y 資產數量)。
    public fun calculate_delta(
        lp_value_usd: u64,
        price_x_usd: u64,
        price_y_usd: u64,
        weight_x_bps: u64,
        weight_y_bps: u64,
        decimals_x_scale: u64,
        decimals_y_scale: u64
    ): (u64, u64) {
        let delta_x_amount = calculate_single_delta_amount(lp_value_usd, price_x_usd, weight_x_bps, decimals_x_scale);
        let delta_y_amount = calculate_single_delta_amount(lp_value_usd, price_y_usd, weight_y_bps, decimals_y_scale);
        (delta_x_amount, delta_y_amount)
    }

    /// [修正] 計算單個資產的 Delta，返回資產的具體數量，並提升精度。
    fun calculate_single_delta_amount(
        lp_value_usd: u64,
        asset_price_usd: u64,
        weight_bps: u64,
        asset_decimals_scale: u64
    ): u64 {
        assert!(asset_price_usd > 0, errors::E_INVALID_PRICE);

        // 1. 計算此資產在 LP 中的價值（USD，縮放 1e6）
        let asset_value_in_lp = ((lp_value_usd as u128) * (weight_bps as u128)) / (BPS_SCALE as u128);

        // 2. 計算資產數量。公式: Amount = Value / Price
        // 為處理不同的縮放因子 (Value: 1e6, Price: 1e8) 並最大化精度：
        // Amount = (asset_value_in_lp * asset_decimals_scale * PRICE_SCALE) / (asset_price_usd * USD_SCALE)
        let numerator = asset_value_in_lp * (asset_decimals_scale as u128) * (PRICE_SCALE as u128);
        let denominator = (asset_price_usd as u128) * (USD_SCALE as u128);
        assert!(denominator > 0, errors::E_DIVISION_BY_ZERO);

        let asset_amount = numerator / denominator;
        (asset_amount as u64)
    }

    // ==============================
    // VaR and CVaR Calculations
    // ==============================

    /// [新增][架構重構] 計算風險價值 (VaR)。
    /// VaR 指在給定的信賴水準下，投資組合在未來特定時間內的最大預期損失。
    /// **注意**: 此函數依賴 Keeper (鏈下) 傳入預先計算並排序好的 IL 情景數據。
    /// @param position_value: 倉位當前價值 (USD, scaled 1e6)。
    /// @param time_horizon_hours: 風險衡量的时间範圍（小時）。
    /// @param sorted_il_scenarios: 由 Keeper 提供的、已排序的 IL 歷史模擬情景 (bps)。
    /// @param confidence_level: 信賴水準 (90, 95, or 99)。
    /// @return: 潛在的 VaR 損失 (USD, scaled 1e6)。
    public fun calculate_var(
        position_value: u64,
        time_horizon_hours: u64,
        sorted_il_scenarios: &vector<u64>,
        confidence_level: u8
    ): u64 {
        assert!(
            confidence_level == 90 || confidence_level == 95 || confidence_level == 99,
            errors::E_INVALID_PARAMETER
        );
        let scenarios_len = vector::length(sorted_il_scenarios);
        assert!(scenarios_len > 0, errors::E_INVALID_PARAMETER);

        // 從預排序的向量中找到對應百分位的 IL 值。
        let percentile_index = calculate_percentile_index(scenarios_len, confidence_level);
        let var_il_bps = *vector::borrow(sorted_il_scenarios, percentile_index);

        // 使用時間平方根法則調整風險。
        // 為保持 sqrt 計算精度，先乘以 100。
        let time_adjustment = math64::sqrt(time_horizon_hours * 100);
        let base_time_adjustment = math64::sqrt(24 * 100); // 基於 24 小時的標準化
        let adjusted_var_il = (var_il_bps * time_adjustment) / base_time_adjustment;

        ((position_value as u128) * (adjusted_var_il as u128) / (BPS_SCALE as u128)) as u64
    }

    /// [新增][架構重構] 計算條件風險價值 (CVaR)。
    /// CVaR (或稱預期短缺) 是指在損失超過 VaR 閾值的情況下，預期的平均損失。
    /// **注意**: 此函數依賴 Keeper (鏈下) 傳入預先計算並排序好的 IL 情景數據。
    /// @param position_value: 倉位當前價值 (USD, scaled 1e6)。
    /// @param sorted_il_scenarios: 由 Keeper 提供的、已排序的 IL 歷史模擬情景 (bps)。
    /// @param confidence_level: 信賴水準 (90, 95, or 99)。
    /// @return: 潛在的 CVaR 損失 (USD, scaled 1e6)。
    public fun calculate_cvar(
        position_value: u64,
        sorted_il_scenarios: &vector<u64>,
        confidence_level: u8
    ): u64 {
        assert!(
            confidence_level == 90 || confidence_level == 95 || confidence_level == 99,
            errors::E_INVALID_PARAMETER
        );
        let scenarios_len = vector::length(sorted_il_scenarios);
        assert!(scenarios_len > 0, errors::E_INVALID_PARAMETER);

        // 找到 VaR 閾值的索引。
        let var_index = calculate_percentile_index(scenarios_len, confidence_level);

        // 計算所有超過 VaR 索引的 "尾部" 情景的平均 IL。
        let tail_sum: u128 = 0;
        let tail_count: u64 = 0;
        let i = var_index;
        while (i < scenarios_len) {
            tail_sum = tail_sum + (*vector::borrow(sorted_il_scenarios, i) as u128);
            tail_count = tail_count + 1;
            i = i + 1;
        };

        if (tail_count > 0) {
            let cvar_il_bps = (tail_sum / (tail_count as u128)) as u64;
            ((position_value as u128) * (cvar_il_bps as u128) / (BPS_SCALE as u128)) as u64
        } else {
            // 如果沒有超過 VaR 的情景 (極不可能)，則 CVaR 等於 VaR。
            let var_il_bps = *vector::borrow(sorted_il_scenarios, var_index);
            ((position_value as u128) * (var_il_bps as u128) / (BPS_SCALE as u128)) as u64
        }
    }


    // ==============================
    // Risk Scoring
    // ==============================

    /// [新增] 根據多個風險因子計算一個綜合風險評分 (0-100)。
    /// 分數越高，代表當前倉位風險越大。
    /// @param current_il_bps: 當前 IL (bps)。
    /// @param il_threshold_bps: 用戶設定的 IL 觸發閾值 (bps)。
    /// @param var_95_loss: 95% 信賴水準的 VaR 損失 (USD, scaled 1e6)。
    /// @param cvar_95_loss: 95% 信賴水準的 CVaR 損失 (USD, scaled 1e6)。
    /// @param position_value: 倉位價值 (USD, scaled 1e6)。
    /// @param volatility_bps: 市場波動率 (bps)。
    /// @param health_factor: 可選，對沖倉位的健康因子 (scaled 1e18)。
    /// @return: 0-100 的綜合風險評分。
    public fun calculate_risk_score(
        current_il_bps: u64,
        il_threshold_bps: u64,
        var_95_loss: u64,
        cvar_95_loss: u64,
        position_value: u64,
        volatility_bps: u64,
        health_factor: Option<u128>
    ): u64 {
        // 1. IL 接近度評分：當前 IL 越接近閾值，分數越高。
        let il_proximity_score = if (current_il_bps >= il_threshold_bps) {
            100
        } else {
            (current_il_bps * 100) / il_threshold_bps
        };

        // 2. VaR 風險評分：以倉位價值的 5% 作為基準。
        let var_score = calculate_risk_component_score(var_95_loss, position_value / 20);

        // 3. CVaR 風險評分：以倉位價值的 10% 作為基準。
        let cvar_score = calculate_risk_component_score(cvar_95_loss, position_value / 10);

        // 4. 市場波動率評分：以 10% (1000 bps) 的波動率作為基準。
        let volatility_score = calculate_risk_component_score(volatility_bps, 1000);

        // 5. 健康因子評分 (若無則為 0)。
        let health_score = if (option::is_some(&health_factor)) {
            calculate_health_factor_score(*option::borrow(&health_factor))
        } else {
            0
        };

        // 計算所有組分的加權平均值。
        let weighted_sum =
            (il_proximity_score * WEIGHT_IL_PROXIMITY) +
            (var_score * WEIGHT_VAR_95) +
            (cvar_score * WEIGHT_CVAR_95) +
            (volatility_score * WEIGHT_VOLATILITY) +
            (health_score * WEIGHT_HEALTH_FACTOR);

        weighted_sum / 100
    }

    // ==============================
    // Price Verification
    // ==============================

    /// [新增] 使用主預言機 (Switchboard) 和輔助來源 (DEX TWAP) 驗證價格的安全性。
    /// @param asset_aggregator_address: Switchboard aggregator 的地址。
    /// @param pool_address: Tapp Exchange 流動性池的地址。
    /// @return: 一個元組，包含 (最可靠的價格 (TWAP), 價格安全報告)。
    public fun verify_price_safety(
        asset_aggregator_address: address,
        pool_address: address
    ): (u64, PriceSafetyReport) {
        // 1. 從主預言機獲取價格。
        let oracle_price = (aggregator::latest_value(asset_aggregator_address) as u64);
        let oracle_info = aggregator::aggregator_info(asset_aggregator_address);
        assert!(timestamp::now_seconds() - oracle_info.latest_timestamp < MAX_PRICE_AGE, errors::E_STALE_PRICE);

        // 2. 從 DEX TWAP 獲取抗操縱的價格。
        let (twap_price, _) = tapp_oracle::get_twap_price(pool_address, TWAP_WINDOW);

        // 3. (可選) 獲取即時池價格用於參考。
        let spot_price = get_spot_price_from_pool(pool_address);

        // 4. 計算兩個主要價格來源之間的偏差。
        let deviation_bps = calculate_price_deviation(oracle_price, twap_price);

        // 5. 根據偏差確定安全等級。
        let safety_level = if (deviation_bps < 200) { 0 /* SAFE */ }
        else if (deviation_bps < MAX_PRICE_DEVIATION_BPS) { 1 /* WARNING */ }
        else { 2 /* CRITICAL */ };

        // 如果偏差過大，中止交易以防止價格操縱攻擊。
        assert!(safety_level != 2, errors::E_PRICE_MANIPULATION_DETECTED);

        let report = PriceSafetyReport {
            oracle_price, twap_price, spot_price,
            deviation_bps, safety_level,
            timestamp: timestamp::now_seconds(),
        };

        // 返回最可靠的 TWAP 價格和安全報告。
        (twap_price, report)
    }

    // ==============================
    // Helper Functions
    // ==============================

    /// 計算給定百分位在向量中的索引。
    fun calculate_percentile_index(vector_length: u64, percentile: u8): u64 {
        if (vector_length == 0) return 0;
        // 公式: index = floor(length * percentile / 100)
        let index = (vector_length * (percentile as u64)) / 100;
        // 確保索引在邊界內。
        if (index >= vector_length) vector_length - 1 else index
    }

    /// 計算兩個價格之間的偏差（基點）。
    fun calculate_price_deviation(price1: u64, price2: u64): u64 {
        if (price1 == price2) return 0;
        let diff = if (price1 > price2) price1 - price2 else price2 - price1;
        // 使用較低的價格作為基數，以避免低估偏差。
        let base = if (price1 < price2) price1 else price2;
        assert!(base > 0, errors::E_INVALID_PRICE);
        ((diff as u128) * (BPS_SCALE as u128) / (base as u128)) as u64
    }

    /// 將風險組件的值標準化為 0-100 的分數。
    fun calculate_risk_component_score(value: u64, benchmark: u64): u64 {
        assert!(benchmark > 0, errors::E_INVALID_PARAMETER);
        if (value >= benchmark) 100 else (value * 100) / benchmark
    }

    /// 將健康因子 (scaled 1e18) 轉換為風險分數 (0-100)。
    fun calculate_health_factor_score(health_factor: u128): u64 {
        let hf_150 = 1_500_000_000_000_000_000; // 1.5 (安全)
        let hf_130 = 1_300_000_000_000_000_000; // 1.3 (警告)
        let hf_115 = 1_150_000_000_000_000_000; // 1.15 (危險)

        if (health_factor >= hf_150) { 0 }      // 綠色區域 -> 低風險
        else if (health_factor >= hf_130) { 30 } // 黃色區域 -> 中風險
        else if (health_factor >= hf_115) { 60 } // 橘色區域 -> 高風險
        else { 100 }                            // 紅色區域 -> 極高風險
    }

    /// 佔位符函數，用於從 Tapp 池獲取即時價格。
    /// 生產環境中應整合 Tapp 合約讀取儲備量。
    fun get_spot_price_from_pool(pool_address: address): u64 {
        // 目前，我們使用一個短週期的 TWAP 作為即時價格的代理。
        let (price, _) = tapp_oracle::get_twap_price(pool_address, 60);
        price
    }
}
