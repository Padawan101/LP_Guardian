module lp_guardian::errors {
    // ==============================
    // Position Related Errors (1xxx)
    // ==============================
    
    /// Position with given ID does not exist
    public const E_POSITION_NOT_FOUND: u64 = 1001;
    
    /// Position already exists for this LP token
    public const E_POSITION_ALREADY_EXISTS: u64 = 1002;
    
    /// Position is not in active state
    public const E_POSITION_NOT_ACTIVE: u64 = 1003;
    
    /// IL threshold value is outside allowed range (200-2000 bps)
    public const E_INVALID_THRESHOLD: u64 = 1004;
    
    /// Invalid strategy type specified (must be 1=StopLoss, 2=Hedge, 3=Hybrid)
    public const E_INVALID_STRATEGY_TYPE: u64 = 1005;
    
    /// LP token not found or does not exist
    public const E_LP_TOKEN_NOT_FOUND: u64 = 1006;
    
    // ==============================
    // Authorization Related Errors (2xxx)
    // ==============================
    
    /// Caller is not authorized to perform this operation
    public const E_UNAUTHORIZED: u64 = 2001;
    
    /// Caller is not the owner of the position
    public const E_NOT_POSITION_OWNER: u64 = 2002;
    
    /// Caller is not an authorized keeper
    public const E_NOT_AUTHORIZED_KEEPER: u64 = 2003;
    
    /// Caller is not the protocol admin
    public const E_NOT_ADMIN: u64 = 2004;
    
    /// Operation is not authorized for this position
    public const E_OPERATION_NOT_AUTHORIZED: u64 = 2005;
    
    // ==============================
    // Gas Tank Related Errors (3xxx)
    // ==============================
    
    /// Insufficient gas balance to execute operation
    public const E_INSUFFICIENT_GAS: u64 = 3001;
    
    /// Invalid payment token type specified
    public const E_INVALID_PAYMENT_TOKEN: u64 = 3002;
    
    /// Refill amount exceeds single transaction limit
    public const E_REFILL_AMOUNT_TOO_LARGE: u64 = 3003;
    
    /// Total balance would exceed maximum allowed limit
    public const E_BALANCE_EXCEEDS_LIMIT: u64 = 3004;
    
    // ==============================
    // Execution Logic Errors (4xxx)
    // ==============================
    
    /// Protection trigger condition not met
    public const E_CONDITION_NOT_MET: u64 = 4001;
    
    /// Too soon to execute another protection operation
    public const E_EXECUTION_TOO_SOON: u64 = 4002;
    
    /// Price manipulation detected (oracle vs pool price deviation)
    public const E_PRICE_MANIPULATION_DETECTED: u64 = 4003;
    
    /// Price deviation between sources exceeds safe threshold
    public const E_PRICE_DEVIATION_TOO_HIGH: u64 = 4004;
    
    /// Slippage exceeds maximum allowed threshold
    public const E_SLIPPAGE_TOO_HIGH: u64 = 4005;
    
    /// Swap operation failed
    public const E_SWAP_FAILED: u64 = 4006;
    
    // ==============================
    // Hedging Related Errors (5xxx)
    // ==============================
    
    /// Health factor too low, position at liquidation risk
    public const E_HEALTH_FACTOR_TOO_LOW: u64 = 5001;
    
    /// Failed to borrow assets from lending protocol
    public const E_BORROW_FAILED: u64 = 5002;
    
    /// Failed to repay borrowed assets
    public const E_REPAY_FAILED: u64 = 5003;
    
    /// Insufficient collateral for borrowing operation
    public const E_INSUFFICIENT_COLLATERAL: u64 = 5004;
    
    /// Hedge ratio outside allowed range
    public const E_HEDGE_RATIO_OUT_OF_RANGE: u64 = 5005;
    
    // ==============================
    // Virtual Position Errors (6xxx)
    // ==============================
    
    /// Virtual position not found
    public const E_VIRTUAL_POSITION_NOT_FOUND: u64 = 6001;
    
    /// Settlement time (24h) has not elapsed yet
    public const E_SETTLEMENT_NOT_DUE: u64 = 6002;
    
    /// Virtual position already settled
    public const E_ALREADY_SETTLED: u64 = 6003;
    
    // ==============================
    // Price & Risk Errors (7xxx)
    // ==============================
    
    /// Price data is stale (exceeds maximum age)
    public const E_STALE_PRICE: u64 = 7001;
    
    /// Oracle service is unavailable
    public const E_ORACLE_UNAVAILABLE: u64 = 7002;
    
    /// Invalid price value (negative or zero)
    public const E_INVALID_PRICE: u64 = 7003;
    
    /// VaR calculation failed
    public const E_VAR_CALCULATION_FAILED: u64 = 7004;
    
    // ==============================
    // System State Errors (8xxx)
    // ==============================
    
    /// System is paused for emergency or maintenance
    public const E_SYSTEM_PAUSED: u64 = 8001;
    
    /// Reentrancy detected
    public const E_REENTRANCY: u64 = 8002;
    
    /// System initialization failed
    public const E_INITIALIZATION_FAILED: u64 = 8003;
    
    // ==============================
    // Other Errors (9xxx)
    // ==============================
    
    /// Invalid parameter provided
    public const E_INVALID_PARAMETER: u64 = 9001;
    
    /// Arithmetic overflow occurred
    public const E_ARITHMETIC_OVERFLOW: u64 = 9002;
    
    /// Division by zero attempted
    public const E_DIVISION_BY_ZERO: u64 = 9003;
    
    /// Invalid timestamp value
    public const E_INVALID_TIMESTAMP: u64 = 9004;
    
    /// Unexpected error occurred
    public const E_UNEXPECTED_ERROR: u64 = 9999;
    
    // ==============================
    // Helper Functions
    // ==============================
    
    /// Check if an error code is position-related (1xxx range)
    public fun is_position_error(code: u64): bool {
        code >= 1000 && code < 2000
    }
    
    /// Check if an error code is authorization-related (2xxx range)
    public fun is_auth_error(code: u64): bool {
        code >= 2000 && code < 3000
    }
    
    /// Check if an error code is gas-tank-related (3xxx range)
    public fun is_gas_error(code: u64): bool {
        code >= 3000 && code < 4000
    }
    
    /// Check if an error code is execution-related (4xxx range)
    public fun is_execution_error(code: u64): bool {
        code >= 4000 && code < 5000
    }
    
    /// Check if an error code is hedging-related (5xxx range)
    public fun is_hedge_error(code: u64): bool {
        code >= 5000 && code < 6000
    }
    
    /// Check if an error code is virtual-position-related (6xxx range)
    public fun is_virtual_error(code: u64): bool {
        code >= 6000 && code < 7000
    }
    
    /// Check if an error code is price/risk-related (7xxx range)
    public fun is_price_risk_error(code: u64): bool {
        code >= 7000 && code < 8000
    }
    
    /// Check if an error code is system-state-related (8xxx range)
    public fun is_system_error(code: u64): bool {
        code >= 8000 && code < 9000
    }
    
    /// Check if an error code is a general/other error (9xxx range)
    public fun is_general_error(code: u64): bool {
        code >= 9000 && code < 10000
    }
}
