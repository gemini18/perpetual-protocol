// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IVault.sol";

contract GlpManager is Ownable, ReentrancyGuard {
    /* ========== ADDRESSES ========== */
    IVault public vault;
    address public usdg;
    address public glp;

    /* ========== STATE VARIABLES ========== */

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant PRECISION = 1e6;

    mapping(address => uint256) public lastAddedAt;
    mapping(address => bool) public handlers;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    uint256 public cooldownDuration;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;

    /* ========== MODIFIERS ========== */

    modifier onlyHandlers() {
        require(handlers[msg.sender], "GlpManager: onlyHandlers");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        address _usdg,
        address _glp,
        uint256 _cooldownDuration
    ) {
        vault = IVault(_vault);
        usdg = _usdg;
        glp = _glp;
        cooldownDuration = _cooldownDuration;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setHandler(address handler) external onlyOwner {
        handlers[handler] = true;
        emit SetHandler(handler);
    }

    function setCooldownDuration(uint256 _cooldownDuration) external onlyOwner {
        require(
            _cooldownDuration <= MAX_COOLDOWN_DURATION,
            "GlpManager: invalid _cooldownDuration"
        );
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction)
        external
        onlyOwner
    {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function addLiquidity(
        address _token,
        uint256 _amount,
        address _to,
        uint256 _minAmountOut
    ) external returns (uint256 liquidity) {
        require(_amount > 0, "GlpManager: invalid _amount");

        // calculate aum before buyUSDG
    }

    /* ========== EVENTS ========== */
    event SetHandler(address handler);
}
