// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {FullMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "@pancakeswap/v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {SafeCast} from "@pancakeswap/v4-core/src/libraries/SafeCast.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManagerRouter} from "@pancakeswap/v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {LiquidityAmounts} from "@pancakeswap/v4-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {DummyERC20} from "../utils/DummyERC20.sol";

/// @notice CLCounterHook is a contract that counts the number of times a hook is called
/// @dev note the code is not production ready, it is only to share how a hook looks like
contract CLCounterHook is CLBaseHook {
    using SafeCast for int256;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    address immutable colTokenAddr;

    mapping(PoolId => uint256) public lastFundingTime;

    mapping(PoolId => mapping(address => uint256)) public collateral;

    mapping(PoolId => mapping(address => LPPosition)) public lpPositions;

    mapping(PoolId => mapping(address => SwapperPosition)) public levPositions;

    // Profits from margin fees paid to LPs - will represent amount in USDC
    mapping(PoolId => mapping(address => uint256)) public lpProfits;

    // Need to keep track of how much liquidity LPs have deposited rather than how
    // much there actually is, so we can properly credit margin payments
    mapping(PoolId => uint256) public lpLiqTotal;

    // keep track of margin fees owed to LPs
    mapping(PoolId => uint256) public lpMarginFeesPerUnit;

    // Absolute value of margin swaps, so if open positions are [-100, +200], should be 300
    mapping(PoolId => uint256) public marginSwapsAbs;
    // Net value of margin swaps, so if open positions are [-100, +200], should be -100
    mapping(PoolId => int256) public marginSwapsNet;

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

    constructor(ICLPoolManager _poolManager) CLBaseHook(_poolManager) {}

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidityReturnsDelta: false,
                afterRemoveLiquidityReturnsDelta: false
            })
        );
    }

    function depositCollateral(PoolKey memory key, uint256 amount) external {
        DummyERC20(colTokenAddr).transferFrom(msg.sender, address(this), amount);
        PoolId id = key.toId();
        collateral[id][msg.sender] += amount;
    }

    function withdrawCollateral(PoolKey memory key, uint256 amount) external {
        PoolId id = key.toId();
        require(collateral[id][msg.sender] >= amount);

        require(levPositions[id][msg.sender].position0 == 0, "Positions must be closed!");

        // This should always be closed if position0 is closed, remove check to save gas?
        require(levPositions[id][msg.sender].position1 == 0, "Positions must be closed!");

        collateral[id][msg.sender] -= amount;
        DummyERC20(colTokenAddr).transfer(msg.sender, amount);
    }

    function lpMint(PoolKey memory key, int128 liquidityDelta) external {
        require(liquidityDelta > 0, "Negative stakes not allowed!");

        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        PoolId id = key.toId();

        (uint160 slot0_sqrtPriceX96, int24 slot0_tick,,) = poolManager.getSlot0(id);
        lpLiqTotal[id] += uint128(liquidityDelta);

        BalanceDelta deltaPred =
            _lpMintBalanceDelta(tickLower, tickUpper, liquidityDelta, slot0_tick, slot0_sqrtPriceX96);

        DummyERC20 token0 = DummyERC20(Currency.unwrap(key.currency0));
        DummyERC20 token1 = DummyERC20(Currency.unwrap(key.currency1));

        token0.transferFrom(msg.sender, address(this), uint128(deltaPred.amount0()));
        token1.transferFrom(msg.sender, address(this), uint128(deltaPred.amount1()));

        modifyPosition(key, ICLPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, bytes32(0)), "");

        // This calculates the LP profits based on the marginFeesPerUnit value at the last time they provided liquidity
        settleLP(id, msg.sender);

        // Adjust liqudity and update margin fees per unit
        lpPositions[id][msg.sender].liquidity += uint128(liquidityDelta);
        lpPositions[id][msg.sender].startLpMarginFeesPerUnit = lpMarginFeesPerUnit[id];
    }

    function lpBurn(PoolKey memory key, int128 liquidityDelta) external {
        require(liquidityDelta < 0);
        PoolId id = key.toId();
        require(lpPositions[id][msg.sender].liquidity >= uint128(-liquidityDelta), "Not enough liquidity!");

        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        (BalanceDelta delta,) = modifyPosition(
            key, ICLPoolManager.ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, bytes32(0)), ""
        );

        settleLP(id, msg.sender);

        lpLiqTotal[id] -= uint128(-liquidityDelta); // decreasing total liquidity
        lpPositions[id][msg.sender].liquidity -= uint128(liquidityDelta); // decreasing liquidity for pool for sender
        lpPositions[id][msg.sender].startLpMarginFeesPerUnit = lpMarginFeesPerUnit[id]; // update margin fee per unit to the latest update

        DummyERC20 token0 = DummyERC20(Currency.unwrap(key.currency0));
        DummyERC20 token1 = DummyERC20(Currency.unwrap(key.currency1));

        uint128 send0 = uint128(delta.amount0());
        uint128 send1 = uint128(delta.amount1());

        // Include profits from whichever one was USDC
        if (address(token0) == colTokenAddr) {
            send0 += uint128(lpProfits[id][msg.sender]);
        } else {
            send1 += uint128(lpProfits[id][msg.sender]);
        }

        token0.transfer(msg.sender, send0);
        token1.transfer(msg.sender, send1);

        lpProfits[id][msg.sender] = 0;
    }

    // zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0
    function marginTrade(PoolKey memory key, uint128 tradeAmount) external payable {}

    function execMarginTrade(PoolKey memory key, int128 tradeAmount, bool zeroIsUSDC)
        private
        returns (BalanceDelta delta)
    {}

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        require(token0 == colTokenAddr || token1 == colTokenAddr, "Must have USDC pair!");
        // Transfer logic is hardcoded for erc20s so disable ETH for now
        require(token0 != address(0) && token1 != address(0), "Cannot have ETH pair!");

        // Round down to nearest hour
        lastFundingTime[id] = (block.timestamp / (3600)) * 3600;
        return CLBaseHook.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        return this.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        doFundingMarginPayments(key);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }

    function settleLP(PoolId id, address addrLP) private {
        // Total margin fees per unit minus the margin fees uints at the time the LP provided liquidity last
        uint256 marginFeesPerUnit = lpMarginFeesPerUnit[id] - lpPositions[id][addrLP].startLpMarginFeesPerUnit;
        // fees per unit is modified by their total liqudity in the pool to get the profit
        uint256 lpProfit = marginFeesPerUnit * lpPositions[id][addrLP].liquidity;
        lpProfits[id][addrLP] += lpProfit;
    }

    function doFundingMarginPayments(PoolKey memory key) private {
        // TODO
        // lpMarginFeesPerUnit is calculated here
    }

    function _lpMintBalanceDelta(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 slot0_tick,
        uint160 slot0_sqrtPriceX96
    ) private returns (BalanceDelta result) {
        if (liquidityDelta != 0) {
            int128 amount0;
            int128 amount1;
            if (slot0_tick < tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidityDelta
                ).toInt128();
                result = result + toBalanceDelta(amount0, 0);
            } else if (slot0_tick < tickUpper) {
                amount0 = SqrtPriceMath.getAmount0Delta(
                    slot0_sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickUpper), liquidityDelta
                ).toInt128();
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tickLower), slot0_sqrtPriceX96, liquidityDelta
                ).toInt128();

                result = result + toBalanceDelta(amount0, amount1);
            } else {
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidityDelta
                ).toInt128();
                result = result + toBalanceDelta(0, amount1);
            }
        }
    }

    function modifyPosition(
        PoolKey memory key,
        ICLPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) private returns (BalanceDelta delta, BalanceDelta feeDelta) {
        (delta, feeDelta) = abi.decode(
            vault.lock(
                abi.encode(
                    "modifyPosition",
                    abi.encode(CLPoolManagerRouter.ModifyPositionCallbackData(msg.sender, key, params, hookData))
                )
            ),
            (BalanceDelta, BalanceDelta)
        );
    }

    function swapperProfitToCollateral(PoolKey memory key, address addrSwapper) private {
        PoolId id = key.toId();

        bool zeroIsUSDC = Currency.unwrap(key.currency0) == colTokenAddr;

        if (zeroIsUSDC) {
            require(levPositions[id][addrSwapper].position1 == 0, "Positions must be closed!");
            if (levPositions[id][addrSwapper].position0 > 0) {
                collateral[id][addrSwapper] += uint128(levPositions[id][addrSwapper].position0);
            } else {
                collateral[id][addrSwapper] += uint128(-levPositions[id][addrSwapper].position0);
            }
            levPositions[id][addrSwapper].position0 = 0;
        } else {
            require(levPositions[id][addrSwapper].position0 == 0, "Positions must be closed!");
            if (levPositions[id][addrSwapper].position1 > 0) {
                collateral[id][addrSwapper] += uint128(levPositions[id][addrSwapper].position1);
            } else {
                collateral[id][addrSwapper] += uint128(-levPositions[id][addrSwapper].position1);
            }
            levPositions[id][addrSwapper].position1 = 0;
        }
    }

    function removeLiquidity(PoolKey memory key, int128 tradeAmount) private {
        // Hardcoding full tick range for now
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        PoolId id = key.toId();
        (uint160 slot0_sqrtPriceX96,,,) = poolManager.getSlot0(id);

        uint256 amount0Desired;
        uint256 amount1Desired;

        amount0Desired = uint128(abs(tradeAmount));
        amount1Desired = 2 ** 64;

        uint256 liquidity =
            getLiquidityFromAmounts(slot0_sqrtPriceX96, tickLower, tickUpper, amount0Desired, amount1Desired);

        modifyPosition(
            key, ICLPoolManager.ModifyLiquidityParams(tickLower, tickUpper, -int256(liquidity), bytes32(0)), ""
        );
    }

    function decreaseMarginAmounts(PoolId id, int128 amountBase) private {
        // These should track values in non-USDC token
        marginSwapsAbs[id] -= abs(amountBase);
        marginSwapsNet[id] -= amountBase;
    }

    function increaseMarginAmounts(PoolId id, int128 amountBase) private {
        marginSwapsAbs[id] += abs(amountBase);
        marginSwapsNet[id] += amountBase;
    }

    function getLiquidityFromAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) private pure returns (uint128) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
        return liquidity;
    }

    // Used to calculate 10x leverage on collateral & do funding payments
    function getUSDCValue(bool zeroIsUSDC, uint160 sqrtPriceX96, uint256 baseAmount)
        private
        pure
        returns (uint256 amountUSDC)
    {
        /*
        Use sqrtPriceX96 as price for conversions in a couple spots
        We want price*position to get value of position in USDC
        price = (sqrtPriceX96 / 2**96)**2

        If USDC is token0 formula is:
        ((math.sqrt(amount) * 2**96) / sqrtPrice) ** 2
        If USDC is token1 formula is:
        ((sqrtPriceX96 * math.sqrt(amount)) / 2**96) ** 2

        Think overflow shouldn't be a concern since we use sqrtAmount?
        */

        uint256 sqrtAmount = sqrt(baseAmount);
        if (zeroIsUSDC) {
            // baseAmount should be
            // abs(levPositions[id][msg.sender].position1)
            amountUSDC = FullMath.mulDiv(sqrtAmount, FixedPoint96.Q96, sqrtPriceX96);
        } else {
            // baseAmount should be
            // abs(levPositions[id][msg.sender].position0)
            amountUSDC = FullMath.mulDiv(sqrtPriceX96, sqrtAmount, FixedPoint96.Q96);
        }
        amountUSDC = amountUSDC * amountUSDC;
    }

    /// @notice from https://ethereum.stackexchange.com/questions/84390/absolute-value-in-solidity
    function abs(int128 x) private pure returns (uint128) {
        return x >= 0 ? uint128(x) : uint128(-x);
    }

    /// @notice from https://ethereum.stackexchange.com/questions/2910/can-i-square-root-in-solidity
    /// @notice Calculates the square root of x, rounding down.
    /// @dev Uses the Babylonian method https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method.
    /// @param x The uint256 number for which to calculate the square root.
    /// @return result The result as an uint256.
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) {
            return 0;
        }

        // Calculate the square root of the perfect square of a power of two that is the closest to x.
        uint256 xAux = uint256(x);
        result = 1;
        if (xAux >= 0x100000000000000000000000000000000) {
            xAux >>= 128;
            result <<= 64;
        }
        if (xAux >= 0x10000000000000000) {
            xAux >>= 64;
            result <<= 32;
        }
        if (xAux >= 0x100000000) {
            xAux >>= 32;
            result <<= 16;
        }
        if (xAux >= 0x10000) {
            xAux >>= 16;
            result <<= 8;
        }
        if (xAux >= 0x100) {
            xAux >>= 8;
            result <<= 4;
        }
        if (xAux >= 0x10) {
            xAux >>= 4;
            result <<= 2;
        }
        if (xAux >= 0x8) {
            result <<= 1;
        }

        // The operations can never overflow because the result is max 2^127 when it enters this block.
        unchecked {
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1; // Seven iterations should be enough
            uint256 roundedDownResult = x / result;
            return result >= roundedDownResult ? roundedDownResult : result;
        }
    }
}
