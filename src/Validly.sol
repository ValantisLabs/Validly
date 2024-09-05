// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISovereignALM} from "@valantis-core/ALM/interfaces/ISovereignALM.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";

/**
 * @title Validly Liquidity Module.
 * @dev UniswapV2 style constant product and Solidly's stable invariant,
 *      implemented as a Valantis Sovereign Liquidity Module.
 */
contract Validly is ISovereignALM, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    /**
     *
     *  ERRORS
     *
     */
    error Validly__deadlineExpired();
    error Validly__onlyPool();
    error Validly__priceOutOfRange();
    error Validly__constructor_customSovereignVaultNotAllowed();
    error Validly__constructor_invalidPool();
    error Validly__deposit_insufficientToken0Deposited();
    error Validly__deposit_insufficientToken1Deposited();
    error Validly__deposit_invalidRecipient();
    error Validly__deposit_lessThanMinShares();
    error Validly__deposit_zeroShares();
    error Validly__getLiquidityQuote_feeInBipsZero();
    error Validly__onSwapCallback_notAllowed();
    error Validly__onSwapCallback_stableInvariantViolated();
    error Validly__withdraw_AmountZero();
    error Validly__withdraw_insufficientToken0Withdrawn();
    error Validly__withdraw_insufficientToken1Withdrawn();
    error Validly__withdraw_zeroShares();
    error Validly__withdraw_invalidRecipient();
    error Validly___get_y_notConverged();

    /**
     *
     *  CONSTANTS
     *
     */
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    bytes32 public constant INVARIANT_CACHE_SLOT = keccak256("validly.invariant");

    /**
     *
     *  IMMUTABLES
     *
     */

    /**
     * @dev SovereignPool is both the entry point contract for swaps (via `swap` function),
     *      and the contract in which token0 and token1 balances should be stored.
     */
    ISovereignPool public immutable pool;

    /**
     * @dev Boolean indicating if the pool is stable or volatile.
     */
    bool public immutable isStable;

    /**
     * @dev Decimals of token0.
     */
    uint256 public immutable decimals0;

    /**
     * @dev Decimals of token1.
     */
    uint256 public immutable decimals1;

    /**
     *
     *  CONSTRUCTOR
     *
     */
    constructor(address _pool, bool _isStable) ERC20("Validly LP Token", "VAL-LP") {
        if (_pool == address(0)) revert Validly__constructor_invalidPool();

        pool = ISovereignPool(_pool);

        if (pool.sovereignVault() != _pool) {
            revert Validly__constructor_customSovereignVaultNotAllowed();
        }

        isStable = _isStable;

        decimals0 = 10 ** IERC20Metadata(pool.token0()).decimals();
        decimals1 = 10 ** IERC20Metadata(pool.token1()).decimals();
    }

    /**
     *
     *  MODIFIERS
     *
     */
    modifier onlyPool() {
        if (msg.sender != address(pool)) {
            revert Validly__onlyPool();
        }
        _;
    }

    modifier ensureDeadline(uint256 deadline) {
        _checkDeadline(deadline);
        _;
    }

    /**
     *
     *  EXTERNAL FUNCTIONS
     *
     */

    /**
     * @notice Deposit liquidity into `pool` and mint LP tokens.
     * @param _amount0 Amount of token0 deposited.
     * @param _amount1 Amount of token1 deposited.
     * @param _minShares Minimum amount of shares to mint.
     * @param _deadline Block timestamp after which this call reverts.
     * @param _recipient Address to mint LP tokens for.
     * @return shares Amount of shares minted.
     */
    function deposit(uint256 _amount0, uint256 _amount1, uint256 _minShares, uint256 _deadline, address _recipient)
        external
        ensureDeadline(_deadline)
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (_recipient == address(0)) {
            revert Validly__deposit_invalidRecipient();
        }

        uint256 totalSupplyCache = totalSupply();
        if (totalSupplyCache == 0) {
            // Minimum token amounts taken as amounts during first deposit
            amount0 = _amount0;
            amount1 = _amount1;

            _mint(address(1), MINIMUM_LIQUIDITY);

            // _shares param is ignored during first deposit
            shares = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
        } else {
            (uint256 reserve0, uint256 reserve1) = pool.getReserves();

            uint256 shares0 = Math.mulDiv(_amount0, totalSupplyCache, reserve0);
            uint256 shares1 = Math.mulDiv(_amount1, totalSupplyCache, reserve1);
            // Normal deposits are made using `onDepositLiquidityCallback`
            if (shares0 < shares1) {
                shares = shares0;
                amount1 = Math.mulDiv(reserve1, shares, totalSupplyCache, Math.Rounding.Ceil);
                amount0 = _amount0;
            } else {
                shares = shares1;
                amount0 = Math.mulDiv(reserve0, shares, totalSupplyCache, Math.Rounding.Ceil);
                amount1 = _amount1;
            }

            // This is a sanity check to ensure that the amounts are not over the amounts specified.
            // This can occur due to rounding errors in mulDiv ceiling.
            if (amount0 > _amount0) {
                revert Validly__deposit_insufficientToken0Deposited();
            }
            if (amount1 > _amount1) {
                revert Validly__deposit_insufficientToken1Deposited();
            }
        }

        if (shares < _minShares) revert Validly__deposit_lessThanMinShares();

        if (shares == 0) revert Validly__deposit_zeroShares();

        _mint(_recipient, shares);

        (amount0, amount1) = pool.depositLiquidity(amount0, amount1, msg.sender, "", abi.encode(msg.sender));
    }

    /**
     * @notice Withdraw liquidity from `pool` and burn LP tokens.
     * @param _shares Amount of LP tokens to burn.
     * @param _amount0Min Minimum amount of token0 required for `_recipient`.
     * @param _amount1Min Minimum amount of token1 required for `_recipient`.
     * @param _deadline Block timestamp after which this call reverts.
     * @param _recipient Address to receive token0 and token1 amounts.
     * @return amount0 Amount of token0 withdrawn. WARNING: Potentially innacurate in case token0 is rebase.
     * @return amount1 Amount of token1 withdrawn. WARNING: Potentially innacurate in case token1 is rebase.
     */
    function withdraw(uint256 _shares, uint256 _amount0Min, uint256 _amount1Min, uint256 _deadline, address _recipient)
        external
        ensureDeadline(_deadline)
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (_shares == 0) revert Validly__withdraw_zeroShares();

        if (_recipient == address(0)) {
            revert Validly__withdraw_invalidRecipient();
        }

        (uint256 reserve0, uint256 reserve1) = pool.getReserves();

        uint256 totalSupplyCache = totalSupply();
        amount0 = Math.mulDiv(reserve0, _shares, totalSupplyCache);
        amount1 = Math.mulDiv(reserve1, _shares, totalSupplyCache);

        if (amount0 == 0 || amount1 == 0) revert Validly__withdraw_AmountZero();

        // Slippage protection checks
        if (amount0 < _amount0Min) {
            revert Validly__withdraw_insufficientToken0Withdrawn();
        }
        if (amount1 < _amount1Min) {
            revert Validly__withdraw_insufficientToken1Withdrawn();
        }

        _burn(msg.sender, _shares);

        pool.withdrawLiquidity(amount0, amount1, msg.sender, _recipient, "");
    }

    /**
     * @notice Callback to transfer tokens from user into `pool` during deposits.
     */
    function onDepositLiquidityCallback(uint256 _amount0, uint256 _amount1, bytes memory _data)
        external
        override
        onlyPool
    {
        address user = abi.decode(_data, (address));

        if (_amount0 > 0) {
            IERC20Metadata(pool.token0()).safeTransferFrom(user, msg.sender, _amount0);
        }

        if (_amount1 > 0) {
            IERC20Metadata(pool.token1()).safeTransferFrom(user, msg.sender, _amount1);
        }
    }

    /**
     * @notice Swap callback from pool.
     * @param _poolInput Contains fundamental data about the swap.
     * @return quote Quote information that prices tokenIn and tokenOut.
     */
    function getLiquidityQuote(
        ALMLiquidityQuoteInput memory _poolInput,
        bytes calldata, /*_externalContext*/
        bytes calldata /*_verifierData*/
    ) external override onlyPool returns (ALMLiquidityQuote memory quote) {
        if (_poolInput.feeInBips == 0) {
            revert Validly__getLiquidityQuote_feeInBipsZero();
        }

        (uint256 reserve0, uint256 reserve1) = pool.getReserves();

        (uint256 reserveIn, uint256 reserveOut) = _poolInput.isZeroToOne ? (reserve0, reserve1) : (reserve1, reserve0);

        if (isStable) {
            uint256 stableInvariant = _stableInvariant(reserve0, reserve1);
            // Scale reserves and amounts to 18 decimals
            reserveIn = _poolInput.isZeroToOne ? (reserveIn * 1e18) / decimals0 : (reserveIn * 1e18) / decimals1;
            reserveOut = _poolInput.isZeroToOne ? (reserveOut * 1e18) / decimals1 : (reserveOut * 1e18) / decimals0;
            uint256 amountIn = _poolInput.isZeroToOne
                ? (_poolInput.amountInMinusFee * 1e18) / decimals0
                : (_poolInput.amountInMinusFee * 1e18) / decimals1;
            uint256 amountOut = reserveOut - _get_y_stableInvariant(amountIn + reserveIn, stableInvariant, reserveOut);

            quote.amountOut = (amountOut * (_poolInput.isZeroToOne ? decimals1 : decimals0)) / 1e18;
            quote.isCallbackOnSwap = true;
            _cacheInvariant();
        } else {
            quote.amountOut = (reserveOut * _poolInput.amountInMinusFee) / (reserveIn + _poolInput.amountInMinusFee);
        }

        quote.amountInFilled = _poolInput.amountInMinusFee;
    }

    /**
     * @notice Callback to check invariant after swap.
     */
    function onSwapCallback(bool, /*_isZeroToOne*/ uint256, /*_amountIn*/ uint256 /*_amountOut*/ )
        external
        override
        onlyPool
    {
        if (isStable) {
            (uint256 reserve0, uint256 reserve1) = pool.getReserves();
            uint256 invariant = _stableInvariant(reserve0, reserve1);
            if (invariant < _getCachedInvariant()) {
                revert Validly__onSwapCallback_stableInvariantViolated();
            }
            _clearInvariant();
        } else {
            revert Validly__onSwapCallback_notAllowed();
        }
    }

    /**
     *
     *  PRIVATE FUNCTIONS
     *
     */
    function _checkDeadline(uint256 _deadline) private view {
        if (block.timestamp > _deadline) {
            revert Validly__deadlineExpired();
        }
    }

    function _f(uint256 x0, uint256 y) private pure returns (uint256) {
        return (x0 * ((((y * y) / 1e18) * y) / 1e18)) / 1e18 + (((((x0 * x0) / 1e18) * x0) / 1e18) * y) / 1e18;
    }

    function _d(uint256 x0, uint256 y) private pure returns (uint256) {
        return (3 * x0 * ((y * y) / 1e18)) / 1e18 + ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    function _get_y_stableInvariant(uint256 x0, uint256 invariant, uint256 y) private pure returns (uint256) {
        for (uint256 i = 0; i < 255; i++) {
            uint256 y_prev = y;
            uint256 k = _f(x0, y);
            if (k < invariant) {
                uint256 dy = ((invariant - k) * 1e18) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - invariant) * 1e18) / _d(x0, y);
                y = y - dy;
            }
            if (y > y_prev) {
                if (y - y_prev <= 1) {
                    return y;
                }
            } else {
                if (y_prev - y <= 1) {
                    return y;
                }
            }
        }
        // Did not converge in 256 fixed point iterations,
        // revert for safety
        revert Validly___get_y_notConverged();
    }

    function _stableInvariant(uint256 x, uint256 y) private view returns (uint256) {
        uint256 _x = (x * 1e18) / decimals0;
        uint256 _y = (y * 1e18) / decimals1;
        uint256 _a = (_x * _y) / 1e18;
        uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
        return (_a * _b) / 1e18; // x3y+y3x >= k
    }

    function _cacheInvariant() internal {
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        uint256 invariant = _stableInvariant(reserve0, reserve1);
        bytes32 invariantSlot = INVARIANT_CACHE_SLOT;
        assembly {
            tstore(invariantSlot, invariant)
        }
    }

    function _getCachedInvariant() internal view returns (uint256) {
        uint256 invariant;
        bytes32 invariantSlot = INVARIANT_CACHE_SLOT;
        assembly {
            invariant := tload(invariantSlot)
        }
        return invariant;
    }

    function _clearInvariant() internal {
        bytes32 invariantSlot = INVARIANT_CACHE_SLOT;
        assembly {
            tstore(invariantSlot, 0)
        }
    }
}
