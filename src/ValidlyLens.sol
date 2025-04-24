// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";

import {IValidly} from "./interfaces/IValidly.sol";

/**
 * @title Validly Lens.
 * @notice Helper contract with read-only functions for Validly.
 */
contract ValidlyLens {
    /**
     *
     *  CONSTANTS
     *
     */
    uint256 private constant MIN_LIQUIDITY = 1000;
    uint256 private constant BIPS = 10_000;

    /**
     *
     *  VIEW FUNCTIONS
     *
     */

    /**
     * @notice Simulate deposit liquidity into Validly and mint LP tokens.
     * @param _validly Address of Validly deployment.
     * @param _amount0Max Maximum amount of token0 to deposit.
     * @param _amount1Max Maximum amount of token1 to deposit.
     * @return shares Amount of shares minted.
     * @return amount0 Correct amount of token0 to deposit.
     * @return amount1 Correct amount of token1 to deposit.
     */
    function simulateDeposit(address _validly, uint256 _amount0Max, uint256 _amount1Max)
        external
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        uint256 totalSupplyCache = ERC20(_validly).totalSupply();
        if (totalSupplyCache == 0) {
            amount0 = _amount0Max;
            amount1 = _amount1Max;

            shares = Math.sqrt(amount0 * amount1) - MIN_LIQUIDITY;
        } else {
            ISovereignPool pool = IValidly(_validly).pool();
            (uint256 reserve0, uint256 reserve1) = pool.getReserves();

            uint256 shares0 = Math.mulDiv(_amount0Max, totalSupplyCache, reserve0);
            uint256 shares1 = Math.mulDiv(_amount1Max, totalSupplyCache, reserve1);

            if (shares0 < shares1) {
                shares = shares0;
                amount1 = Math.mulDiv(reserve1, shares, totalSupplyCache, Math.Rounding.Ceil);
                amount0 = _amount0Max;
            } else {
                shares = shares1;
                amount0 = Math.mulDiv(reserve0, shares, totalSupplyCache, Math.Rounding.Ceil);
                amount1 = _amount1Max;
            }
        }
    }

    /**
     * @notice Simulate withdraw liquidity from Validly and burn LP tokens.
     * @param _validly Address of Validly deployment.
     * @param _shares Amount of LP tokens to burn.
     * @return amount0 Amount of token0 withdrawn. WARNING: Potentially innacurate in case token0 is rebase.
     * @return amount1 Amount of token1 withdrawn. WARNING: Potentially innacurate in case token1 is rebase.
     */
    function simulateWithdraw(address _validly, uint256 _shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (_shares == 0) return (0, 0);

        ISovereignPool pool = IValidly(_validly).pool();
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();

        uint256 totalSupplyCache = ERC20(_validly).totalSupply();
        amount0 = Math.mulDiv(reserve0, _shares, totalSupplyCache);
        amount1 = Math.mulDiv(reserve1, _shares, totalSupplyCache);

        if (amount0 == 0 || amount1 == 0) revert("zero_amount_withdrawn");
    }

    /**
     * @notice Simulate swap quote from Validly.
     * @param _validly Address of Validly deployment.
     * @param _isZeroToOne Direction of the swap.
     * @param _amountIn Amount of input token to swap.
     * @return amountOut Amount of output token received after swap.
     */
    function simulateSwap(address _validly, bool _isZeroToOne, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        if (_amountIn == 0) return 0;

        IValidly validly = IValidly(_validly);

        ISovereignPool pool = validly.pool();
        bool isStable = validly.isStable();

        (uint256 reserve0, uint256 reserve1) = pool.getReserves();

        uint256 amountInWithoutFee = Math.mulDiv(_amountIn, BIPS, BIPS + pool.defaultSwapFeeBips());

        (uint256 reserveIn, uint256 reserveOut) = _isZeroToOne ? (reserve0, reserve1) : (reserve1, reserve0);

        uint256 invariant;
        if (isStable) {
            uint256 decimals0 = validly.decimals0();
            uint256 decimals1 = validly.decimals1();

            invariant = _stableInvariant(reserve0, reserve1, decimals0, decimals1);
            // Scale reserves and amounts to 18 decimals
            reserveIn = _isZeroToOne ? (reserveIn * 1e18) / decimals0 : (reserveIn * 1e18) / decimals1;
            reserveOut = _isZeroToOne ? (reserveOut * 1e18) / decimals1 : (reserveOut * 1e18) / decimals0;
            uint256 amountIn =
                _isZeroToOne ? (amountInWithoutFee * 1e18) / decimals0 : (amountInWithoutFee * 1e18) / decimals1;
            amountOut = reserveOut - _get_y_stableInvariant(amountIn + reserveIn, invariant, reserveOut);

            amountOut = (amountOut * (_isZeroToOne ? decimals1 : decimals0)) / 1e18;
        } else {
            invariant = reserve0 * reserve1;

            amountOut = (reserveOut * amountInWithoutFee) / (reserveIn + amountInWithoutFee);
        }
    }

    /**
     *
     *  PRIVATE FUNCTIONS
     *
     */
    function _stableInvariant(uint256 x, uint256 y, uint256 decimals0, uint256 decimals1)
        private
        pure
        returns (uint256)
    {
        uint256 _x = (x * 1e18) / decimals0;
        uint256 _y = (y * 1e18) / decimals1;
        uint256 _a = (_x * _y) / 1e18;
        uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
        return (_a * _b) / 1e18; // x3y+y3x >= k
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
        // Did not converge in 255 fixed point iterations
        revert("stable_invariant_not_converged");
    }
}
