// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IVault {
    function dollar() external view returns (address);

    function increasePosition(
        address _account,
        address _indexToken,
        uint256 _dollarIn,
        uint256 _sizeDelta,
        bool _isLong
    ) external;
}
