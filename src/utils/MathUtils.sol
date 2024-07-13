// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "@pancakeswap/v4-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {FullMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "@pancakeswap/v4-core/src/pool-cl/libraries/FixedPoint96.sol";

library MathUtils {
    // Used to calculate 10x leverage on collateral & do funding payments
    function getUSDCValue(bool zeroIsUSDC, uint160 sqrtPriceX96, uint256 baseAmount)
        internal
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

    function getLiquidityFromAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal pure returns (uint128) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
        return liquidity;
    }

    /// @notice from https://ethereum.stackexchange.com/questions/84390/absolute-value-in-solidity
    function abs(int128 x) internal pure returns (uint128) {
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
