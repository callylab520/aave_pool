// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface IPancakeV3Factory {
  function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}