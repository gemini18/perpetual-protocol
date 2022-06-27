// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IVault {
    function increasePosition(
        address _account,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external;
}
