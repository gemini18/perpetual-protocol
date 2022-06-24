// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../interfaces/IMarket.sol";

contract Market is Ownable, ReentrancyGuard, IMarket {
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
        address receiver;
        uint256 acceptablePrice;
        uint256 minAmountOut;
        uint256 executionFee;
        uint256 blockTime;
    }
    /* ========== ADDRESSES ========== */

    address public dollar;
    address public vault;

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
    uint256 public minExecutionFee = 4000 wei;

    // delay
    uint256 public maxBlockDelay;
    uint256 public maxTimeDelay;

    /* ========== MODIFIERS ========== */

    modifier onlyExecutors() {
        require(executors[msg.sender], "Market: onlyExecutors");
        _;
    }

    /* ========== CONSTRUCTORS ========== */

    constructor(address _dollar, address _vault) {
        dollar = _dollar;
        vault = _vault;
    }

    /* ========== VIEWS ========== */

    function getRequestKey(address _account, uint256 _index)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_account, _index));
    }

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

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Create increase position request
    /// @param _indexToken Address of index token.
    /// @param _amountIn Amount of dollar input.
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
    ) external payable nonReentrant {
        uint256 _executionFee = msg.value;
        require(
            _executionFee >= minExecutionFee,
            "Market::createIncreasePosition Cannot smaller than minExecutionFee"
        );
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
        bytes32 key = getRequestKey(_account, index);
        increasePositionRequests[key] = request;

        emit CreateIncreasePosition(
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

    function executeIncreasePosition(bytes32 _key) public nonReentrant {
        IncreasePositionRequest memory request = increasePositionRequests[_key];
        if (request.account == address(0)) {
            return;
        }
        if (request.blockTime.add(maxTimeDelay) <= block.timestamp) {
            revert("Market::_validateExecution Request has expired");
        }
        bool allowed = msg.sender == request.account || executors[msg.sender];
        if (!allowed) {
            revert("Market::_validateExecution Forbidden");
        }
        delete increasePositionRequests[_key];
        IERC20(dollar).safeTransfer(vault, request.amountIn);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== EVENTS ========== */

    event SetDepositFee(uint256 depositFee);
    event SetMinExecutionFee(uint256 minExecutionFee);
    event SetMaxTimeDelay(uint256 maxTimeDelay);
    event CreateIncreasePosition(
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
}
