// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IVault.sol";

contract OrderBook is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct IncreaseOrder {
        address account;
        address market;
        uint256 amount;
        uint256 sizeDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
    }

    struct DecreaseOrder {
        address account;
        address market;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
    }

    /* ========== ADDRESSES ========== */

    address public immutable weth;
    address public vault;

    /* ========== STATE VARIABLES ========== */

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant PRECISION = 1e6;

    mapping(address => mapping(uint256 => IncreaseOrder)) public increaseOrders;
    mapping(address => uint256) public increaseOrdersIndex;
    mapping(address => mapping(uint256 => DecreaseOrder)) public decreaseOrders;
    mapping(address => uint256) public decreaseOrdersIndex;

    /* ========== CONSTRUCTORS ========== */

    constructor(address _vault, address _weth) {
        vault = _vault;
        weth = _weth;
    }

    /* ========== FALLBACK ========== */
    receive() external payable {
        assert(msg.sender == weth);
        // only accept ETH via fallback from the WETH contract
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== VIEWS ========== */

    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _market,
        bool _maximizePrice,
        bool _raise
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice
            ? IVault(vault).getMaxPrice(_market)
            : IVault(vault).getMinPrice(_market);
        bool isPriceValid = _triggerAboveThreshold
            ? currentPrice >= _triggerPrice
            : currentPrice <= _triggerPrice;
        if (_raise) {
            require(isPriceValid, "OrderBook: invalid price for execution");
        }
        return (currentPrice, isPriceValid);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function createIncreaseOrder(
        address _market,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external nonReentrant whenNotPaused {
        address _account = msg.sender;
        IERC20(_market).safeTransferFrom(_account, address(this), _amountIn);

        uint256 _index = increaseOrdersIndex[_account] + 1;
        increaseOrdersIndex[_account] = _index;

        IncreaseOrder memory order = IncreaseOrder(
            _account,
            _market,
            _amountIn,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold
        );
        increaseOrders[_account][_index] = order;

        emit CreateIncreaseOrder(
            _account,
            _index,
            _market,
            _amountIn,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    function updateIncreaseOrder(
        uint256 _orderIndex,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external nonReentrant {
        IncreaseOrder storage order = increaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;

        emit UpdateIncreaseOrder(
            msg.sender,
            _orderIndex,
            _sizeDelta,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    function cancelIncreaseOrder(uint256 _orderIndex) external nonReentrant {
        IncreaseOrder memory order = increaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        delete increaseOrders[msg.sender][_orderIndex];

        IERC20(order.market).safeTransfer(msg.sender, order.amount);

        emit CancelIncreaseOrder(
            order.account,
            _orderIndex,
            order.market,
            order.amount,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold
        );
    }

    function executeIncreaseOrder(address _account, uint256 _orderIndex)
        external
        nonReentrant
        whenNotPaused
    {
        IncreaseOrder memory order = increaseOrders[_account][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        // increase long should use max price
        // increase short should use min price
        validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.market,
            order.isLong,
            true
        );

        delete increaseOrders[_account][_orderIndex];

        IERC20(order.market).safeApprove(vault, 0);
        IERC20(order.market).safeApprove(vault, order.amount);

        IVault(vault).increasePosition(
            order.account,
            order.market,
            order.amount,
            order.sizeDelta,
            order.isLong
        );

        emit ExecuteIncreaseOrder(
            order.account,
            _orderIndex,
            order.market,
            order.amount,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold
        );
    }

    function createDecreaseOrder(
        address _market,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external nonReentrant {
        address _account = msg.sender;
        uint256 _index = decreaseOrdersIndex[_account] + 1;
        decreaseOrdersIndex[_account] = _index;
        DecreaseOrder memory order = DecreaseOrder(
            _account,
            _market,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold
        );
        decreaseOrders[_account][_index] = order;

        emit CreateDecreaseOrder(
            _account,
            _index,
            _market,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    function executeDecreaseOrder(address _account, uint256 _orderIndex)
        external
        nonReentrant
        whenNotPaused
    {
        DecreaseOrder memory order = decreaseOrders[_account][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.market,
            !order.isLong,
            true
        );

        delete decreaseOrders[_account][_orderIndex];

        IVault(vault).decreasePosition(
            order.account,
            order.market,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong
        );

        emit ExecuteDecreaseOrder(
            order.account,
            _orderIndex,
            order.market,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold
        );
    }

    function cancelDecreaseOrder(uint256 _orderIndex) external nonReentrant {
        DecreaseOrder memory order = decreaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        delete decreaseOrders[msg.sender][_orderIndex];

        emit CancelDecreaseOrder(
            order.account,
            _orderIndex,
            order.market,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold
        );
    }

    function updateDecreaseOrder(
        uint256 _orderIndex,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external nonReentrant {
        DecreaseOrder storage order = decreaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;
        order.collateralDelta = _collateralDelta;

        emit UpdateDecreaseOrder(
            msg.sender,
            _orderIndex,
            _collateralDelta,
            _sizeDelta,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    /* ========== EVENTS ========== */

    event CreateIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address market,
        uint256 amount,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event UpdateIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        uint256 sizeDelta,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event CancelIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address market,
        uint256 amount,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event ExecuteIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address market,
        uint256 amount,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event CreateDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address market,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event ExecuteDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address token,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event CancelDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address market,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event UpdateDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
}
