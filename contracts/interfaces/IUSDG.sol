// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IUSDG {
    function mint(uint256 _amount) external;

    function burn(address _to, uint256 _amount) external;

    function decimals() external view returns (uint8);
}
