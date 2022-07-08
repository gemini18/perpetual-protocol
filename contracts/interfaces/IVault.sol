// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IVault {
    function dollar() external view returns (address);

    function getMaxPrice(address _token) external view returns (uint256);

    function getMinPrice(address _token) external view returns (uint256);

    function increasePosition(
        address _account,
        address _indexToken,
        uint256 _dollarIn,
        uint256 _sizeDelta,
        bool _isLong
    ) external;

    function decreasePosition(
        address _account,
        address _token,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) external;
}
