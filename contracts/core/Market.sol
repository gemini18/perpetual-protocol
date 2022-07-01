// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IVault.sol";

contract Market is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    struct IncreasePositionRequest {
        address account;
        address token;
        uint256 amountIn;
        uint256 sizeDelta;
        bool isLong;
        uint256 blockTime;
    }

    struct DecreasePositionRequest {
        address account;
        address token;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        uint256 blockTime;
    }
    /* ========== ADDRESSES ========== */

    address public vault;
    address public immutable weth;

    /* ========== STATE VARIABLES ========== */

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant PRECISION = 1e6;

    // position requests
    mapping(address => uint256) public increasePositionsIndex;
    mapping(bytes32 => IncreasePositionRequest) public increasePositionRequests;

    mapping(address => uint256) public decreasePositionsIndex;
    mapping(bytes32 => DecreasePositionRequest) public decreasePositionRequests;

    // delay
    uint256 public maxTimeDelay;

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

    function setMaxTimeDelay(uint256 _maxTimeDelay) external onlyOwner {
        maxTimeDelay = _maxTimeDelay;
        emit SetMaxTimeDelay(_maxTimeDelay);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Create increase position request
    /// @param _token Address of token.
    /// @param _amountIn Amount of collateral input.
    /// @param _sizeDelta : Size of position.
    /// @param _isLong : long or short position.
    function createIncreasePosition(
        address _token,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong
    ) external nonReentrant whenNotPaused {
        address dollar = IVault(vault).dollar();
        address _account = msg.sender;
        IERC20(dollar).safeTransferFrom(_account, address(this), _amountIn);
        uint256 index = increasePositionsIndex[_account] + 1;
        increasePositionsIndex[_account] = index;

        IncreasePositionRequest memory request = IncreasePositionRequest(
            _account,
            _token,
            _amountIn,
            _sizeDelta,
            _isLong,
            block.timestamp
        );
        bytes32 key = keccak256(abi.encodePacked(_account, index));
        increasePositionRequests[key] = request;

        emit CreateIncreasePosition(
            key,
            _account,
            _token,
            _amountIn,
            _sizeDelta,
            _isLong,
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
            request.blockTime + maxTimeDelay > block.timestamp,
            "Market::executeIncreasePosition Request has expired"
        );
        delete increasePositionRequests[_key];

        // step 2: create position
        address dollar = IVault(vault).dollar();
        IERC20(dollar).safeApprove(vault, 0);
        IERC20(dollar).safeApprove(vault, request.amountIn);
        IVault(vault).increasePosition(
            request.account,
            request.token,
            request.amountIn,
            request.sizeDelta,
            request.isLong
        );

        emit ExecuteIncreasePosition(
            _key,
            request.account,
            request.token,
            request.amountIn,
            request.sizeDelta,
            request.isLong,
            block.timestamp
        );
    }

    /// @notice Create decrease position request
    /// @param _token Address of index token.
    /// @param _collateralDelta Amount of collateral decrease.
    /// @param _sizeDelta : Size of position.
    /// @param _isLong : long or short position.
    function createDecreasePosition(
        address _token,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) external nonReentrant whenNotPaused {
        address _account = msg.sender;
        uint256 index = decreasePositionsIndex[_account] + 1;
        decreasePositionsIndex[_account] = index;

        DecreasePositionRequest memory request = DecreasePositionRequest(
            _account,
            _token,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            block.timestamp
        );
        bytes32 key = keccak256(abi.encodePacked(_account, index));
        decreasePositionRequests[key] = request;

        emit CreateDecreasePosition(
            key,
            _account,
            _token,
            _collateralDelta,
            _sizeDelta,
            _isLong,
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
            request.blockTime + maxTimeDelay > block.timestamp,
            "Market::executeDecreasePosition Request has expired"
        );
        delete decreasePositionRequests[_key];

        // step 2: decrease position
        IVault(vault).decreasePosition(
            request.account,
            request.token,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong
        );

        emit ExecuteDecreasePosition(
            _key,
            request.account,
            request.token,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            block.timestamp
        );
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
        address token,
        uint256 amountIn,
        uint256 sizeDelta,
        bool isLong,
        uint256 index,
        uint256 blockTime
    );
    event ExecuteIncreasePosition(
        bytes32 key,
        address indexed account,
        address token,
        uint256 amountIn,
        uint256 sizeDelta,
        bool isLong,
        uint256 blockTime
    );
    event CreateDecreasePosition(
        bytes32 key,
        address indexed account,
        address token,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 index,
        uint256 blockTime
    );
    event ExecuteDecreasePosition(
        bytes32 key,
        address indexed account,
        address token,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 blockTime
    );
}
