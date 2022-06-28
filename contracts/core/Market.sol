// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IVault.sol";

contract Market is Ownable, ReentrancyGuard, Pausable, IMarket {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct IncreasePositionRequest {
        address account;
        address indexToken;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 blockTime;
    }

    struct DecreasePositionRequest {
        address account;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 minAmountOut;
        uint256 executionFee;
        uint256 blockTime;
    }
    /* ========== ADDRESSES ========== */

    address public vault;
    address public immutable weth;

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) public executors;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant PRECISION = 1e6;

    // position requests
    mapping(address => uint256) public increasePositionsIndex;
    mapping(bytes32 => IncreasePositionRequest) public increasePositionRequests;

    mapping(address => uint256) public decreasePositionsIndex;
    mapping(bytes32 => DecreasePositionRequest) public decreasePositionRequests;

    // fees
    uint256 public depositFee = 5000; // 6 decimals of precision
    uint256 public minExecutionFee = 4000 wei; // fee to execute position requests

    // delay
    uint256 public maxTimeDelay;

    /* ========== MODIFIERS ========== */

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

    /* ========== VIEWS ========== */

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setDepositFee(uint256 _depositFee) external onlyOwner {
        depositFee = _depositFee;
        emit SetDepositFee(_depositFee);
    }

    function setMinExecutionFee(uint256 _minExecutionFee) external onlyOwner {
        minExecutionFee = _minExecutionFee;
        emit SetMinExecutionFee(_minExecutionFee);
    }

    function setMaxTimeDelay(uint256 _maxTimeDelay) external onlyOwner {
        maxTimeDelay = _maxTimeDelay;
        emit SetMaxTimeDelay(_maxTimeDelay);
    }

    function setExecutor(address executor) external onlyOwner {
        executors[executor] = true;
        emit SetExecutor(executor);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Create increase position request
    /// @param _indexToken Address of index token.
    /// @param _amountIn Amount of collateral input.
    /// @param _minAmountOut : Min amount of index token ouput;
    /// @param _sizeDelta : Size of position.
    /// @param _isLong : long or short position.
    /// @param _acceptablePrice : acceptable price of index token
    function createIncreasePosition(
        address _indexToken,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice
    ) external payable nonReentrant whenNotPaused {
        uint256 _executionFee = msg.value;
        require(
            _executionFee >= minExecutionFee,
            "Market::createIncreasePosition Cannot smaller than minExecutionFee"
        );
        IWETH(weth).deposit{value: _executionFee}();
        IERC20(_indexToken).safeTransferFrom(
            msg.sender,
            address(this),
            _amountIn
        );
        address _account = msg.sender;
        uint256 index = increasePositionsIndex[_account].add(1);
        increasePositionsIndex[_account] = index;

        IncreasePositionRequest memory request = IncreasePositionRequest(
            _account,
            _indexToken,
            _amountIn,
            _minAmountOut,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            block.timestamp
        );
        bytes32 key = keccak256(abi.encodePacked(_account, index));
        increasePositionRequests[key] = request;

        emit CreateIncreasePosition(
            key,
            _account,
            _indexToken,
            _amountIn,
            _minAmountOut,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            index,
            block.timestamp
        );
    }

    /// @notice Execute increase position request
    /// @param _key key of increase position request.
    function executeIncreasePosition(bytes32 _key) public nonReentrant {
        // step 1: validate request
        IncreasePositionRequest memory request = increasePositionRequests[_key];
        if (request.account == address(0)) {
            return;
        }
        require(
            request.blockTime.add(maxTimeDelay) > block.timestamp,
            "Market::executeIncreasePosition Request has expired"
        );
        delete increasePositionRequests[_key];
        // step 2: calculate fee

        // step 3: create position
        if (request.isLong) {
            require(
                IVault(vault).getMaxPrice(request.indexToken) >=
                    request.acceptablePrice,
                "Market::executeIncreasePosition Mark price higher than limit"
            );
        } else {
            require(
                IVault(vault).getMinPrice(request.indexToken) <=
                    request.acceptablePrice,
                "Market::executeIncreasePosition Mark price lower than limit"
            );
        }
        address dollar = IVault(vault).dollar();
        IERC20(dollar).safeApprove(vault, 0);
        IERC20(dollar).safeApprove(vault, request.amountIn);
        IVault(vault).increasePosition(
            request.account,
            request.indexToken,
            request.amountIn,
            request.sizeDelta,
            request.isLong
        );

        // step 4: send execution fee
        IWETH(weth).withdraw(request.executionFee);
        payable(msg.sender).transfer(request.executionFee);

        emit ExecuteIncreasePosition(
            _key,
            request.account,
            request.indexToken,
            request.amountIn,
            request.minAmountOut,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            block.timestamp
        );
    }

    /// @notice Create decrease position request
    /// @param _indexToken Address of index token.
    /// @param _collateralDelta Amount of collateral decrease.
    /// @param _sizeDelta : Size of position.
    /// @param _isLong : long or short position.
    /// @param _acceptablePrice : acceptable price of index token
    /// @param _minAmountOut : Min amount of index token ouput;
    function createDecreasePosition(
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _minAmountOut
    ) external payable nonReentrant whenNotPaused {
        uint256 _executionFee = msg.value;
        require(
            _executionFee >= minExecutionFee,
            "Market::createDecreasePosition Cannot smaller than minExecutionFee"
        );
        IWETH(weth).deposit{value: _executionFee}();

        address _account = msg.sender;
        uint256 index = decreasePositionsIndex[_account].add(1);
        decreasePositionsIndex[_account] = index;

        DecreasePositionRequest memory request = DecreasePositionRequest(
            _account,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _minAmountOut,
            _executionFee,
            block.timestamp
        );
        bytes32 key = keccak256(abi.encodePacked(_account, index));
        decreasePositionRequests[key] = request;

        emit CreateDecreasePosition(
            key,
            _account,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _minAmountOut,
            _executionFee,
            index,
            block.number
        );
    }

    /// @notice Execute decrease position request
    /// @param _key key of decrease position request.
    function executeDecreasePosition(bytes32 _key) public nonReentrant {
        // step 1: validate request
        DecreasePositionRequest memory request = decreasePositionRequests[_key];
        if (request.account == address(0)) {
            return;
        }
        require(
            request.blockTime.add(maxTimeDelay) > block.timestamp,
            "Market::executeDecreasePosition Request has expired"
        );
        delete decreasePositionRequests[_key];
        // step 2: calculate fee

        // step 3: decrease position
        if (request.isLong) {
            require(
                IVault(vault).getMinPrice(request.indexToken) >=
                    request.acceptablePrice,
                "Market::executeDecreasePosition Mark price lower than limit"
            );
        } else {
            require(
                IVault(vault).getMaxPrice(request.indexToken) <=
                    request.acceptablePrice,
                "Market::executeDecreasePosition Mark price higher than limit"
            );
        }

        // step 4: send execution fee
        IWETH(weth).withdraw(request.executionFee);
        payable(msg.sender).transfer(request.executionFee);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== EVENTS ========== */

    event SetDepositFee(uint256 depositFee);
    event SetMinExecutionFee(uint256 minExecutionFee);
    event SetMaxTimeDelay(uint256 maxTimeDelay);
    event SetExecutor(address executor);
    event CreateIncreasePosition(
        bytes32 key,
        address indexed account,
        address indexToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 blockTime
    );
    event ExecuteIncreasePosition(
        bytes32 key,
        address indexed account,
        address indexToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockTime
    );
    event CreateDecreasePosition(
        bytes32 key,
        address indexed account,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 minAmountOut,
        uint256 executionFee,
        uint256 index,
        uint256 blockTime
    );
}
