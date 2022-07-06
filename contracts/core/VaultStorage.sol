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
        uint256 lastIncreasedTime;
    }

    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;
    }

    /* ========== ADDRESSES ========== */

    address public weth;
    address public usdg;
    address public priceFeed;

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) public plugins;
    mapping(address => Market) public markets;

    address[] public allMarkets;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    mapping(address => uint256) public poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping(address => uint256) public reservedAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    // this value is used to calculate the redemption values for selling of USDG
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    mapping(address => uint256) public guaranteedUsd;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // funding rate
    uint256 public constant FUNDING_INTERVAL = 3600 * 8; // 8 hours
    uint256 public fundingRateFactor; // 6 decimals of precision
    uint256 public cumulativeFundingRate; // tracks the funding rates based on utilization
    mapping(address => uint256) public lastRefreshFundingRateTimestamp; // tracks the last time funding was updated for a token

    // fees
    uint256 public liquidationFee;
    uint256 public marginFee = 1000; // 0.1%
    uint256 public feeReserves;

    // short
    mapping(address => uint256) public globalShortSizes;
    mapping(address => uint256) public globalShortAveragePrices;
    mapping(address => uint256) public maxGlobalShortSizes;
}
