// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {IValantisPool} from "@valantis-core/pools/interfaces/IValantisPool.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";

import {Validly} from "../src/Validly.sol";
import {ValidlyFactory} from "../src/ValidlyFactory.sol";

contract ValidlyFuzzTest is Test {
    error SovereignPool__swap_zeroAmountInOrOut();

    ValidlyFactory factory;

    ERC20Mock token0;
    ERC20Mock token1;

    address volatilePool;
    address stablePool;

    Validly volatilePair;
    Validly stablePair;

    function setUp() public {
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();

        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);

        ProtocolFactory protocolFactory = new ProtocolFactory(address(this));

        SovereignPoolFactory poolFactory = new SovereignPoolFactory();

        protocolFactory.setSovereignPoolFactory(address(poolFactory));

        // Create ValidlyFactory
        factory = new ValidlyFactory(address(protocolFactory), 1);

        // Create volatile and stable pairs
        volatilePair = Validly(factory.createPair(address(token0), address(token1), false));
        stablePair = Validly(factory.createPair(address(token1), address(token0), true));

        volatilePool = address(volatilePair.pool());
        stablePool = address(stablePair.pool());
    }

    function test_deposit(uint256 reserve0, uint256 reserve1, uint256 totalSupply, uint256 amount0, uint256 amount1)
        public
    {
        reserve0 = bound(reserve0, 1, 1e26);
        reserve1 = bound(reserve1, 1, 1e26);
        totalSupply = bound(totalSupply, 0, 1e26);
        amount0 = bound(amount0, 0, reserve0);
        amount1 = bound(amount1, 0, reserve1);

        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);

        token0.approve(address(volatilePair), amount0);
        token1.approve(address(volatilePair), amount1);

        // Set the total supply of the volatile pair
        vm.store(address(volatilePair), bytes32(uint256(2)), bytes32(totalSupply));
        vm.mockCall(
            volatilePool, abi.encodeWithSelector(ISovereignPool.getReserves.selector), abi.encode(reserve0, reserve1)
        );
        if (totalSupply == 0) {
            uint256 expectedShares = Math.sqrt(amount0 * amount1);

            if (expectedShares < 1000) {
                vm.expectRevert(stdError.arithmeticError);
                volatilePair.deposit(amount0, amount1, 0, block.timestamp + 1, address(1));
                return;
            }

            if (amount0 == 0 || amount1 == 0 || expectedShares == 1000) {
                vm.expectRevert(Validly.Validly__deposit_zeroShares.selector);
                volatilePair.deposit(amount0, amount1, 0, block.timestamp + 1, address(1));
                return;
            }

            (uint256 shares, uint256 amount0Deposited, uint256 amount1Deposited) =
                volatilePair.deposit(amount0, amount1, 0, block.timestamp + 1, address(1));

            assertEq(amount0Deposited, amount0);
            assertEq(amount1Deposited, amount1);
            assertEq(shares, expectedShares - 1000);
        } else {
            uint256 expectedShares =
                Math.min(Math.mulDiv(amount0, totalSupply, reserve0), Math.mulDiv(amount1, totalSupply, reserve1));
            if (amount0 == 0 || amount1 == 0 || expectedShares == 0) {
                vm.expectRevert(Validly.Validly__deposit_zeroShares.selector);
                volatilePair.deposit(amount0, amount1, 0, block.timestamp + 1, address(1));
                return;
            }

            (uint256 shares, uint256 amount0Deposited, uint256 amount1Deposited) =
                volatilePair.deposit(amount0, amount1, 0, block.timestamp + 1, address(1));

            assertLe(amount0Deposited, amount0);
            assertLe(amount1Deposited, amount1);
            assertEq(shares, expectedShares);
        }
    }

    function test_withdraw(uint256 reserve0, uint256 reserve1, uint256 totalSupply, uint256 shares) public {
        reserve0 = bound(reserve0, 1, 1e26);
        reserve1 = bound(reserve1, 1, 1e26);
        totalSupply = bound(totalSupply, 0, 1e26);
        shares = bound(shares, 0, totalSupply);

        token0.mint(volatilePool, reserve0);
        token1.mint(volatilePool, reserve1);

        vm.store(address(volatilePair), bytes32(uint256(2)), bytes32(totalSupply));

        deal(address(volatilePair), address(this), shares);

        vm.store(volatilePool, bytes32(uint256(10)), bytes32(reserve0));
        vm.store(volatilePool, bytes32(uint256(11)), bytes32(reserve1));

        if (shares == 0) {
            vm.expectRevert(Validly.Validly__withdraw_zeroShares.selector);
            volatilePair.withdraw(shares, 0, 0, block.timestamp + 1, address(this));
            return;
        }

        if (totalSupply == 0) {
            vm.expectRevert(stdError.divisionError);
            volatilePair.withdraw(shares, 0, 0, block.timestamp + 1, address(this));
            return;
        }

        uint256 expectedAmount0 = Math.mulDiv(reserve0, shares, totalSupply);
        uint256 expectedAmount1 = Math.mulDiv(reserve1, shares, totalSupply);

        if (expectedAmount0 == 0 || expectedAmount1 == 0) {
            vm.expectRevert(Validly.Validly__withdraw_AmountZero.selector);
            volatilePair.withdraw(shares, 0, 0, block.timestamp + 1, address(this));
            return;
        }

        (uint256 amount0, uint256 amount1) = volatilePair.withdraw(shares, 0, 0, block.timestamp + 1, address(this));

        assertEq(amount0, expectedAmount0);
        assertEq(amount1, expectedAmount1);
    }

    function test_swap_volatile(uint256 reserve0, uint256 reserve1, uint256 amountIn, bool isZeroToOne) public {
        reserve0 = bound(reserve0, 1000, 1e26);
        reserve1 = bound(reserve1, 1000, 1e26);
        amountIn = bound(amountIn, 1, 1e26);

        token0.mint(volatilePool, reserve0);
        token1.mint(volatilePool, reserve1);

        vm.store(volatilePool, bytes32(uint256(10)), bytes32(reserve0));
        vm.store(volatilePool, bytes32(uint256(11)), bytes32(reserve1));

        if (isZeroToOne) {
            token0.mint(address(this), amountIn);
            token0.approve(volatilePool, amountIn);
        } else {
            token1.mint(address(this), amountIn);
            token1.approve(volatilePool, amountIn);
        }

        SovereignPoolSwapParams memory params;

        params.isSwapCallback = false;
        params.isZeroToOne = isZeroToOne;
        params.amountIn = amountIn;
        params.amountOutMin = 0;
        params.deadline = block.timestamp + 1;
        params.recipient = address(this);
        params.swapTokenOut = isZeroToOne ? address(token1) : address(token0);

        uint256 k_pre = reserve0 * reserve1;

        uint256 amountInMinusFee = Math.mulDiv(amountIn, 10000, 10001);
        uint256 expectedAmountOut = isZeroToOne
            ? Math.mulDiv(amountInMinusFee, reserve1, reserve0 + amountInMinusFee)
            : Math.mulDiv(amountInMinusFee, reserve0, reserve1 + amountInMinusFee);

        if (expectedAmountOut == 0) {
            vm.expectRevert(SovereignPool__swap_zeroAmountInOrOut.selector);
            ISovereignPool(volatilePool).swap(params);
            return;
        }

        (uint256 amountInUsed, uint256 amountOut) = ISovereignPool(volatilePool).swap(params);

        uint256 k_post = isZeroToOne
            ? (reserve0 + amountInUsed) * (reserve1 - amountOut)
            : (reserve0 - amountOut) * (reserve1 + amountInUsed);

        assertGe(k_post, k_pre);
    }

    function test_swap_stable(uint256 reserve, uint256 amountIn, bool isZeroToOne) public {
        uint256 reserve0 = bound(reserve, 1e18, 1e26);
        uint256 reserve1 = reserve0;
        amountIn = bound(amountIn, 3, 1e26);

        token0.mint(stablePool, reserve0);
        token1.mint(stablePool, reserve1);

        vm.store(stablePool, bytes32(uint256(10)), bytes32(reserve0));
        vm.store(stablePool, bytes32(uint256(11)), bytes32(reserve1));

        if (isZeroToOne) {
            token0.mint(address(this), amountIn);
            token0.approve(stablePool, amountIn);
        } else {
            token1.mint(address(this), amountIn);
            token1.approve(stablePool, amountIn);
        }

        SovereignPoolSwapParams memory params;

        params.isSwapCallback = false;
        params.isZeroToOne = isZeroToOne;
        params.amountIn = amountIn;
        params.amountOutMin = 0;
        params.deadline = block.timestamp + 1;
        params.recipient = address(this);
        params.swapTokenOut = isZeroToOne ? address(token1) : address(token0);

        uint256 k_pre = _stableInvariant(reserve0, reserve1);

        (uint256 amountInUsed, uint256 amountOut) = ISovereignPool(stablePool).swap(params);

        uint256 k_post = isZeroToOne
            ? _stableInvariant(reserve0 + amountInUsed, reserve1 - amountOut)
            : _stableInvariant(reserve0 - amountOut, reserve1 + amountInUsed);

        assertGe(k_post, k_pre);
    }

    function test_swap_stable_rebase(uint256 reserve, uint256 amountIn, bool isZeroToOne) public {
        uint256 reserve0 = bound(reserve, 1e18, 1e26);
        uint256 reserve1 = reserve0;
        amountIn = bound(amountIn, 1e18, 1e26);

        token0.mint(stablePool, reserve0);
        token1.mint(stablePool, reserve1);

        vm.store(stablePool, bytes32(uint256(10)), bytes32(reserve0));
        vm.store(stablePool, bytes32(uint256(11)), bytes32(reserve1));

        if (isZeroToOne) {
            token0.mint(address(this), amountIn);
            token0.approve(stablePool, amountIn);
        } else {
            token1.mint(address(this), amountIn);
            token1.approve(stablePool, amountIn);
        }

        SovereignPoolSwapParams memory params;

        params.isSwapCallback = false;
        params.isZeroToOne = isZeroToOne;
        params.amountIn = amountIn;
        params.amountOutMin = 0;
        params.deadline = block.timestamp + 1;
        params.recipient = address(this);
        params.swapTokenOut = isZeroToOne ? address(token1) : address(token0);

        uint256 k_pre = _stableInvariant(reserve0, reserve1);

        uint256 snapshot = vm.snapshot();

        vm.prank(address(stablePool));
        ALMLiquidityQuoteInput memory poolInput;
        poolInput.isZeroToOne = isZeroToOne;
        poolInput.feeInBips = 1;
        poolInput.amountInMinusFee = Math.mulDiv(amountIn, 10000, 10001);

        ALMLiquidityQuote memory quote = stablePair.getLiquidityQuote(poolInput, "", "");

        vm.revertTo(snapshot);

        uint256 k_post = isZeroToOne
            ? _stableInvariant(reserve0 + amountIn - 10, reserve1 - quote.amountOut)
            : _stableInvariant(reserve0 - quote.amountOut, reserve1 + amountIn - 10);

        if (k_post < k_pre) {
            vm.expectRevert(Validly.Validly__onSwapCallback_stableInvariantViolated.selector);
            ISovereignPool(stablePool).swap(params);
            return;
        }

        (uint256 amountInUsed, uint256 amountOut) = ISovereignPool(stablePool).swap(params);

        k_post = isZeroToOne
            ? _stableInvariant(reserve0 + amountInUsed - 10, reserve1 - amountOut)
            : _stableInvariant(reserve0 - amountOut, reserve1 + amountInUsed - 10);

        assertGe(k_post, k_pre);
    }

    function _stableInvariant(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 _x = x;
        uint256 _y = y;
        uint256 _a = (_x * _y) / 1e18;
        uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
        return (_a * _b) / 1e18; // x3y+y3x >= k
    }
}
