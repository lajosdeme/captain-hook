// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {CLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "@pancakeswap/v4-core/src/Vault.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {SortTokens} from "@pancakeswap/v4-core/test/helpers/SortTokens.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {CLSwapRouter} from "@pancakeswap/v4-periphery/src/pool-cl/CLSwapRouter.sol";
import {NonfungiblePositionManager} from "@pancakeswap/v4-periphery/src/pool-cl/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from
    "@pancakeswap/v4-periphery/src/pool-cl/interfaces/INonfungiblePositionManager.sol";
import {DummyERC20} from "../../../src/utils/DummyERC20.sol";

library SortTokens2 {
    function sort(DummyERC20 tokenA, DummyERC20 tokenB)
        internal
        pure
        returns (Currency _currency0, Currency _currency1)
    {
        if (address(tokenA) < address(tokenB)) {
            (_currency0, _currency1) = (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        } else {
            (_currency0, _currency1) = (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        }
    }
}

contract CLTestUtils {
    Vault vault;
    CLPoolManager poolManager;
    NonfungiblePositionManager nfp;
    CLSwapRouter swapRouter;

    function deployContractsWithTokens() internal returns (Currency, Currency) {
        vault = new Vault();
        poolManager = new CLPoolManager(vault, 500000);
        vault.registerApp(address(poolManager));

        nfp = new NonfungiblePositionManager(vault, poolManager, address(0), address(0));
        swapRouter = new CLSwapRouter(vault, poolManager, address(0));

        DummyERC20 token0 = new DummyERC20("token0", "T0");
        DummyERC20 token1 = new DummyERC20("token1", "T1");

        address[2] memory approvalAddress = [address(nfp), address(swapRouter)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }

        return SortTokens2.sort(token0, token1);
    }

    function addLiquidity(PoolKey memory key, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper)
        internal
    {
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            salt: bytes32(0),
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        nfp.mint(mintParams);
    }
}
