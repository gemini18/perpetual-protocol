// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

contract VaultStorage {
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
    }

    /* ========== ADDRESSES ========== */

    address public weth;
    address public dollar;
    address public usdg;
    address public priceFeed;

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) public plugins;
    mapping(address => bool) public whitelistedTokens;

    // poolAmounts tracks the number of received dollar that can be used for leverage
    uint256 public poolAmount;

    // reservedAmounts tracks the number of dollar reserved for open leverage positions
    uint256 public reservedAmount;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // funding rate
    uint256 public constant FUNDING_INTERVAL = 3600 * 8; // 8 hours
    uint256 public fundingRateFactor; // 6 decimals of precision
    uint256 public cumulativeFundingRate; // tracks the funding rates based on utilization
    uint256 public lastRefreshFundingRateTimestamp;

    // fees
    uint256 public liquidationFee;
    uint256 public marginFee = 1000; // 0.1%
    uint256 public feeReserves;

    //leverage
    uint256 public maxLeverage = 50000000; // 50x
}
