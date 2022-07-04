// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IVaultPriceFeed.sol";
import "../interfaces/IUSDG.sol";
import "./VaultStorage.sol";

contract Vault is VaultStorage, Ownable, Pausable, ReentrancyGuard {
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
        address _usdg,
        address _priceFeed
    ) {
        weth = _weth;
        dollar = _dollar;
        usdg = _usdg;
        priceFeed = _priceFeed;
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
            block.timestamp - lastRefreshFundingRateTimestamp < FUNDING_INTERVAL
        ) return;
        uint256 intervals = (block.timestamp -
            lastRefreshFundingRateTimestamp) / FUNDING_INTERVAL;
        if (poolAmount == 0) {
            cumulativeFundingRate = 0;
        } else {
            cumulativeFundingRate =
                (fundingRateFactor * reservedAmount * intervals) /
                poolAmount;
        }

        lastRefreshFundingRateTimestamp = block.timestamp;
    }

    /* ========== VIEWS ========== */

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
    /// @param _token Address of token.
    /// @param _size Size of position.
    /// @param _entryPrice Entry price of position.
    /// @param _isLong long or short position
    function getDelta(
        address _token,
        uint256 _size,
        uint256 _entryPrice,
        bool _isLong
    ) public view returns (bool, uint256) {
        uint256 markPrice = _isLong ? getMinPrice(_token) : getMaxPrice(_token);
        uint256 priceDelta = _entryPrice > markPrice
            ? _entryPrice - markPrice
            : markPrice - _entryPrice;
        uint256 delta = (_size * priceDelta) / _entryPrice;

        bool hasProfit = _isLong
            ? markPrice > _entryPrice
            : _entryPrice > markPrice;

        return (hasProfit, delta);
    }

    /// @notice check liquidate position
    /// @param _key key of position
    /// @param _token Address of token.
    /// @param _isLong long or short position
    function liquidatePositionAllowed(
        bytes32 _key,
        address _token,
        bool _isLong,
        bool _raise
    ) public view returns (bool allowed) {
        Position storage position = positions[_key];

        if (position.size == 0) {
            if (_raise) revert("Vault: non-existent position");
        }

        (bool hasProfit, uint256 delta) = getDelta(
            _token,
            position.size,
            position.entryPrice,
            _isLong
        );

        if (!hasProfit && position.collateral <= delta) {
            allowed = true;
            if (_raise) revert("Vault: LOSSES_EXCEED_COLLATERAL");
        }

        uint256 remainingCollateral = position.collateral;

        if (!hasProfit) {
            remainingCollateral = position.collateral - delta;
        }

        if (
            remainingCollateral != 0 &&
            (position.size / remainingCollateral) > maxLeverage
        ) {
            allowed = true;
            if (_raise) revert("Vault: MAX_LEVERAGE_EXCEED");
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function buyUSDG(uint256 _amount) external nonReentrant returns (uint256) {
        uint256 actualAmount = doTransferIn(dollar, msg.sender, _amount);
        refreshCumulativeFundingRate();

        uint256 missingDecimals = 18 +
            IUSDG(usdg).decimals() -
            ERC20(dollar).decimals();

        uint256 usdgAmount = (actualAmount * 10**missingDecimals) /
            PRICE_PRECISION;
        require(usdgAmount > 0, "Vault: invalid usdgAmount");

        increasePoolAmount(actualAmount);

        IUSDG(usdg).mint(usdgAmount);

        emit BuyUSDG(msg.sender, usdgAmount);

        return usdgAmount;
    }

    function sellUSDG(uint256 _amount) external nonReentrant returns (uint256) {
        address receiver = msg.sender;
        uint256 actualAmount = doTransferIn(usdg, receiver, _amount);
        require(actualAmount > 0, "Vault: invalid usdgAmount");

        refreshCumulativeFundingRate();

        decreasePoolAmount(actualAmount);

        IUSDG(usdg).burn(address(this), actualAmount);

        uint256 missingDecimals = 18 +
            IUSDG(usdg).decimals() -
            ERC20(dollar).decimals();

        uint256 amountOut = (actualAmount * PRICE_PRECISION) /
            10**missingDecimals;

        doTransferOut(dollar, receiver, amountOut);

        emit SellUSDG(receiver, actualAmount);

        return actualAmount;
    }

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
        bytes32 key = keccak256(abi.encodePacked(_account, _token, _isLong));
        Position storage position = positions[key];
        refreshCumulativeFundingRate();

        uint256 actualAmount = doTransferIn(dollar, msg.sender, _amountIn);

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
            uint256 nextSize = position.size + _sizeDelta;
            if (_isLong) {
                denom = hasProfit ? nextSize + delta : nextSize - delta;
            } else {
                denom = hasProfit ? nextSize - delta : nextSize + delta;
            }
            position.entryPrice = (markPrice * nextSize) / denom;
        }

        // update entryFundingRate = cumulativeFundingRate
        // size = size + _sizeDelta
        // lastIncreasedTime = block.timestamp
        position.entryFundingRate = cumulativeFundingRate;
        position.size += _sizeDelta;
        require(position.size > 0, "Vault: invalid position size");

        // calculte collateral of position: collateral = collateral + actualAmount;
        position.collateral += actualAmount;
        require(
            position.size >= position.collateral,
            "Vault: size must be more than collateral"
        );

        // validate liquidation
        liquidatePositionAllowed(key, _token, _isLong, true);

        // update reserveAmount = reserveAmount + _sizeDelta
        position.reserveAmount += _sizeDelta;
        increaseReservedAmount(_sizeDelta);

        increasePoolAmount(actualAmount);

        emit IncreasePosition(
            key,
            _account,
            _token,
            actualAmount,
            _sizeDelta,
            _isLong,
            markPrice
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
        bytes32 key = keccak256(abi.encodePacked(_account, _token, _isLong));
        Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");
        require(position.size >= _sizeDelta, "Vault: invalid position size");
        require(
            position.collateral > _collateralDelta,
            "Vault: position collateral exceeded"
        );
        {
            uint256 reserveDelta = (position.reserveAmount * _sizeDelta) /
                position.size;
            position.reserveAmount -= reserveDelta;
            decreaseReservedAmount(reserveDelta);
        }

        uint256 markPrice = _isLong ? getMinPrice(_token) : getMaxPrice(_token);

        uint256 usdOut = adjustCollateral(
            key,
            _token,
            _collateralDelta,
            _sizeDelta,
            _isLong
        );

        // close all or part of position;
        if (position.size != _sizeDelta) {
            position.entryFundingRate = cumulativeFundingRate;
            position.size -= _sizeDelta;
            require(
                position.size >= position.collateral,
                "Vault: Size must be more than collateral"
            );
            // validate liquidation
            liquidatePositionAllowed(key, _token, _isLong, true);

            emit DecreasePosition(
                key,
                _account,
                _token,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                markPrice
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
                markPrice
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
            decreasePoolAmount(usdOut);
            doTransferOut(dollar, _account, usdOut);
        }
    }

    function liquidatePosition(
        address _account,
        address _token,
        bool _isLong
    ) external nonReentrant {
        refreshCumulativeFundingRate();
        bytes32 key = keccak256(abi.encodePacked(_account, _token, _isLong));
        Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");

        bool allowed = liquidatePositionAllowed(key, _token, _isLong, false);
        require(allowed, "Vault: position cannot be liquidated");

        decreaseReservedAmount(position.reserveAmount);

        uint256 markPrice = _isLong ? getMinPrice(_token) : getMaxPrice(_token);

        delete positions[key];

        emit LiquidatePosition(
            key,
            _account,
            _token,
            _isLong,
            position.size,
            position.collateral,
            position.reserveAmount,
            position.realisedPnl,
            markPrice
        );
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function adjustCollateral(
        bytes32 key,
        address _token,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256) {
        Position storage position = positions[key];

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
            adjustedDelta = (_sizeDelta * delta) / position.size;
        }

        uint256 usdOut;

        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral -= adjustedDelta;

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut += _collateralDelta;
            position.collateral -= _collateralDelta;
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut += position.collateral;
            position.collateral = 0;
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return usdOut;
    }

    function increaseReservedAmount(uint256 _amount) private {
        reservedAmount += _amount;
        require(reservedAmount <= poolAmount, "Vault: reserve exceeds pool");
        emit IncreaseReservedAmount(_amount);
    }

    function decreaseReservedAmount(uint256 _amount) private {
        reservedAmount -= _amount;
        emit DecreaseReservedAmount(_amount);
    }

    function increasePoolAmount(uint256 _amount) private {
        poolAmount += _amount;
        uint256 balance = IERC20(dollar).balanceOf(address(this));
        require(poolAmount <= balance, "Vault: pool exceeds balance");
        emit IncreasePoolAmount(_amount);
    }

    function decreasePoolAmount(uint256 _amount) private {
        require(poolAmount >= _amount, "Vault: poolAmount exceeded");
        poolAmount -= _amount;
        require(reservedAmount <= poolAmount, "Vault: reserve exceeds pool");
        emit DecreasePoolAmount(_amount);
    }

    function doTransferIn(
        address _token,
        address _from,
        uint256 _amount
    ) private returns (uint256) {
        IERC20 token = IERC20(_token);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(_from, address(this), _amount);
        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = token.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function doTransferOut(
        address _token,
        address to,
        uint256 amount
    ) private {
        IERC20 token = IERC20(_token);
        token.transfer(to, amount);
    }

    /* ========== EVENTS ========== */
    event SetPlugin(address plugin);
    event SetErrors(string[] errors);
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
        uint256 price
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address token,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price
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
    event LiquidatePosition(
        bytes32 key,
        address account,
        address token,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);
    event BuyUSDG(address account, uint256 usdgAmount);
    event SellUSDG(address account, uint256 usdgAmount);
}
