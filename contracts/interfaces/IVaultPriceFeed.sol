// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IVaultPriceFeed {
    function getPrice(address _token, bool _maximise)
        external
        view
        returns (uint256);
}
