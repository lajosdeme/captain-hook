// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET
} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@pancakeswap/v4-core/src/interfaces/IHooks.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {ICLHooks} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/CLPoolManager.sol";
import {DummyERC20} from "../utils/DummyERC20.sol";
import {Currency, CurrencyLibrary} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {CurrencySettlement} from "@pancakeswap/v4-core/test/helpers/CurrencySettlement.sol";
import "forge-std/console.sol";

abstract contract CLBaseHook is ICLHooks {
    using CurrencySettlement for Currency;

    error NotPoolManager();
    error NotVault();
    error NotSelf();
    error InvalidPool();
    error LockFailure();
    error HookNotImplemented();

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

    /// @notice The address of the pool manager
    ICLPoolManager public immutable poolManager;

    /// @notice The address of the vault
    IVault public immutable vault;

    uint8 whichLock;

    constructor(ICLPoolManager _poolManager) {
        poolManager = _poolManager;
        vault = CLPoolManager(address(poolManager)).vault();
    }

    /// @dev Only the pool manager may call this function
    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Only the vault may call this function
    modifier vaultOnly() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @dev Only pools with hooks set to this contract may call this function
    modifier onlyValidPools(IHooks hooks) {
        if (address(hooks) != address(this)) revert InvalidPool();
        _;
    }

    /// @dev Helper function when the hook needs to get a lock from the vault. See
    ///      https://github.com/pancakeswap/pancake-v4-hooks oh hooks which perform vault.lock()
    function lockAcquired(bytes calldata rawData) external virtual vaultOnly returns (bytes memory) {
        (bytes memory action, bytes memory rawCallbackData) = abi.decode(rawData, (bytes, bytes));
        if (keccak256(action) == keccak256("modifyPosition")) {
            return modifyPositionCallback(rawCallbackData);
        } else if (keccak256(action) == keccak256("swap")) {
            return swapCallback(rawCallbackData);
        } else {
            revert("ACTION NOT IMPLEMENTED");
        }
    }

    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _hooksRegistrationBitmapFrom(Permissions memory permissions) internal pure returns (uint16) {
        return uint16(
            (permissions.beforeInitialize ? 1 << HOOKS_BEFORE_INITIALIZE_OFFSET : 0)
                | (permissions.afterInitialize ? 1 << HOOKS_AFTER_INITIALIZE_OFFSET : 0)
                | (permissions.beforeAddLiquidity ? 1 << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET : 0)
                | (permissions.afterAddLiquidity ? 1 << HOOKS_AFTER_ADD_LIQUIDITY_OFFSET : 0)
                | (permissions.beforeRemoveLiquidity ? 1 << HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET : 0)
                | (permissions.afterRemoveLiquidity ? 1 << HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET : 0)
                | (permissions.beforeSwap ? 1 << HOOKS_BEFORE_SWAP_OFFSET : 0)
                | (permissions.afterSwap ? 1 << HOOKS_AFTER_SWAP_OFFSET : 0)
                | (permissions.beforeDonate ? 1 << HOOKS_BEFORE_DONATE_OFFSET : 0)
                | (permissions.afterDonate ? 1 << HOOKS_AFTER_DONATE_OFFSET : 0)
                | (permissions.beforeSwapReturnsDelta ? 1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterSwapReturnsDelta ? 1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterAddLiquidityReturnsDelta ? 1 << HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterRemoveLiquidityReturnsDelta ? 1 << HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET : 0)
        );
    }

    function swapCallback(bytes memory rawData) private returns (bytes memory) {
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));
        console.log("am specified: ", uint256(data.params.amountSpecified));

        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        console.log("in swap callback : ", uint128(delta.amount0()));
        if (data.params.zeroForOne) {
            if (delta.amount0() < 0) {
                bool burn = !data.testSettings.settleUsingTransfer;
                if (burn) {
                    console.log("burn ?");
                    vault.transferFrom(data.sender, address(this), data.key.currency0, uint128(-delta.amount0()));
                    data.key.currency0.settle(vault, address(this), uint128(-delta.amount0()), burn);
                } else {
                    console.log("other - doing settle");
                    data.key.currency0.settle(vault, data.sender, uint128(-delta.amount0()), burn);
                }
            }

            bool claims = !data.testSettings.withdrawTokens;
            if (delta.amount1() > 0) data.key.currency1.take(vault, data.sender, uint128(delta.amount1()), claims);
        } else {
            if (delta.amount1() < 0) {
                bool burn = !data.testSettings.settleUsingTransfer;
                if (burn) {
                    console.log("burn 2 ?");
                    vault.transferFrom(data.sender, address(this), data.key.currency1, uint128(-delta.amount1()));
                    data.key.currency1.settle(vault, address(this), uint128(-delta.amount1()), burn);
                } else {
                    console.log("other - doing settle 2");
                    data.key.currency1.settle(vault, data.sender, uint128(-delta.amount1()), burn);
                }
            }

            bool claims = !data.testSettings.withdrawTokens;
            if (delta.amount0() > 0) data.key.currency0.take(vault, data.sender, uint128(delta.amount0()), claims);
        }

        return abi.encode(delta);
    }

    function modifyPositionCallback(bytes memory rawData) private returns (bytes memory) {
        ModifyPositionCallbackData memory data = abi.decode(rawData, (ModifyPositionCallbackData));

        // delta already takes feeDelta into account
        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(data.key, data.params, data.hookData);

        if (delta.amount0() < 0) data.key.currency0.settle(vault, data.sender, uint128(-delta.amount0()), false);
        if (delta.amount1() < 0) data.key.currency1.settle(vault, data.sender, uint128(-delta.amount1()), false);
        if (delta.amount0() > 0) data.key.currency0.take(vault, data.sender, uint128(delta.amount0()), false);
        if (delta.amount1() > 0) data.key.currency1.take(vault, data.sender, uint128(delta.amount1()), false);

        return abi.encode(delta, feeDelta);
    }
}
