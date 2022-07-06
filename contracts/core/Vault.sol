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

    modifier onlySupportMarkets(address token) {
        require(markets[token].isListed, "Vault: onlySupportMarkets");
        _;
    }

    modifier onlyPlugins() {
        require(plugins[msg.sender], "Vault: onlyPlugins");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _weth,
        address _usdg,
        address _priceFeed
    ) {
        weth = _weth;
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

    function supportMarket(address market) external onlyOwner {
        require(!markets[market].isListed, "Vault: Market already listed");
        markets[market] = Market({isListed: true});
        for (uint256 i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != market, "market already added");
        }
        allMarkets.push(market);

        // validate price feed
        getMaxPrice(market);
        emit MarketListed(market);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /// @notice Update cumulative fundingRate
    function refreshCumulativeFundingRate(address _market) public {
        if (
            block.timestamp - lastRefreshFundingRateTimestamp[_market] <
            FUNDING_INTERVAL
        ) return;
        uint256 intervals = (block.timestamp -
            lastRefreshFundingRateTimestamp[_market]) / FUNDING_INTERVAL;
        uint256 poolAmount = poolAmounts[_market];
        uint256 reservedAmount = reservedAmounts[_market];
        if (poolAmount == 0) {
            cumulativeFundingRate = 0;
        } else {
            cumulativeFundingRate =
                (fundingRateFactor * reservedAmount * intervals) /
                poolAmount;
        }

        lastRefreshFundingRateTimestamp[_market] = block.timestamp;
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
    function getPositionDelta(
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
    /// @param _market Address of market.
    /// @param _isLong long or short position
    function liquidatePositionAllowed(
        bytes32 _key,
        address _market,
        bool _isLong,
        bool _raise
    ) public view returns (bool allowed) {
        Position storage position = positions[_key];

        if (position.size == 0) {
            if (_raise) revert("Vault: non-existent position");
        }

        (bool hasProfit, uint256 positionDelta) = getPositionDelta(
            _market,
            position.size,
            position.entryPrice,
            _isLong
        );

        if (!hasProfit && position.collateral <= positionDelta) {
            allowed = true;
            if (_raise) revert("Vault: losses exceed collateral");
        }

        uint256 remainingCollateral = position.collateral;

        if (!hasProfit) {
            remainingCollateral = position.collateral - positionDelta;
        }
    }

    /// @notice caculate token amount to usd
    /// @param _token address of token
    /// @param _amount amount of token
    /// @param _maximise min or max price
    function tokenToUsd(
        address _token,
        uint256 _amount,
        bool _maximise
    ) public view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        uint256 price = _maximise ? getMaxPrice(_token) : getMinPrice(_token);
        return (_amount * price) / PRICE_PRECISION;
    }

    /// @notice caculate usd to token amount
    /// @param _token address of token
    /// @param _amount amount in usd
    /// @param _maximise min or max price
    function usdToToken(
        address _token,
        uint256 _amount,
        bool _maximise
    ) public view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        uint256 price = _maximise ? getMaxPrice(_token) : getMinPrice(_token);
        return (_amount * PRICE_PRECISION) / price;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice buy usdg from token
    /// @param _token address of token
    /// @param _amount amount of token
    function buyUSDG(address _token, uint256 _amount)
        external
        onlySupportMarkets(_token)
        nonReentrant
        returns (uint256)
    {
        refreshCumulativeFundingRate(_token);
        uint256 actualAmount = doTransferIn(_token, msg.sender, _amount);

        uint256 missingDecimals = 18 +
            IUSDG(usdg).decimals() -
            ERC20(_token).decimals();

        uint256 usdgAmount = (actualAmount * 10**missingDecimals) /
            PRICE_PRECISION;
        require(usdgAmount > 0, "Vault: invalid usdgAmount");

        increasePoolAmount(_token, actualAmount);

        IUSDG(usdg).mint(usdgAmount);

        emit BuyUSDG(msg.sender, usdgAmount);

        return usdgAmount;
    }

    /// @notice sell usdg to token
    /// @param _token address of token
    /// @param _amount amount of token
    function sellUSDG(address _token, uint256 _amount)
        external
        onlySupportMarkets(_token)
        nonReentrant
        returns (uint256)
    {
        address receiver = msg.sender;
        uint256 actualAmount = doTransferIn(usdg, receiver, _amount);
        require(actualAmount > 0, "Vault: invalid usdgAmount");

        refreshCumulativeFundingRate(_token);

        decreasePoolAmount(_token, actualAmount);

        IUSDG(usdg).burn(address(this), actualAmount);

        uint256 missingDecimals = 18 +
            IUSDG(usdg).decimals() -
            ERC20(_token).decimals();

        uint256 amountOut = (actualAmount * PRICE_PRECISION) /
            10**missingDecimals;

        doTransferOut(_token, receiver, amountOut);

        emit SellUSDG(receiver, actualAmount);

        return actualAmount;
    }

    /// @notice increase position
    /// @param _account address of account increase position
    /// @param _collateralToken address of collateral token
    /// @param _market address of market
    /// @param _amountIn amount of collateral token increase position
    /// @param _sizeDelta size delta in usd to increase position
    /// @param _isLong long or short position
    function increasePosition(
        address _account,
        address _collateralToken,
        address _market,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong
    )
        external
        nonReentrant
        whenNotPaused
        onlyPlugins
        onlySupportMarkets(_market)
    {
        refreshCumulativeFundingRate(_market);
        bytes32 key = keccak256(
            abi.encodePacked(_account, _collateralToken, _market, _isLong)
        );
        Position storage position = positions[key];

        uint256 actualAmount = doTransferIn(
            _collateralToken,
            msg.sender,
            _amountIn
        );

        uint256 markPrice = _isLong
            ? getMaxPrice(_market)
            : getMinPrice(_market);

        // set position entryPrice if no position exist
        if (position.size == 0) {
            position.entryPrice = markPrice;
        }

        (bool hasProfit, uint256 positionDelta) = getPositionDelta(
            _market,
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
                denom = hasProfit
                    ? nextSize + positionDelta
                    : nextSize - positionDelta;
            } else {
                denom = hasProfit
                    ? nextSize - positionDelta
                    : nextSize + positionDelta;
            }
            position.entryPrice = (markPrice * nextSize) / denom;
        }

        // update entryFundingRate = cumulativeFundingRate
        // size = size + _sizeDelta
        // lastIncreasedTime = block.timestamp
        position.entryFundingRate = cumulativeFundingRate;
        position.size += _sizeDelta;
        position.lastIncreasedTime = block.timestamp;
        // calculte collateral of position: collateral = collateral + actualAmountUsd;
        uint256 actualAmountUsd = tokenToUsd(
            _collateralToken,
            actualAmount,
            false
        );
        position.collateral += actualAmountUsd;

        require(position.size > 0, "Vault: invalid position size");
        require(
            position.size >= position.collateral,
            "Vault: size must be more than collateral"
        );

        // validate liquidation
        liquidatePositionAllowed(key, _market, _isLong, true);

        // update reserveAmount = reserveAmount + reserveDelta
        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToToken(_collateralToken, _sizeDelta, true);
        position.reserveAmount += reserveDelta;
        increaseReservedAmount(_collateralToken, _sizeDelta);

        if (_isLong) {
            // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            increaseGuaranteedUsd(_collateralToken, _sizeDelta);
            decreaseGuaranteedUsd(_collateralToken, actualAmountUsd);
            // treat the deposited collateral as part of the pool
            increasePoolAmount(_collateralToken, actualAmount);
        } else {
            if (globalShortSizes[_market] == 0) {
                globalShortAveragePrices[_market] = markPrice;
            } else {
                uint256 globalShortSize = globalShortSizes[_market];
                uint256 globalShortAveragePrice = globalShortAveragePrices[
                    _market
                ];

                uint256 globalShortPriceDelta = globalShortAveragePrice >
                    markPrice
                    ? globalShortAveragePrice - markPrice
                    : markPrice - globalShortAveragePrice;

                uint256 globalShortSizeDelta = (globalShortSize *
                    globalShortPriceDelta) / globalShortAveragePrice;

                uint256 nextGlobalShortSize = globalShortSize + _sizeDelta;

                uint256 denom = globalShortAveragePrice > markPrice
                    ? nextGlobalShortSize - globalShortSizeDelta
                    : nextGlobalShortSize + globalShortSizeDelta;

                globalShortAveragePrice =
                    (markPrice * nextGlobalShortSize) /
                    denom;
            }

            increaseGlobalShortSize(_market, _sizeDelta);
        }

        emit IncreasePosition(
            key,
            _account,
            _collateralToken,
            _market,
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

    /// @notice decrease position
    /// @param _account address of account decrease position
    /// @param _collateralToken address of collateral token
    /// @param _market address of market
    /// @param _collateralDelta amount of collateral token decrease position
    /// @param _sizeDelta size delta in usd to decrease position
    /// @param _isLong long or short position
    function decreasePosition(
        address _account,
        address _collateralToken,
        address _market,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    )
        external
        nonReentrant
        whenNotPaused
        onlyPlugins
        onlySupportMarkets(_market)
    {
        refreshCumulativeFundingRate(_market);
        bytes32 key = keccak256(
            abi.encodePacked(_account, _collateralToken, _market, _isLong)
        );
        Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");
        require(position.size >= _sizeDelta, "Vault: invalid position size");
        require(
            position.collateral > _collateralDelta,
            "Vault: position collateral exceeded"
        );
        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = (position.reserveAmount * _sizeDelta) /
                position.size;
            position.reserveAmount -= reserveDelta;
            decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        uint256 markPrice = _isLong
            ? getMinPrice(_market)
            : getMaxPrice(_market);

        uint256 usdOut = adjustCollateral(
            key,
            _collateralToken,
            _market,
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
            liquidatePositionAllowed(key, _market, _isLong, true);

            emit DecreasePosition(
                key,
                _account,
                _collateralToken,
                _market,
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
                _collateralToken,
                _market,
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
            if (_isLong) {
                decreasePoolAmount(_collateralToken, usdOut);
            }
            doTransferOut(_collateralToken, _account, usdOut);
        }
    }

    /// @notice liquidate position
    /// @param _account address of account decrease position
    /// @param _collateralToken address of collateral token
    /// @param _market address of market
    /// @param _isLong long or short position
    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _market,
        bool _isLong
    ) external nonReentrant {
        refreshCumulativeFundingRate(_market);
        bytes32 key = keccak256(
            abi.encodePacked(_account, _collateralToken, _market, _isLong)
        );
        Position storage position = positions[key];
        require(position.size > 0, "Vault: empty position");

        bool allowed = liquidatePositionAllowed(key, _market, _isLong, false);
        require(allowed, "Vault: position cannot be liquidated");

        decreaseReservedAmount(_collateralToken, position.reserveAmount);

        uint256 markPrice = _isLong
            ? getMinPrice(_market)
            : getMaxPrice(_market);

        if (_isLong) {
            decreaseGuaranteedUsd(
                _collateralToken,
                position.size - position.collateral
            );
        }

        if (!_isLong) {
            decreaseGlobalShortSize(_market, position.size);
            increasePoolAmount(_collateralToken, position.collateral);
        }

        delete positions[key];

        emit LiquidatePosition(
            key,
            _account,
            _collateralToken,
            _market,
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
        address _collateralToken,
        address _market,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256) {
        Position storage position = positions[key];

        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = getPositionDelta(
                _market,
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

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToToken(
                    _collateralToken,
                    adjustedDelta,
                    false
                );
                decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral -= adjustedDelta;

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToToken(
                    _collateralToken,
                    adjustedDelta,
                    false
                );
                increasePoolAmount(_collateralToken, tokenAmount);
            }
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

    function increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] += _amount;
        require(
            reservedAmounts[_token] <= poolAmounts[_token],
            "Vault: reserve exceeds pool"
        );
        emit IncreaseReservedAmount(_token, _amount);
    }

    function decreaseReservedAmount(address _token, uint256 _amount) private {
        require(
            reservedAmounts[_token] >= _amount,
            "Vault: insufficient reserve"
        );
        reservedAmounts[_token] -= _amount;
        emit DecreaseReservedAmount(_token, _amount);
    }

    function increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] += _amount;
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(poolAmounts[_token] <= balance, "Vault: pool exceeds balance");
        emit IncreasePoolAmount(_token, _amount);
    }

    function decreasePoolAmount(address _token, uint256 _amount) private {
        require(
            poolAmounts[_token] <= poolAmounts[_token],
            "Vault: reserve exceeds pool"
        );
        poolAmounts[_token] -= _amount;
        require(
            reservedAmounts[_token] <= poolAmounts[_token],
            "Vault: reserve exceeds pool"
        );
        emit DecreasePoolAmount(_token, _amount);
    }

    function increaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] += _usdAmount;
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function decreaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] -= _usdAmount;
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }

    function increaseGlobalShortSize(address _token, uint256 _amount) private {
        globalShortSizes[_token] += _amount;

        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            require(
                globalShortSizes[_token] <= maxSize,
                "Vault: max shorts exceeded"
            );
        }
    }

    function decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            globalShortSizes[_token] = 0;
            return;
        }

        globalShortSizes[_token] -= _amount;
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
    event MarketListed(address market);
    event IncreaseReservedAmount(address market, uint256 amount);
    event DecreaseReservedAmount(address market, uint256 amount);
    event IncreasePoolAmount(address market, uint256 amount);
    event DecreasePoolAmount(address market, uint256 amount);
    event IncreaseGuaranteedUsd(address market, uint256 amount);
    event DecreaseGuaranteedUsd(address market, uint256 amount);
    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address market,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address market,
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
        address collateralToken,
        address market,
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
