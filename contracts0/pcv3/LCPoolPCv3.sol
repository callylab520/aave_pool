// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./interfaces/IWETH.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IPancakeV3Factory.sol";
import "./interfaces/IMasterChefv3.sol";
import "./interfaces/IERC721Receiver.sol";
import "./interfaces/ISwapPlusv1.sol";
import "./interfaces/IFeeTierStrate.sol";
import "./interfaces/ILCPoolPCv3Ledger.sol";

import "./utils/Ownable.sol";
import "./utils/SafeERC20.sol";

contract LCPoolPCv3 is Ownable, IERC721Receiver {
  using SafeERC20 for IERC20;

  address public nftManager;
  address public nftFactory;
  address public v3MasterChef;
  address public WETH;
  address public rewardToken;
  address public swapRouter;
  address public feeStrate;
  address public ledger;

  int24 private constant MIN_TICK = -887272;
  int24 private constant MAX_TICK = -MIN_TICK;
  uint256 private constant coreDecimal = 1000000;
  bool public reinvestAble = true;
  uint256 public reinvestEdge = 100;

  struct Operator {
    address account;
    address[2] pair;
    uint256 meta; // fee
    uint256 basketId;
    address token;
    uint256 amount;
  }

  struct swapPath {
    ISwapPlusv1.swapBlock[] path;
  }

  mapping (address => bool) public managers;
  mapping (address => bool) public operators;
  modifier onlyManager() {
    require(managers[msg.sender], "LC pool: !manager");
    _;
  }

  event Deposit(uint256 nftId, uint256 liquiidty);
  event Withdraw(uint256 nftId, uint256 liquiidty, uint256 amountOut);
  event ReInvest(address token0, address token1, uint24 fee, uint256 nftId, uint256 reward, uint256 extraLp);
  event RemovePool(address operator, address from, uint256 tokenId, address token0, address token1, uint24 fee, bytes data);
  event LcFee(address account, address token, uint256 amount);
  event ClaimReward(address account, uint256 nftId, uint256 basketId, uint256 extraLp, uint256 reward);

  constructor (
    address _nftManager,
    address _nftFactory,
    address _v3MasterChef,
    address _swapRouter,
    address _feeStrate,
    address _ledger,
    address _WETH,
    address _reward
  ) {
    require(_nftManager != address(0), "LC pool: nft manager");
    require(_nftFactory != address(0), "LC pool: factory");
    require(_v3MasterChef != address(0), "LC pool: master chef");
    require(_swapRouter != address(0), "LC pool: swap router");
    require(_feeStrate != address(0), "LC pool: feeStrate");
    require(_ledger != address(0), "LC pool: ledger");
    require(_WETH != address(0), "LC pool: WETH");
    require(_reward != address(0), "LC pool: reward");

    nftManager = _nftManager;
    nftFactory = _nftFactory;
    v3MasterChef = _v3MasterChef;
    swapRouter = _swapRouter;
    feeStrate = _feeStrate;
    ledger = _ledger;
    WETH = _WETH;
    rewardToken = _reward;
    managers[msg.sender] = true;
  }

  receive() external payable {
  }

  function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) public virtual override returns (bytes4) {
    ( , , address token0, address token1, uint24 fee, , , , , , , ) = INonfungiblePositionManager(nftManager).positions(tokenId);
    emit RemovePool(operator, from, tokenId, token0, token1, fee, data);
    return this.onERC721Received.selector;
  }

  /**
   * mtoken     0: tokenMReward, 1: tM'
   * percent    0: tM->t0%       1: tM->t1%
   * paths      0: tIn->tM,      1: tM->t0,  2: tM->t1
   * minAmounts 0: lpMin0        1: lpMin1
   */
  // function deposit(uint256 tokenId, uint256 basketId, uint256 liquidity, uint256 reward, uint256 exRate) public payable {
  function deposit(
    Operator calldata info,
    address[2][2] calldata mtoken,
    uint256[2][2] calldata percent,
    swapPath[3] calldata paths,
    swapPath[3] calldata rpaths,
    uint256[2][2] calldata minAmounts
  ) public payable returns(uint256, uint256) {
    require(msg.sender == info.account || operators[msg.sender], "LC pool: no access");
    uint256[] memory dpvar = new uint256[](4);
    dpvar[0] = 0; // reward
    dpvar[1] = 0; // exLp
    dpvar[2] = 0; // rewardReserve
    dpvar[3] = 0; // iAmount
    if (info.token != address(0)) {  // If address is not null, send this amount to contract.
      dpvar[3] = IERC20(info.token).balanceOf(address(this));
      IERC20(info.token).safeTransferFrom(info.account, address(this), info.amount);
      dpvar[3] = IERC20(info.token).balanceOf(address(this)) - dpvar[3];
    }
    else {
      IWETH(WETH).deposit{value: msg.value}();
      dpvar[3] = msg.value;
    }
    
    // return extraLp, reward, reserved reward, claim extra lp, claim reward amount
    (dpvar[1], dpvar[0], dpvar[2], ,) = _reinvest(info, mtoken[1], percent[1], rpaths, minAmounts[1], false);

    dpvar[3] = _distributeFee(info.basketId, (info.token==address(0)?WETH:info.token), dpvar[3], 1);
    (uint256 tokenId, uint256 liquidity) = _deposit(info, dpvar[3], mtoken[0], percent[0], paths, minAmounts[0]);
    ILCPoolPCv3Ledger(ledger).updateInfo(info.account, tokenId, info.basketId, liquidity, dpvar[0], dpvar[2], dpvar[1], true);

    return (tokenId, liquidity);
  }

  function withdraw(
    address receiver,
    Operator calldata info,
    address[2][2] calldata mtoken,
    uint256[2] calldata percent,
    swapPath[3] calldata paths,
    swapPath[3] calldata rpaths,
    uint256[2][2] calldata minAmounts
  ) public returns(uint256) {
    require(receiver == info.account || operators[msg.sender], "LC pool: no access");
    // 0: reward
    // 1: exLp
    // 2: rewardReserve
    // 3: tokenId
    // 4: outAmount
    // 5: claim extra lp
    // 6: claim reward amount
    // 7: withdrawn liquidity amount
    // 8: current reward
    uint256[] memory wvar = new uint256[](9);
    
    // return extraLp, reward, reserved reward, claim extra lp, claim reward amount
    (wvar[1], wvar[0], wvar[2], wvar[5], wvar[6]) = _reinvest(info, mtoken[1], percent, rpaths, minAmounts[1], true);
    wvar[8] = IERC20(rewardToken).balanceOf(address(this));
    if (wvar[8] < wvar[6]) {
      wvar[6] = wvar[8];
    }
    if (wvar[6] > 0) {
      IERC20(rewardToken).safeTransfer(info.account, wvar[6]);
    }

    bool isCoin = false;
    if (info.token == address(0)) {
      isCoin = true;
    }
    // return tokenId, withdraw liquidity amount, receive token amount
    (wvar[3], wvar[7], wvar[4]) = _withdraw(info, wvar[5], mtoken[0], paths, minAmounts[0]);
    ILCPoolPCv3Ledger(ledger).updateInfo(info.account, wvar[3], info.basketId, wvar[7], wvar[0], wvar[2], wvar[1], false);

    wvar[4] = _distributeFee(info.basketId, isCoin?WETH:info.token, wvar[4], 0);

    if (wvar[4] > 0) {
      if (isCoin) {
        IWETH(WETH).withdraw(wvar[4]);
        (bool success, ) = payable(receiver).call{value: wvar[4]}("");
        require(success, "LC pool: Failed receipt");
      }
      else {
        IERC20(info.token).safeTransfer(receiver, wvar[4]);
      }
    }
    if (wvar[5] > 0 || wvar[6] > 0) {
      emit ClaimReward(info.account, wvar[3], info.basketId, wvar[5], wvar[6]);
    }
    return wvar[4];
  }

  /**
   * tokens   0: token0,  1: token1,
   * mtokens  0: tokenM,  1: tM'
   * paths    0: t->tM,   1: tM->t0,   2: tM->t1
   * percents 0: tM->t0%  1: tM->t1%
   * return amount0, amount1
   */
  function _depositSwap(
    address tokenIn,
    uint256 amountIn,
    address[2] memory tokens,
    address[2] calldata mTokens,
    uint256[2] calldata percents,
    swapPath[3] calldata paths
  ) internal returns(uint256, uint256) {
    uint256[2] memory outs;
    outs[0] = amountIn;
    outs[1] = amountIn;
    uint256 amountM = amountIn;
    if (tokenIn == address(0)) tokenIn = WETH;

    if (paths[0].path.length > 0) {
      _approveTokenIfNeeded(tokenIn, swapRouter, amountM);
      (, amountM) = ISwapPlusv1(swapRouter).swap(tokenIn, amountM, mTokens[0], address(this), paths[0].path);
    }
    if (paths[1].path.length > 0) {
      _approveTokenIfNeeded(mTokens[0], swapRouter, amountM);
      (, outs[0]) = ISwapPlusv1(swapRouter).swap(mTokens[0], amountM*percents[0]/coreDecimal, tokens[0], address(this), paths[1].path);
      amountM -= amountM*percents[0]/coreDecimal;
      outs[1] = amountM;
    }
    if (paths[2].path.length > 0) {
      if (mTokens[0] == mTokens[1]) {
        _approveTokenIfNeeded(mTokens[1], swapRouter, amountM);
        (, outs[1]) = ISwapPlusv1(swapRouter).swap(mTokens[1], amountM, tokens[1], address(this), paths[2].path);
      }
      else {
        _approveTokenIfNeeded(mTokens[1], swapRouter, outs[0]);
        (, outs[1]) = ISwapPlusv1(swapRouter).swap(mTokens[1], outs[0]*percents[1]/coreDecimal, tokens[1], address(this), paths[2].path);
        outs[0] -= outs[0]*percents[1]/coreDecimal;
      }
    }
    return (outs[0], outs[1]);
  }

  /**
   * return extraLp, reward, reserved reward, claim extra lp, claim reward amount
   */
  function _reinvest(
    Operator calldata info,
    address[2] calldata mtoken,
    uint256[2] calldata percents,
    swapPath[3] calldata paths,
    uint256[2] calldata minAmounts,
    bool claimReward
  ) internal returns(uint256, uint256, uint256, uint256, uint256) {
    uint256[] memory rvar = new uint256[](8);
    rvar[0] = ILCPoolPCv3Ledger(ledger).poolToNftId(info.pair[0], info.pair[1], uint24(info.meta)); // tokenId
    rvar[1] = IERC20(rewardToken).balanceOf(address(this)); // reward
    rvar[2] = 0; // extraLp
    rvar[6] = 0; // claim extra lp
    rvar[7] = 0; // claim reward amount
    if (rvar[0] != 0) {
      if (IMasterChefv3(v3MasterChef).pendingCake(rvar[0]) > 0) {
        IMasterChefv3(v3MasterChef).harvest(rvar[0], address(this));
      }
    }
    rvar[1] = IERC20(rewardToken).balanceOf(address(this)) - rvar[1];
    if (claimReward && rvar[0] != 0) {
      (rvar[6], rvar[7]) = ILCPoolPCv3Ledger(ledger).getSingleReward(info.account, rvar[0], info.basketId, rvar[1], false);
    }
    rvar[1] += ILCPoolPCv3Ledger(ledger).getLastRewardAmount(rvar[0]);

    rvar[1] = _distributeFee(info.basketId, rewardToken, rvar[1], 2);
    rvar[1] = rvar[1] >= rvar[7] ? rvar[1] - rvar[7] : 0;
    rvar[3] = rvar[1]; // reserveReward

    if (reinvestAble && rvar[0] != 0 && rvar[1] >= reinvestEdge) {
      rvar[3] = IERC20(rewardToken).balanceOf(address(this));
      (rvar[4], rvar[5]) = _depositSwap(rewardToken, rvar[1], info.pair, mtoken, percents, paths);
      (rvar[2], , ) = _increaseLiquidity(rvar[0], rvar[4], rvar[5], minAmounts[0], minAmounts[1]);
      rvar[3] = rvar[1] + IERC20(rewardToken).balanceOf(address(this)) - rvar[3];
      emit ReInvest(info.pair[0], info.pair[1], uint24(info.meta), rvar[0], rvar[1], rvar[2]);
    }
    return (rvar[2], rvar[1], rvar[3], rvar[6], rvar[7]);
  }

  /**
   * return tokenId, liquidity
   */
  function _deposit(
    Operator calldata info,
    uint256 iAmount,
    address[2] calldata mtoken,
    uint256[2] calldata percents,
    swapPath[3] calldata paths,
    uint256[2] calldata minAmounts
  ) internal returns(uint256, uint256) {
    (uint256 amount0, uint256 amount1) = _depositSwap(info.token, iAmount, info.pair, mtoken, percents, paths);
    uint256 tokenId = ILCPoolPCv3Ledger(ledger).poolToNftId(info.pair[0], info.pair[1], uint24(info.meta)); // tokenId
    uint128 liquidity = 0;
    uint256[] memory amount = new uint256[](2);
    if (tokenId == 0) {
      (tokenId, liquidity, amount[0], amount[1]) = _mintNewPosition(info.pair[0], info.pair[1], uint24(info.meta), amount0, amount1, minAmounts[0], minAmounts[1]);
    }
    else {
      (liquidity, amount[0], amount[1]) = _increaseLiquidity(tokenId, amount0, amount1, minAmounts[0], minAmounts[1]);
    }
    _refundReserveToken(info.account, info.pair[0], info.pair[1], amount0-amount[0], amount1-amount[1]);
    emit Deposit(tokenId, liquidity);
    return (tokenId, uint256(liquidity));
  }

  function _mintNewPosition(
    address token0,
    address token1,
    uint24 fee,
    uint256 amount0ToAdd,
    uint256 amount1ToAdd,
    uint256 amount0Min,
    uint256 amount1Min
  ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
    _approveTokenIfNeeded(token0, nftManager, amount0ToAdd);
    _approveTokenIfNeeded(token1, nftManager, amount1ToAdd);

    int24 tickSpacing = IPancakeV3Factory(nftFactory).feeAmountTickSpacing(fee);

    INonfungiblePositionManager.MintParams
      memory params = INonfungiblePositionManager.MintParams({
        token0: token0,
        token1: token1,
        fee: fee,
        tickLower: (MIN_TICK / tickSpacing) * tickSpacing,
        tickUpper: (MAX_TICK / tickSpacing) * tickSpacing,
        amount0Desired: amount0ToAdd,
        amount1Desired: amount1ToAdd,
        amount0Min: amount0Min,
        amount1Min: amount1Min,
        recipient: address(this),
        deadline: block.timestamp
      });

    (tokenId, liquidity, amount0, amount1) = INonfungiblePositionManager(nftManager).mint(params);
    INonfungiblePositionManager(nftManager).safeTransferFrom(address(this), v3MasterChef, tokenId);
    ILCPoolPCv3Ledger(ledger).setPoolToNftId(token0, token1, fee, tokenId);
  }

  function _increaseLiquidity(
    uint256 tokenId,
    uint256 amount0ToAdd,
    uint256 amount1ToAdd,
    uint256 amount0Min,
    uint256 amount1Min
  ) internal returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
    ( , , address token0, address token1, , , , , , , , ) = INonfungiblePositionManager(nftManager).positions(tokenId);

    _approveTokenIfNeeded(token0, v3MasterChef, amount0ToAdd);
    _approveTokenIfNeeded(token1, v3MasterChef, amount1ToAdd);

    INonfungiblePositionManagerStruct.IncreaseLiquidityParams memory params = INonfungiblePositionManagerStruct
      .IncreaseLiquidityParams({
        tokenId: tokenId,
        amount0Desired: amount0ToAdd,
        amount1Desired: amount1ToAdd,
        amount0Min: amount0Min,
        amount1Min: amount1Min,
        deadline: block.timestamp
      });

    (liquidity, amount0, amount1) = IMasterChefv3(v3MasterChef).increaseLiquidity(params);
  }

  function _refundReserveToken(address account, address token0, address token1, uint256 amount0, uint256 amount1) internal {
    if (amount0 > 0) {
      IERC20(token0).safeTransfer(account, amount0);
    }
    if (amount1 > 0) {
      IERC20(token1).safeTransfer(account, amount1);
    }
  }

  function _withdrawSwap(
    address tokenOut,
    address[2] memory tokens,
    uint256[2] memory amount,
    address[2] memory mTokens,
    swapPath[3] memory paths
  ) internal returns(uint256) {
    uint256 amountM0 = amount[0];
    uint256 amountM1 = amount[1];
    if (paths[2].path.length > 0) {
      _approveTokenIfNeeded(tokens[1], swapRouter, amount[1]);
      (, amountM1) = ISwapPlusv1(swapRouter).swap(tokens[1], amount[1], mTokens[1], address(this), paths[2].path);
    }

    if (paths[1].path.length == 0) {
      return amount[0] + amountM1;
    }
    else {
      if (mTokens[1] == tokens[0]) {
        amount[0] += amountM1;
      }
      _approveTokenIfNeeded(tokens[0], swapRouter, amount[0]);
      (, amountM0) = ISwapPlusv1(swapRouter).swap(tokens[0], amount[0], mTokens[0], address(this), paths[1].path);
    }

    if (paths[0].path.length == 0) {
      if (mTokens[0] == mTokens[1]) return amountM0+amountM1;
      else return amountM0;
    }
    else {
      _approveTokenIfNeeded(mTokens[0], swapRouter, amountM0+amountM1);
      (, amountM0) = ISwapPlusv1(swapRouter).swap(mTokens[0], amountM0+amountM1, tokenOut, address(this), paths[0].path);
      return amountM0;
    }
  }

  /**
   * return tokenId, withdraw liquidity amount, receive token amount
   */
  function _withdraw(
    Operator calldata info,
    uint256 extraLp,
    address[2] memory mtoken,
    swapPath[3] memory paths,
    uint256[2] memory minAmounts
  ) internal returns(uint256, uint256, uint256) {
    uint256 tokenId = ILCPoolPCv3Ledger(ledger).poolToNftId(info.pair[0], info.pair[1], uint24(info.meta));
    if (tokenId == 0) {
      return (0, 0, 0);
    }
    else {
      uint256 withdrawAmount = info.amount;
      uint256 userLiquidity = ILCPoolPCv3Ledger(ledger).getUserLiquidity(info.account, tokenId, info.basketId);
      if (userLiquidity < withdrawAmount) {
        withdrawAmount = userLiquidity;
      }
      uint256[] memory amount = new uint256[](3);
      withdrawAmount += extraLp;
      (, , , , , , , uint128 liquidity0, , , ,) = INonfungiblePositionManager(nftManager).positions(tokenId);
      if (uint256(liquidity0) < withdrawAmount) {
        withdrawAmount = uint256(liquidity0);
      }
      if (withdrawAmount > 0) {
        (amount[0], amount[1]) = _decreaseLiquidity(tokenId, uint128(withdrawAmount), minAmounts[0], minAmounts[1]);
        amount[2] = _withdrawSwap(info.token, info.pair, [amount[0], amount[1]], mtoken, paths);
        emit Withdraw(tokenId, withdrawAmount, amount[2]);
        return (tokenId, withdrawAmount, amount[2]);
      }
      else {
        return (tokenId, withdrawAmount, 0);
      }
    }
  }

  function _decreaseLiquidity(
    uint256 tokenId,
    uint128 liquidity,
    uint256 amount0Min,
    uint256 amount1Min
  ) internal returns (uint256, uint256) {
    INonfungiblePositionManagerStruct.DecreaseLiquidityParams
      memory params = INonfungiblePositionManagerStruct
        .DecreaseLiquidityParams({
          tokenId: tokenId,
          liquidity: liquidity,
          amount0Min: amount0Min,
          amount1Min: amount1Min,
          deadline: block.timestamp
        });

    IMasterChefv3(v3MasterChef).decreaseLiquidity(params);

    INonfungiblePositionManagerStruct.CollectParams memory cparams = INonfungiblePositionManagerStruct
      .CollectParams({
        tokenId: tokenId,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      });
    return IMasterChefv3(v3MasterChef).collect(cparams);
  }

  // mode 0: withdraw 1: deposit 2: reward
  function _distributeFee(uint256 basketId, address token, uint256 amount, uint256 mode) internal returns(uint256) {
    uint256[] memory fvar = new uint256[](4);
    fvar[0] = 0; // totalFee
    fvar[1] = 0; // baseFee
    if (mode == 0) {
      (fvar[0], fvar[1]) = IFeeTierStrate(feeStrate).getWithdrawFee(basketId);
    }
    else if (mode == 1) {
      (fvar[0], fvar[1]) = IFeeTierStrate(feeStrate).getDepositFee(basketId);
    }
    else if (mode == 2) {
      (fvar[0], fvar[1]) = IFeeTierStrate(feeStrate).getTotalFee(basketId);
    }

    fvar[2] = amount; // rewardReserve
    require(fvar[1] > 0, "LC pool: wrong fee configure");
    fvar[3] = amount * fvar[0] / fvar[1]; // rewardLc

    if (fvar[3] > 0) {
      uint256[] memory feeIndexs = IFeeTierStrate(feeStrate).getAllTier();
      uint256 len = feeIndexs.length;
      uint256 maxFee = IFeeTierStrate(feeStrate).getMaxFee();
      for (uint256 i=0; i<len; i++) {
        (address feeAccount, ,uint256 fee) = IFeeTierStrate(feeStrate).getTier(feeIndexs[i]);
        uint256 feeAmount = fvar[3] * fee / maxFee;
        if (feeAmount > 0 && fvar[2] >= feeAmount && IERC20(token).balanceOf(address(this)) > feeAmount) {
          IERC20(token).safeTransfer(feeAccount, feeAmount);
          emit LcFee(feeAccount, token, feeAmount);
          fvar[2] -= feeAmount;
        }
      }
    }
    return fvar[2];
  }

  function setManager(address account, bool access) public onlyOwner {
    managers[account] = access;
  }

  function setOperator(address account, bool access) public onlyManager {
    operators[account] = access;
  }

  function setFeeStrate(address _feeStrate) external onlyManager {
    require(_feeStrate != address(0), "LC pool: Fee Strate");
    feeStrate = _feeStrate;
  }

  function setSwapRouter(address _swapRouter) external onlyManager {
    require(_swapRouter != address(0), "LC pool: Swap Router");
    swapRouter = _swapRouter;
  }

  function setReinvestInfo(bool able, uint256 edge) public onlyManager {
    reinvestAble = able;
    reinvestEdge = edge;
  }

  function _approveTokenIfNeeded(address token, address spender, uint256 amount) private {
    if (IERC20(token).allowance(address(this), spender) < amount) {
      IERC20(token).safeApprove(spender, 0);
      IERC20(token).safeApprove(spender, type(uint256).max);
    }
  }
}
