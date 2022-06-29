// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IVaultPriceFeed.sol";
import "./VaultStorage.sol";
import "../common/ErrorReporter.sol";

contract Vault is
    VaultStorage,
    VaultErrorReporter,
    Ownable,
    Pausable,
    ReentrancyGuard
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant PRECISION = 1e6;

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

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setPlugin(address plugin) external onlyOwner {
        plugins[plugin] = true;
        emit SetPlugin(plugin);
    }

    function setWhitelistedToken(address token) external onlyOwner {
        whitelistedTokens[token] = true;
        emit SetWhitelistedToken(token);
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
        if (
            block.timestamp.sub(lastRefreshFundingRateTimestamp) <
            FUNDING_INTERVAL
        ) return;
        uint256 intervals = block
            .timestamp
            .sub(lastRefreshFundingRateTimestamp)
            .div(FUNDING_INTERVAL);
        if (poolAmount == 0) {
            cumulativeFundingRate = 0;
        } else {
            cumulativeFundingRate = fundingRateFactor
                .mul(reservedAmount)
                .mul(intervals)
                .div(poolAmount);
        }

        lastRefreshFundingRateTimestamp = block.timestamp;
    }

    /* ========== VIEWS ========== */

    function getPositionKey(
        address _account,
        address _token,
        bool _isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _token, _isLong));
    }

    /// @notice get max price of token
    /// @param _token Address of token.
    function getMaxPrice(address _token) public view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true);
    }

    /// @notice get min price of token
    /// @param _token Address of token.
    function getMinPrice(address _token) public view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false);
    }

    /// @notice check if has profit
    function getDelta(
        address _token,
        uint256 _size,
        uint256 _entryPrice,
        bool _isLong
    ) public view returns (bool, uint256) {
        uint256 markPrice = _isLong ? getMinPrice(_token) : getMaxPrice(_token);
        uint256 priceDelta = _entryPrice > markPrice
            ? _entryPrice.sub(markPrice)
            : markPrice.sub(_entryPrice);
        uint256 delta = _size.mul(priceDelta).div(_entryPrice);

        bool hasProfit = _isLong
            ? markPrice > _entryPrice
            : _entryPrice > markPrice;

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

    function liquidatePositionAllowed(
        address _account,
        address _token,
        bool _isLong
    ) public view returns (uint256) {
        bytes32 key = getPositionKey(_account, _token, _isLong);
        Position storage position = positions[key];

        if (position.size == 0) return uint256(Error.POSISTION_NOT_EXIST);

        (bool hasProfit, uint256 delta) = getDelta(
            _token,
            position.size,
            position.entryPrice,
            _isLong
        );

        uint256 fees = getFundingFee(position.size, position.entryFundingRate)
            .add(getPositionFee(position.size));
        if (!hasProfit && position.collateral < delta)
            return uint256(Error.LOSSES_EXCEED_COLLATERAL);

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral.sub(delta);
        }
        if (remainingCollateral < fees) {
            return uint256(Error.FEES_EXCEED_COLLATERAL);
        }
        if (remainingCollateral < fees.add(liquidationFee)) {
            return uint256(Error.LIQUIDATION_FEES_EXCEED_COLLATERAL);
        }

        if (position.size.div(remainingCollateral) > maxLeverage) {
            return uint256(Error.MAX_LEVERAGE_EXCEED);
        }
        return uint256(Error.NO_ERROR);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function increasePosition(
        address _account,
        address _token,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong
    )
        external
        nonReentrant
        whenNotPaused
        onlyPlugins
        onlyWhitelistedTokens(_token)
    {
        bytes32 key = getPositionKey(_account, _token, _isLong);
        Position storage position = positions[key];
        refreshCumulativeFundingRate();

        uint256 actualAmount = doTransferIn(msg.sender, _amountIn);

        uint256 markPrice = _isLong ? getMaxPrice(_token) : getMinPrice(_token);

        // set position entryPrice if no position exist
        if (position.size == 0) {
            position.entryPrice = markPrice;
        }

        (bool hasProfit, uint256 delta) = getDelta(
            _token,
            position.size,
            position.entryPrice,
            _isLong
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
            position.entryPrice = markPrice.mul(nextSize).div(denom);
        }

        // update entryFundingRate = cumulativeFundingRate
        // size = size + _sizeDelta
        // lastIncreasedTime = block.timestamp
        position.entryFundingRate = cumulativeFundingRate;
        position.size = position.size.add(_sizeDelta);
        require(position.size > 0, "Vault: invalid position size");

        // calculate marginFee = positionFee + fundingFee
        // update fee reserve
        // calculte collateral of position: collateral = collateral + actualAmount - fee;
        uint256 fee = _collectMarginFees(
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        position.collateral = position.collateral.add(actualAmount).sub(fee);
        require(
            position.collateral >= fee,
            "Vault: insufficient collateral for fees"
        );
        require(
            position.size >= position.collateral,
            "Vault: size must be more than collateral"
        );

        // validate liquidation
        uint256 allowed = liquidatePositionAllowed(_account, _token, _isLong);
        validate(allowed);

        // update reserveAmount = reserveAmount + _sizeDelta
        position.reserveAmount = position.reserveAmount.add(_sizeDelta);
        _increaseReservedAmount(_sizeDelta);

        if (_isLong) {
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(actualAmount);
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            _decreasePoolAmount(fee);
        }

        emit IncreasePosition(
            key,
            _account,
            _token,
            actualAmount,
            _sizeDelta,
            _isLong,
            markPrice,
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
            markPrice
        );
    }

    function decreasePosition(
        address _account,
        address _token,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    )
        external
        nonReentrant
        whenNotPaused
        onlyPlugins
        onlyWhitelistedTokens(_token)
    {
        refreshCumulativeFundingRate();
        bytes32 key = getPositionKey(_account, _token, _isLong);
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

        uint256 markPrice = _isLong ? getMinPrice(_token) : getMaxPrice(_token);

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(
            _account,
            _token,
            _collateralDelta,
            _sizeDelta,
            _isLong
        );

        // close all or part of position;
        if (position.size != _sizeDelta) {
            position.entryFundingRate = cumulativeFundingRate;
            position.size = position.size.sub(_sizeDelta);
            require(
                position.size >= position.collateral,
                "Vault: Size must be more than collateral"
            );
            // validate liquidation
            uint256 allowed = liquidatePositionAllowed(
                _account,
                _token,
                _isLong
            );
            validate(allowed);

            emit DecreasePosition(
                key,
                _account,
                _token,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                markPrice,
                usdOut.sub(usdOutAfterFee)
            );
            emit UpdatePosition(
                key,
                position.size,
                position.collateral,
                position.entryPrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl,
                markPrice
            );
        } else {
            emit DecreasePosition(
                key,
                _account,
                _token,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                markPrice,
                usdOut.sub(usdOutAfterFee)
            );
            emit ClosePosition(
                key,
                position.size,
                position.collateral,
                position.entryPrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl
            );

            delete positions[key];
        }

        if (usdOut > 0) {
            if (_isLong) {
                _decreasePoolAmount(usdOut);
            }
            doTransferOut(_account, usdOutAfterFee);
        }
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
        address _token,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _token, _isLong);
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
                _token,
                position.size,
                position.entryPrice,
                _isLong
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

    function doTransferIn(address _from, uint256 _amount)
        private
        returns (uint256)
    {
        IERC20 token = IERC20(dollar);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(_from, address(this), _amount);
        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = token.balanceOf(address(this));
        return balanceAfter.sub(balanceBefore, "TOKEN_TRANSFER_IN_OVERFLOW");
    }

    function doTransferOut(address to, uint256 amount) private {
        IERC20 token = IERC20(dollar);
        token.transfer(to, amount);
    }

    /* ========== EVENTS ========== */
    event SetPlugin(address plugin);
    event SetWhitelistedToken(address token);
    event IncreaseReservedAmount(uint256 amount);
    event DecreaseReservedAmount(uint256 amount);
    event IncreasePoolAmount(uint256 amount);
    event DecreasePoolAmount(uint256 amount);
    event IncreasePosition(
        bytes32 key,
        address account,
        address token,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address token,
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
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 entryPrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);
}
