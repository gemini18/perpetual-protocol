// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

contract VaultErrorReporter {
    enum Error {
        NO_ERROR,
        POSISTION_NOT_EXIST,
        LOSSES_EXCEED_COLLATERAL,
        FEES_EXCEED_COLLATERAL,
        LIQUIDATION_FEES_EXCEED_COLLATERAL,
        MAX_LEVERAGE_EXCEED
    }

    // errors track string of known errors from vault
    mapping(uint256 => string) public errors;

    /**
     * @dev use this when reporting a known error from vault
     */
    function validate(uint256 errCode) internal view {
        require(errCode != uint256(Error.NO_ERROR), errors[errCode]);
    }
}
