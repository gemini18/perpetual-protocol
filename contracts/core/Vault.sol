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

    //leverage
    uint256 public maxLeverage = 50; // 50x

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

    function getMaxPrice(address _token)
        public
        view
        override
        returns (uint256)
    {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true);
    }

    function getMinPrice(address _token)
        public
        view
        override
        returns (uint256)
    {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false);
    }

    /// @notice check if has profit
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

        // set position entryPrice if no position exist
        if (position.size == 0) {
            position.entryPrice = price;
        }

        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            position.size,
            position.entryPrice,
            _isLong,
            position.lastIncreasedTime
        );

        // calculate new entry price if increase size of position
        // entryPrice = nextPrice * nextSize / (nextSize + delta)
        if (position.size > 0 && _sizeDelta > 0) {
            uint256 denom;
            uint256 nextSize = position.size.add(_sizeDelta);
            if (_isLong) {
                denom = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
            } else {
                denom = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
            }
            position.entryPrice = price.mul(nextSize).div(denom);
        }

        // update entryFundingRate = cumulativeFundingRate
        // size = size + _sizeDelta
        // lastIncreasedTime = block.timestamp
        position.entryFundingRate = cumulativeFundingRate;
        position.size = position.size.add(_sizeDelta);
        position.lastIncreasedTime = block.timestamp;

        // calculate marginFee = positionFee + fundingFee
        // update fee reserve
        // calculte collateral of position: collateral = collateral + _dollarIn - fee;
        uint256 fee = _collectMarginFees(
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        position.collateral = position.collateral.add(_dollarIn).sub(fee);

        // validate liquidation
        require(position.size > 0, "Vault: empty position");
        require(
            position.size >= position.collateral,
            "Vault: size must be more than collateral"
        );
        if (!hasProfit && position.collateral < delta) {
            revert("Vault: losses exceed collateral");
        }
        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral.sub(delta);
        }
        if (remainingCollateral < fee) {
            revert("Vault: fees exceed collateral");
        }
        if (remainingCollateral < fee.add(liquidationFee)) {
            revert("Vault: liquidation fees exceed collateral");
        }

        if (position.size.div(remainingCollateral) > maxLeverage) {
            revert("Vault: maxLeverage exceeded");
        }

        // update reserveAmount = reserveAmount + _sizeDelta
        position.reserveAmount = position.reserveAmount.add(_sizeDelta);
        _increaseReservedAmount(_sizeDelta);

        if (_isLong) {
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(_dollarIn);
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            _decreasePoolAmount(fee);
        }

        emit IncreasePosition(
            key,
            _account,
            _indexToken,
            _dollarIn,
            _sizeDelta,
            _isLong,
            price,
            fee
        );
        emit UpdatePosition(
            key,
            position.size,
            position.collateral,
            position.entryPrice,
            position.entryFundingRate,
            position.reserveAmount,
            position.realisedPnl,
            price
        );
    }

    function decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    )
        external
        nonReentrant
        whenNotPaused
        onlyPlugins
        onlyWhitelistedTokens(_indexToken)
    {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");
        require(position.size > _sizeDelta, "Vault: invalid position size");
        require(
            position.collateral > _collateralDelta,
            "Vault: position collateral exceeded"
        );
        {
            uint256 reserveDelta = position.reserveAmount.mul(_sizeDelta).div(
                position.size
            );
            position.reserveAmount = position.reserveAmount.sub(reserveDelta);
            _decreaseReservedAmount(reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(
            _account,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong
        );
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
        return totalFee;
    }

    function _reduceCollateral(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = getDelta(
                _indexToken,
                position.size,
                position.entryPrice,
                _isLong,
                position.lastIncreasedTime
            );
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = _sizeDelta.mul(delta).div(position.size);
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                _decreasePoolAmount(adjustedDelta);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral.sub(adjustedDelta);

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                _increasePoolAmount(adjustedDelta);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut.add(_collateralDelta);
            position.collateral = position.collateral.sub(_collateralDelta);
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut = usdOut.add(position.collateral);
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut.sub(fee);
        } else {
            position.collateral = position.collateral.sub(fee);
            if (_isLong) {
                _decreasePoolAmount(fee);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function _increaseReservedAmount(uint256 _amount) private {
        reservedAmount = reservedAmount.add(_amount);
        require(reservedAmount <= poolAmount, "Vault: reserve exceeds pool");
        emit IncreaseReservedAmount(_amount);
    }

    function _decreaseReservedAmount(uint256 _amount) private {
        reservedAmount = reservedAmount.sub(
            _amount,
            "Vault: insufficient reserve"
        );
        emit DecreaseReservedAmount(_amount);
    }

    function _increasePoolAmount(uint256 _amount) private {
        poolAmount = poolAmount.add(_amount);
        uint256 balance = IERC20(dollar).balanceOf(address(this));
        require(poolAmount <= balance, "Vault: pool exceeds balance");
        emit IncreasePoolAmount(_amount);
    }

    function _decreasePoolAmount(uint256 _amount) private {
        poolAmount = poolAmount.sub(_amount, "Vault: poolAmount exceeded");
        require(reservedAmount <= poolAmount, "Vault: reserve exceeds pool");
        emit DecreasePoolAmount(_amount);
    }

    /* ========== EVENTS ========== */
    event SetPlugin(address plugin);
    event IncreaseReservedAmount(uint256 amount);
    event DecreaseReservedAmount(uint256 amount);
    event IncreasePoolAmount(uint256 amount);
    event DecreasePoolAmount(uint256 amount);
    event IncreasePosition(
        bytes32 key,
        address account,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 entryPrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);
}
