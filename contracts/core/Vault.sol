// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IVaultPriceFeed.sol";

contract Vault is Ownable, Pausable, ReentrancyGuard, IVault {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    /* ========== ADDRESSES ========== */

    address public immutable weth;
    address public override dollar;
    address public priceFeed;

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) public plugins;
    mapping(address => bool) public whitelistedTokens;
    mapping(address => uint256) public minProfitBasisPoints;

    // poolAmounts tracks the number of received dollar that can be used for leverage
    uint256 public poolAmount;

    // reservedAmounts tracks the number of dollar reserved for open leverage positions
    uint256 public reservedAmount;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant PRECISION = 1e6;

    // funding rate
    uint256 public constant FUNDING_INTERVAL = 3600 * 8; // 8 hours
    uint256 public fundingRateFactor; // 6 decimals of precision
    uint256 public cumulativeFundingRate; // tracks the funding rates based on utilization
    uint256 public lastRefreshFundingRateTimestamp;

    // fees
    uint256 public liquidationFee;
    uint256 public marginFee = 1000; // 0.1%
    uint256 public feeReserves;

    uint256 public minProfitTime;

    /* ========== MODIFIERS ========== */

    modifier onlyWhitelistedTokens(address token) {
        require(whitelistedTokens[token], "Vault: onlyWhitelistedTokens");
        _;
    }

    modifier onlyPlugins() {
        require(plugins[msg.sender], "Vault: onlyPlugins");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _weth,
        address _dollar,
        address _priceFeed,
        uint256 _liquidationFee,
        uint256 _fundingRateFactor
    ) {
        weth = _weth;
        dollar = _dollar;
        priceFeed = _priceFeed;
        liquidationFee = _liquidationFee;
        fundingRateFactor = _fundingRateFactor;
    }

    /* ========== FALLBACK ========== */

    receive() external payable {
        assert(msg.sender == weth);
        // only accept ETH via fallback from the WETH contract
    }

    /* ========== VIEWS ========== */

    function getPositionKey(
        address _account,
        address _indexToken,
        bool _isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _indexToken, _isLong));
    }

    function getMaxPrice(address _token) public view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true);
    }

    function getMinPrice(address _token) public view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false);
    }

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _entryPrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view returns (bool, uint256) {
        uint256 price = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        uint256 priceDelta = _entryPrice > price
            ? _entryPrice.sub(price)
            : price.sub(_entryPrice);
        uint256 delta = _size.mul(priceDelta).div(_entryPrice);

        bool hasProfit = _isLong ? price > _entryPrice : _entryPrice > price;

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime.add(minProfitTime)
            ? 0
            : minProfitBasisPoints[_indexToken];
        if (hasProfit && delta.mul(PRECISION) <= _size.mul(minBps)) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function getNextEntryPrice(
        address _indexToken,
        uint256 _size,
        uint256 _entryPrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            _size,
            _entryPrice,
            _isLong,
            _lastIncreasedTime
        );
        uint256 nextSize = _size.add(_sizeDelta);
        uint256 denom;
        if (_isLong) {
            denom = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            denom = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }
        return _nextPrice.mul(nextSize).div(denom);
    }

    function getPositionFee(uint256 _sizeDelta) public view returns (uint256) {
        return _sizeDelta.mul(marginFee).div(PRECISION);
    }

    function getFundingFee(uint256 _size, uint256 _entryFundingRate)
        public
        view
        returns (uint256)
    {
        uint256 fundingRate = cumulativeFundingRate.sub(_entryFundingRate);
        return _size.mul(fundingRate).div(PRECISION);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setPlugin(address plugin) external onlyOwner {
        plugins[plugin] = true;
        emit SetPlugin(plugin);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /// @notice Update cumulative fundingRate
    function refreshCumulativeFundingRate() public {
        require(
            block.timestamp.sub(lastRefreshFundingRateTimestamp) >=
                FUNDING_INTERVAL,
            "Vault::refreshCumulativeFundingRate: Must wait for the funding interval since last refresh"
        );
        uint256 intervals = block
            .timestamp
            .sub(lastRefreshFundingRateTimestamp)
            .div(FUNDING_INTERVAL);
        if (poolAmount == 0) {
            cumulativeFundingRate = 0;
        }
        cumulativeFundingRate = fundingRateFactor
            .mul(reservedAmount)
            .mul(intervals)
            .div(poolAmount);
        lastRefreshFundingRateTimestamp = block.timestamp;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function increasePosition(
        address _account,
        address _indexToken,
        uint256 _dollarIn,
        uint256 _sizeDelta,
        bool _isLong
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyPlugins
        onlyWhitelistedTokens(_indexToken)
    {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 price = _isLong
            ? getMaxPrice(_indexToken)
            : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.entryPrice = price;
        }
        if (position.size > 0 && _sizeDelta > 0) {
            position.entryPrice = getNextEntryPrice(
                _indexToken,
                position.size,
                position.entryPrice,
                _isLong,
                price,
                _sizeDelta,
                position.lastIncreasedTime
            );
        }
        position.collateral = position.collateral.add(_dollarIn);
        uint256 fee = _collectMarginFees(
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        position.collateral = position.collateral.sub(fee);
        position.entryFundingRate = cumulativeFundingRate;
        position.size = position.size.add(_sizeDelta);
        position.lastIncreasedTime = block.timestamp;
        require(position.size > 0, "Vault: empty position");
        require(
            position.size >= position.collateral,
            "Vault: size must be more than collateral"
        );
        // validate liquidation

        position.reserveAmount = position.reserveAmount.add(_sizeDelta);
        _increaseReservedAmount(_sizeDelta);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _collectMarginFees(
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) private returns (uint256) {
        uint256 positionFee = getPositionFee(_sizeDelta);

        uint256 fundingFee = getFundingFee(_size, _entryFundingRate);
        uint256 totalFee = positionFee.add(fundingFee);
        feeReserves = feeReserves.add(totalFee);

        emit CollectMarginFees(totalFee);
        return totalFee;
    }

    function _increaseReservedAmount(uint256 _amount) private {
        reservedAmount = reservedAmount.add(_amount);
        require(reservedAmount <= poolAmount, "Vault: reserve exceeds pool");
        emit IncreaseReservedAmount(_amount);
    }

    /* ========== EVENTS ========== */
    event SetPlugin(address plugin);
    event CollectMarginFees(uint256 fee);
    event IncreaseReservedAmount(uint256 amount);
}
