// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";

struct SwapperPosition {
    int128 position0;
    int128 position1;
    uint256 startSwapMarginFeesPerUnit;
    int256 startSwapFundingFeesPerUnit;
}

struct LPPosition {
    uint256 liquidity;
    uint256 startLpMarginFeesPerUnit;
}

struct Permissions {
    bool beforeInitialize;
    bool afterInitialize;
    bool beforeAddLiquidity;
    bool afterAddLiquidity;
    bool beforeRemoveLiquidity;
    bool afterRemoveLiquidity;
    bool beforeSwap;
    bool afterSwap;
    bool beforeDonate;
    bool afterDonate;
    bool beforeSwapReturnsDelta;
    bool afterSwapReturnsDelta;
    bool afterAddLiquidityReturnsDelta;
    bool afterRemoveLiquidityReturnsDelta;
}

struct ModifyPositionCallbackData {
    address sender;
    PoolKey key;
    ICLPoolManager.ModifyLiquidityParams params;
    bytes hookData;
}

struct SwapCallbackData {
    address sender;
    SwapTestSettings testSettings;
    PoolKey key;
    ICLPoolManager.SwapParams params;
    bytes hookData;
}

struct SwapTestSettings {
    bool withdrawTokens;
    bool settleUsingTransfer;
}
