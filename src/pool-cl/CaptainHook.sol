// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@pancakeswap/v4-core/src/types/Currency.sol";
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

import {ICLSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-cl/interfaces/ICLSwapRouterBase.sol";

import {UnsafeMath} from "@pancakeswap/v4-core/src/libraries/math/UnsafeMath.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {DummyERC20} from "../utils/DummyERC20.sol";
import {MathUtils} from "../utils/MathUtils.sol";
import "./Structs.sol";

contract CaptainHook is CLBaseHook {
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

    // keep track of margin fees owed by swappers
    mapping(PoolId => uint256) public swapMarginFeesPerUnit;
    // keep track of funding fees owed between swappers
    mapping(PoolId => int256) public swapFundingFeesPerUnit;

    // Absolute value of margin swaps, so if open positions are [-100, +200], should be 300
    mapping(PoolId => uint256) public marginSwapsAbs;
    // Net value of margin swaps, so if open positions are [-100, +200], should be -100
    mapping(PoolId => int256) public marginSwapsNet;

    error TransactionTooOld();

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionTooOld();
        _;
    }

    constructor(ICLPoolManager _poolManager, address _colTokenAddr) CLBaseHook(_poolManager) {
        colTokenAddr = _colTokenAddr;
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
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
    function marginTrade(
        PoolKey memory key,
        int128 tradeAmount
    ) external payable {
        bool zeroIsUSDC = Currency.unwrap(key.currency0) == colTokenAddr;
        PoolId id = key.toId();
        if (zeroIsUSDC) {
            decreaseMarginAmounts(id, levPositions[id][msg.sender].position1);
        } else {
            decreaseMarginAmounts(id, levPositions[id][msg.sender].position0);
        }
        BalanceDelta delta = execMarginTrade(key, tradeAmount, zeroIsUSDC);

        settleSwapper(id, msg.sender);

        // Track our positions
        levPositions[id][msg.sender].position0 += delta.amount0();
        levPositions[id][msg.sender].position1 += delta.amount1();

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(id);
        uint256 baseAmount = zeroIsUSDC
            ? MathUtils.abs(levPositions[id][msg.sender].position1)
            : MathUtils.abs(levPositions[id][msg.sender].position0);
        uint256 amountUSDC = MathUtils.getUSDCValue(zeroIsUSDC, sqrtPriceX96, baseAmount);

        if (zeroIsUSDC) {
            uint256 sqrtAmount = MathUtils.sqrt(
                MathUtils.abs(levPositions[id][msg.sender].position1)
            );
            amountUSDC = FullMath.mulDiv(
                sqrtAmount,
                FixedPoint96.Q96,
                sqrtPriceX96
            );
            amountUSDC = amountUSDC * amountUSDC;
        } else {
            uint256 sqrtAmount = MathUtils.sqrt(
                MathUtils.abs(levPositions[id][msg.sender].position0)
            );
            amountUSDC = FullMath.mulDiv(
                sqrtPriceX96,
                sqrtAmount,
                FixedPoint96.Q96
            );
            amountUSDC = amountUSDC * amountUSDC;
        }
        // Saying 10x initial margin
        uint collateral10x = collateral[id][msg.sender] * 10;
        require(collateral10x >= amountUSDC, "Not enough collateral");

        levPositions[id][msg.sender]
            .startSwapMarginFeesPerUnit = swapMarginFeesPerUnit[id];
        levPositions[id][msg.sender]
            .startSwapFundingFeesPerUnit = swapFundingFeesPerUnit[id];

        // If they've closed their position, calculate their profit and add to collateral

        bool cond1 = (zeroIsUSDC &&
            (levPositions[id][msg.sender].position1 == 0));
        bool cond2 = (!zeroIsUSDC &&
            (levPositions[id][msg.sender].position0 == 0));
        if (cond1 || cond2) {
            swapperProfitToCollateral(key, msg.sender);
        }

        if (zeroIsUSDC) {
            increaseMarginAmounts(id, levPositions[id][msg.sender].position1);
        } else {
            increaseMarginAmounts(id, levPositions[id][msg.sender].position0);
        }
    }

    function execMarginTrade(PoolKey memory key, int128 tradeAmount, bool zeroIsUSDC)
        private
        returns (BalanceDelta delta)
    {
        removeLiquidity(key, tradeAmount);

        bool zeroForOne;
        if (zeroIsUSDC) {
            // if trade amount is positive and token0 is usdc we are selling token1 for usdc, we are not selling usdc for token1
            // if trade amount is negative and token0 is usdc we are selling usdc for token1
            zeroForOne = tradeAmount > 0 ? false : true;
        } else {
            // if trade amount is positive and token1 is usdc, we are selling token0 for usdc
            // if trade amount is negative and token1 is usdc, we are selling usdc for token0
            zeroForOne = tradeAmount > 0 ? true : false;
        }

        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: tradeAmount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1 // unlimited impact
        });

        SwapTestSettings memory testSettings = SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        delta = swap(key, params, testSettings, "");
    }

    function liquidateSwapper(PoolKey calldata key, address liqSwapper) public {
        PoolId id = key.toId();

        // We can just execute the swap and confirm that it was a valid liquidation
        // based on amounts post-swap, and revert if it's invalid

        bool zeroIsUSDC = Currency.unwrap(key.currency0) == colTokenAddr;
        int128 tradeAmount;
        if (zeroIsUSDC) {
            tradeAmount = -levPositions[id][liqSwapper].position1;
            decreaseMarginAmounts(id, levPositions[id][liqSwapper].position1);
        } else {
            tradeAmount = -levPositions[id][liqSwapper].position0;
            decreaseMarginAmounts(id, levPositions[id][liqSwapper].position0);
        }

        BalanceDelta delta = execMarginTrade(key, tradeAmount, zeroIsUSDC);

        settleSwapper(id, liqSwapper);
        uint256 swapperCol = collateral[id][liqSwapper];
        SwapperPosition memory swapperPos = levPositions[id][liqSwapper];

        // This will be the current position value
        int128 positionVal;
        int128 profitUSDC;
        if (zeroIsUSDC) {
            positionVal = delta.amount0();
            profitUSDC = positionVal - swapperPos.position0;
        } else {
            positionVal = delta.amount1();
            profitUSDC = positionVal - swapperPos.position1;
        }

        uint remainingCollateral;
        if (profitUSDC < 0) {
            remainingCollateral = swapperCol - uint128(-profitUSDC);
        } else {
            remainingCollateral = swapperCol + uint128(profitUSDC);
        }

        // Must be greater than 20x leverage in order to liquidate!
        require(
            MathUtils.abs(positionVal) / remainingCollateral > 20,
            "Invalid liquidation!"
        );

        // Pay a fee to the liquidator
        uint256 liqFee = remainingCollateral / 20;
        DummyERC20(colTokenAddr).transfer(msg.sender, liqFee);

        // And do position accounting
        levPositions[id][liqSwapper].position0 += delta.amount0();
        levPositions[id][liqSwapper].position1 += delta.amount1();

        levPositions[id][liqSwapper]
            .startSwapMarginFeesPerUnit = swapMarginFeesPerUnit[id];
        levPositions[id][liqSwapper]
            .startSwapFundingFeesPerUnit = swapFundingFeesPerUnit[id];

        // This should take care of calculating current swapper collateral
        swapperProfitToCollateral(key, liqSwapper);

        // Don't need to call increaseMarginAmounts because position must be 0!
    }

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
        doFundingMarginPayments(key);
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        doFundingMarginPayments(key);
        return this.beforeRemoveLiquidity.selector;
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

    function settleLP(PoolId id, address addrLP) private {
        // Total margin fees per unit minus the margin fees uints at the time the LP provided liquidity last
        uint256 marginFeesPerUnit = lpMarginFeesPerUnit[id] - lpPositions[id][addrLP].startLpMarginFeesPerUnit;
        // fees per unit is modified by their total liqudity in the pool to get the profit
        uint256 lpProfit = marginFeesPerUnit * lpPositions[id][addrLP].liquidity;
        lpProfits[id][addrLP] += lpProfit;
    }

    function settleSwapper(PoolId id, address addrSwapper) private {
        uint256 marginFeesPerUnit = swapMarginFeesPerUnit[id] - levPositions[id][addrSwapper].startSwapMarginFeesPerUnit;
        uint256 marginPaid = marginFeesPerUnit * MathUtils.abs(levPositions[id][addrSwapper].position0);

        int256 fundingFeesPerUnit =
            swapFundingFeesPerUnit[id] - levPositions[id][addrSwapper].startSwapFundingFeesPerUnit;
        int256 fundingPaid = fundingFeesPerUnit * levPositions[id][addrSwapper].position0;

        collateral[id][addrSwapper] -= marginPaid;
        if (fundingPaid > 0) {
            collateral[id][addrSwapper] += uint256(fundingPaid);
        } else {
            collateral[id][addrSwapper] -= uint256(-fundingPaid);
        }
    }

    function doFundingMarginPayments(PoolKey memory key) private {
        // lpMarginFeesPerUnit is calculated here
        PoolId id = key.toId();

        // calculates how many hourly funding periods have passed since the last funding time
        uint256 num_funding_periods = (block.timestamp - lastFundingTime[id]) / 3600;

        if (num_funding_periods == 0) {
            return;
        }

        // update lastFundingTime to the current time, adjusted for the number of funding periods
        lastFundingTime[id] += (num_funding_periods * 3600);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        bool zeroIsUSDC = Currency.unwrap(key.currency0) == colTokenAddr;

        uint256 amountUSDCAbs = MathUtils.getUSDCValue(zeroIsUSDC, sqrtPriceX96, marginSwapsAbs[id]);

        // 10% annual on position size, charged hourly
        uint256 marginPayment = amountUSDCAbs / 87600;

        if (marginPayment == 0) {
            return;
        }

        uint256 lpMarginAdj = marginPayment / lpLiqTotal[id];
        uint256 swapMarginAdj = marginPayment / marginSwapsAbs[id];

        uint256 amountUSDCNet = MathUtils.getUSDCValue(zeroIsUSDC, sqrtPriceX96, MathUtils.abs(int128(marginSwapsNet[id])));

        /* 
        The constant 17520 scales the annual interest rate of 10% to an hourly rate 
        while considering an additional factor to limit the maximum payment. 
        This ensures that the funding payments are correctly applied at an hourly rate, 
        reflecting the cost of holding leveraged positions over time, 
        and also moderates the payment to a sustainable level.
         */
        int256 fundingPayment = int256(amountUSDCNet) / 17520;
        if (marginSwapsNet[id] < 0) {
            fundingPayment = -fundingPayment;
        }

        int256 swapFundingAdj = fundingPayment / marginSwapsNet[id];

        // The fees per unit for LPs and swappers are updated based on the number of funding periods that have passed.
        lpMarginFeesPerUnit[id] += lpMarginAdj * num_funding_periods;
        swapMarginFeesPerUnit[id] += swapMarginAdj * num_funding_periods;
        swapFundingFeesPerUnit[id] += swapFundingAdj * int256(num_funding_periods);
    }

    function _lpMintBalanceDelta(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 slot0_tick,
        uint160 slot0_sqrtPriceX96
    ) private view returns (BalanceDelta result) {
        if (liquidityDelta != 0) {
            int128 amount0;
            int128 amount1;
            if (slot0_tick < tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
                uint256 amu = getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), uint128(liquidityDelta), false
                );
                amount0 = amu.toInt128();
                result = result + toBalanceDelta(amount0, 0);
            } else if (slot0_tick < tickUpper) {
                uint160 reatioattick = TickMath.getSqrtRatioAtTick(tickUpper);

                uint256 amu = getAmount0Delta(
                    slot0_sqrtPriceX96, reatioattick, uint128(liquidityDelta), false
                );

                amount0 = amu.toInt128();

                uint256 amu1 = getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tickLower), slot0_sqrtPriceX96, uint128(liquidityDelta), false
                );
                amount1 = amu1.toInt128();

                result = result + toBalanceDelta(amount0, amount1);
            } else {
                uint256 amu1 = getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), uint128(liquidityDelta), false
                );
                amount1 = amu1.toInt128();

                result = result + toBalanceDelta(0, amount1);
            }
        }
    }

    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0)
    {
        unchecked {
            if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

            // equivalent: if (sqrtRatioAX96 == 0) revert InvalidPrice();
            assembly ("memory-safe") {
                if iszero(sqrtRatioAX96) {
                    mstore(0, 0x00bfc921) // selector for InvalidPrice()
                    revert(0x1c, 0x04)
                }
            }

            uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
            uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

            return roundUp
                ? UnsafeMath.divRoundingUp(FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), sqrtRatioAX96)
                : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
        }
    }

    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        uint256 numerator = SqrtPriceMath.absDiff(sqrtRatioAX96, sqrtRatioBX96);
        uint256 denominator = FixedPoint96.Q96;
        uint256 _liquidity;
        assembly ("memory-safe") {
            // avoid implicit upcasting
            _liquidity := liquidity
        }
        /**
         * Equivalent to:
         *   amount1 = roundUp
         *       ? FullMath.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96)
         *       : FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
         * Cannot overflow because `type(uint128).max * type(uint160).max >> 96 < (1 << 192)`.
         */
        amount1 = FullMath.mulDiv(_liquidity, numerator, denominator);
        assembly ("memory-safe") {
            amount1 := add(amount1, and(gt(mulmod(_liquidity, numerator, denominator), 0), roundUp))
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

        amount0Desired = uint128(MathUtils.abs(tradeAmount));
        amount1Desired = 2 ** 64;

        uint256 liquidity =
            MathUtils.getLiquidityFromAmounts(slot0_sqrtPriceX96, tickLower, tickUpper, amount0Desired, amount1Desired);

        modifyPosition(
            key, ICLPoolManager.ModifyLiquidityParams(tickLower, tickUpper, -int256(liquidity), bytes32(0)), ""
        );
    }

    function decreaseMarginAmounts(PoolId id, int128 amountBase) private {
        // These should track values in non-USDC token
        marginSwapsAbs[id] -= MathUtils.abs(amountBase);
        marginSwapsNet[id] -= amountBase;
    }

    function increaseMarginAmounts(PoolId id, int128 amountBase) private {
        marginSwapsAbs[id] += MathUtils.abs(amountBase);
        marginSwapsNet[id] += amountBase;
    }

    /// SWAP
    function swap(
        PoolKey memory key,
        ICLPoolManager.SwapParams memory params,
        SwapTestSettings memory testSettings,
        bytes memory hookData
    ) private returns (BalanceDelta delta) {
        delta = abi.decode(
            vault.lock(
                abi.encode("swap", abi.encode(SwapCallbackData(msg.sender, testSettings, key, params, hookData)))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
    }
}
