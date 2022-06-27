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
    address public collateral;
    address public priceFeed;

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) public whitelistedTokens;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant PRECISION = 1e6;

    // funding rate
    uint256 public constant FUNDING_INTERVAL = 3600 * 8; // 8 hours
    uint256 public fundingRateFactor; // 6 decimals of precision
    mapping(address => uint256) public lastRefreshFundingRateTimestamp;

    // fees
    uint256 public liquidationFee;

    uint256 public minProfitTime;

    /* ========== MODIFIERS ========== */

    modifier onlyWhitelistedTokens(address token) {
        require(whitelistedTokens[token], "Market: onlyWhitelistedTokens");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _weth,
        address _collateral,
        address _priceFeed,
        uint256 _liquidationFee,
        uint256 _fundingRateFactor
    ) {
        weth = _weth;
        collateral = _collateral;
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

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
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
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }
        return _nextPrice.mul(nextSize).div(divisor);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /// @notice Update cumulative fundingRate
    function refreshCumulativeFundingRate(address _indexToken) public {
        require(
            block.timestamp - lastRefreshFundingRateTimestamp[_indexToken] >=
                FUNDING_INTERVAL,
            "Vault::refreshCumulativeFundingRate: Must wait for the funding interval since last refresh"
        );
        // calculate funding rate

        lastRefreshFundingRateTimestamp[_indexToken] = block.timestamp;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function increasePosition(
        address _account,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    )
        external
        override
        nonReentrant
        whenNotPaused
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
    }
}
