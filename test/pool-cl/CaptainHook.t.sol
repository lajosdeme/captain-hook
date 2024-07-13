// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Constants} from "@pancakeswap/v4-core/test/pool-cl/helpers/Constants.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {CLPosition} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPosition.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {CaptainHook} from "../../src/pool-cl/CaptainHook.sol";
import {CLTestUtils} from "./utils/CLTestUtils.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {ICLSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-cl/interfaces/ICLSwapRouterBase.sol";
import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";

import {Helper} from "./utils/Users.sol";
import "forge-std/console.sol";

contract CaptainHookTest is Helper, CLTestUtils {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    CaptainHook perpHook;
    Currency currency0;
    Currency currency1;
    PoolKey key;

    function setUp() public {
        vm.startPrank(dev);
        (currency0, currency1) = deployContractsWithTokens();
        perpHook = new CaptainHook(poolManager, Currency.unwrap(currency0));

        MockERC20 token = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        token.mint(dev, 300 ether);
        token1.mint(dev, 300 ether);

        // create the pool key
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: perpHook,
            poolManager: poolManager,
            fee: uint24(3000), // 0.3% fee
            // tickSpacing: 10
            parameters: bytes32(uint256(perpHook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });

        // initialize pool at 1:1 price point (assume stablecoin pair)
        poolManager.initialize(key, Constants.SQRT_RATIO_1_1, new bytes(0));

        addLiquidity(key, 100 ether, 100 ether, -887220, 887220);

        vm.stopPrank();
    }

    function testDepositCollateral() public {
        vm.startPrank(dev);
        uint256 depositAmount = 1 ether;
        // If we do not approve hook - this should fail!
        vm.expectRevert();
        perpHook.depositCollateral(key, depositAmount);

        MockERC20 token = MockERC20(Currency.unwrap(currency0));

        token.mint(dev, 300 ether);

        // After we do approve, it should work
        uint256 balBefore = token.balanceOf(dev);

        token.approve(address(perpHook), depositAmount);

        perpHook.depositCollateral(key, depositAmount);

        uint256 balAfter = token.balanceOf(dev);

        assertEq(balBefore, balAfter + depositAmount);
        vm.stopPrank();
    }

    function testLpMint() public {
        vm.startPrank(dev);
        MockERC20 token = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        token.approve(address(perpHook), 100 ether);
        token1.approve(address(perpHook), 100 ether);

        // These are hardcoded in function, need to change if func changes
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);
        /*         console.log(uint24(tickLower)); */

        //address owner = address(this);
        address owner = address(perpHook);
        CLPosition.Info memory position0 = poolManager.getPosition(key.toId(), owner, -887220, 887220, bytes32(0));
        // Should start with 0...
        assertEq(position0.liquidity, 0);
        console.log("starting to mint ");
        perpHook.lpMint(key, 3 ether);
        console.log("MINTED !");

        //uint128 liquidity = manager.getLiquidity(
        //    id,
        //    owner,
        //    tickLower,
        //    tickUpper
        //);

        CLPosition.Info memory position1 = poolManager.getPosition(key.toId(), owner, tickLower, tickUpper, bytes32(0));
        // We minted 3*10^18 liquidity...
        assertEq(position1.liquidity, 3 ether);
        vm.stopPrank();
    }

    function testMarginTrade0() public {
        vm.startPrank(dev);
        MockERC20 token1 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token2 = MockERC20(Currency.unwrap(currency1));

        token1.approve(address(perpHook), 1000 ether);
        token2.approve(address(perpHook), 1000 ether);

        token1.approve(address(perpHook.vault()), 1000 ether);
        token2.approve(address(perpHook.vault()), 1000 ether);

        // Need to mint so we have funds to pull
        // Should add a test to make sure fails gracefully if no free liquidity?
        perpHook.lpMint(key, 3 ether);
        int128 tradeAmount = 1 ether;
        console.log("LP MINTED");
        (uint160 sqrtPriceX96_before0,,,) = poolManager.getSlot0(key.toId());

        // With no collateral should fail!
        vm.expectRevert();
        perpHook.marginTrade(key, tradeAmount);

        uint256 depositAmount = 5 ether;

        perpHook.depositCollateral(key, depositAmount);
        console.log("Collateral deposited");

        perpHook.marginTrade(key, tradeAmount);

        assertApproxEqAbs(perpHook.marginSwapsAbs(key.toId()), 1 ether, 0.1 ether);
        assertApproxEqAbs(abs(perpHook.marginSwapsNet(key.toId())), 1 ether, 0.1 ether);

        (uint160 sqrtPriceX96_after0,,,) = poolManager.getSlot0(key.toId());
        // console2.log("PRICE AFTER", sqrtPriceX962);
        console.log(sqrtPriceX96_after0);
        console.log(sqrtPriceX96_before0);
        assertGt(sqrtPriceX96_after0, sqrtPriceX96_before0);
        vm.stopPrank();
    }

    function testMarginTrade1() public {
        vm.startPrank(dev);
        MockERC20 token1 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token2 = MockERC20(Currency.unwrap(currency1));

        token1.approve(address(perpHook), 1000 ether);
        token2.approve(address(perpHook), 1000 ether);

        token1.approve(address(perpHook.vault()), 1000 ether);
        token2.approve(address(perpHook.vault()), 1000 ether);
        // Need to mint so we have funds to pull
        // Should add a test to make sure fails gracefully if no free liquidity?
        perpHook.lpMint(key, 3 ether);

        int128 tradeAmount = -1 ether;

        (uint160 sqrtPriceX96_before1,,,) = poolManager.getSlot0(key.toId());
        // console2.log("PRICE BEFORE", sqrtPriceX96);

        // With no collateral should fail!
        vm.expectRevert();
        perpHook.marginTrade(key, tradeAmount);

        uint256 depositAmount = 5 ether;
        perpHook.depositCollateral(key, depositAmount);
        perpHook.marginTrade(key, tradeAmount);

        assertApproxEqAbs(perpHook.marginSwapsAbs(key.toId()), 1 ether, 0.1 ether);
        assertApproxEqAbs(abs(perpHook.marginSwapsNet(key.toId())), 1 ether, 0.1 ether);

        (uint160 sqrtPriceX96_after1,,,) = poolManager.getSlot0(key.toId());
        // console2.log("PRICE AFTER", sqrtPriceX962);
        assertLt(sqrtPriceX96_after1, sqrtPriceX96_before1);
    }

    function abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
