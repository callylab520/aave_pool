// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./INonfungiblePositionManagerStruct.sol";

interface IMasterChefv3 is INonfungiblePositionManagerStruct {
  function decreaseLiquidity(
    DecreaseLiquidityParams memory params
  ) external payable returns (uint256 amount0, uint256 amount1);
  
  function increaseLiquidity(
    IncreaseLiquidityParams memory params
  ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);

  function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

  function withdraw(uint256 _tokenId, address _to) external returns (uint256 reward);

  function harvest(uint256 _tokenId, address _to) external returns (uint256 reward);

  function pendingCake(uint256 _tokenId) external view returns (uint256 reward);
}