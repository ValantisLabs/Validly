// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ALMLiquidityQuoteInput} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";

import {Validly} from "../src/Validly.sol";
import {ValidlyFactory} from "../src/ValidlyFactory.sol";

contract ValidlyTest is Test {
    ValidlyFactory public factory;
    ERC20Mock public token0;
    ERC20Mock public token1;

    Validly public volatilePair;
    Validly public stablePair;
    ISovereignPool public volatilePool;
    ISovereignPool public stablePool;

    function setUp() public {
        // Create dummy tokens
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();

        ProtocolFactory protocolFactory = new ProtocolFactory(address(this));

        SovereignPoolFactory poolFactory = new SovereignPoolFactory();

        protocolFactory.setSovereignPoolFactory(address(poolFactory));

        // Create ValidlyFactory
        factory = new ValidlyFactory(address(protocolFactory), 1);

        // Create volatile and stable pairs
        volatilePair = Validly(factory.createPair(address(token0), address(token1), false));
        stablePair = Validly(factory.createPair(address(token1), address(token0), true));

        volatilePool = volatilePair.pool();
        stablePool = stablePair.pool();
    }

    function test_constructor() public {
        assertEq(address(volatilePair.pool()), address(volatilePool));
        assertEq(address(stablePair.pool()), address(stablePool));

        assertEq(volatilePair.isStable(), false);
        assertEq(stablePair.isStable(), true);

        vm.mockCall(
            address(volatilePool),
            abi.encodeWithSelector(ISovereignPool.sovereignVault.selector),
            abi.encode(address(volatilePair))
        );
        vm.expectRevert(Validly.Validly__constructor_customSovereignVaultNotAllowed.selector);
        new Validly(address(volatilePool), false);

        assertEq(volatilePair.decimals0(), 1e18);
        assertEq(volatilePair.decimals1(), 1e18);
    }

    function test_deposit() public {
        vm.warp(block.timestamp + 1);

        vm.expectRevert(Validly.Validly__deadlineExpired.selector);
        volatilePair.deposit(10 ether, 0, 0, block.timestamp - 1, address(0));

        vm.expectRevert(Validly.Validly__deposit_invalidRecipient.selector);
        volatilePair.deposit(10 ether, 0, 0, block.timestamp + 1, address(0));

        vm.expectRevert(Validly.Validly__deposit_lessThanMinShares.selector);
        volatilePair.deposit(10000, 10000, 10000, block.timestamp + 1, address(this));

        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);

        token0.approve(address(volatilePair), 1000 ether);
        token1.approve(address(volatilePair), 1000 ether);

        volatilePair.deposit(1 ether, 10 ether, 0, block.timestamp + 1, address(this));

        volatilePair.deposit(1 ether, 20 ether, 0, block.timestamp + 1, address(this));

        vm.expectRevert(Validly.Validly__deposit_zeroShares.selector);
        volatilePair.deposit(1 ether, 0, 0, block.timestamp + 1, address(this));
    }

    function test_withdraw() public {
        test_deposit();

        uint256 shares = volatilePair.balanceOf(address(this));

        vm.expectRevert(Validly.Validly__deadlineExpired.selector);
        volatilePair.withdraw(shares, 0, 0, block.timestamp - 1, address(0));

        vm.expectRevert(Validly.Validly__withdraw_zeroShares.selector);
        volatilePair.withdraw(0, 0, 0, block.timestamp + 1, address(this));

        vm.expectRevert(Validly.Validly__withdraw_invalidRecipient.selector);
        volatilePair.withdraw(shares, 0, 0, block.timestamp + 1, address(0));

        uint256 sharesToWithdraw = shares / 2;

        (uint256 reserve0, uint256 reserve1) = volatilePool.getReserves();
        uint256 expectedAmount0 = Math.mulDiv(reserve0, sharesToWithdraw, volatilePair.totalSupply());
        uint256 expectedAmount1 = Math.mulDiv(reserve1, sharesToWithdraw, volatilePair.totalSupply());

        vm.expectRevert(Validly.Validly__withdraw_AmountZero.selector);
        volatilePair.withdraw(1, 0, 0, block.timestamp + 1, address(this));

        vm.expectRevert(Validly.Validly__withdraw_insufficientToken0Withdrawn.selector);
        volatilePair.withdraw(sharesToWithdraw, 100 ether, 0, block.timestamp + 1, address(this));

        vm.expectRevert(Validly.Validly__withdraw_insufficientToken1Withdrawn.selector);
        volatilePair.withdraw(sharesToWithdraw, 0, 100 ether, block.timestamp + 1, address(this));

        (uint256 amount0, uint256 amount1) =
            volatilePair.withdraw(sharesToWithdraw, 0, 0, block.timestamp + 1, address(this));

        assertEq(amount0, expectedAmount0);
        assertEq(amount1, expectedAmount1);
    }

    function test_getLiquidityQuote_stable() public {
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);

        token0.approve(address(stablePair), 1000 ether);
        token1.approve(address(stablePair), 1000 ether);

        stablePair.deposit(100 ether, 100 ether, 0, block.timestamp + 1, address(this));

        SovereignPoolSwapParams memory params;

        params.isSwapCallback = false;
        params.isZeroToOne = true;
        params.amountIn = 1 ether;
        params.amountOutMin = 0;
        params.deadline = block.timestamp + 1;
        params.recipient = address(this);
        params.swapTokenOut = address(token0);

        token1.approve(address(stablePool), 1 ether);

        (uint256 amountInUsed, uint256 amountOut) = stablePool.swap(params);

        assertApproxEqAbs(amountOut, amountInUsed, Math.mulDiv(amountInUsed, 1, 1000));
    }

    function test_getLiquidityQuote_volatile() public {
        test_deposit();

        ALMLiquidityQuoteInput memory input;
        input.amountInMinusFee = 1 ether;
        input.isZeroToOne = true;
        vm.prank(address(volatilePool));
        vm.expectRevert(Validly.Validly__getLiquidityQuote_feeInBipsZero.selector);
        volatilePair.getLiquidityQuote(input, "", "");

        SovereignPoolSwapParams memory params;

        params.isSwapCallback = false;
        params.isZeroToOne = true;
        params.amountIn = 1 ether;
        params.amountOutMin = 0;
        params.deadline = block.timestamp + 1;
        params.recipient = address(this);
        params.swapTokenOut = address(token0);

        (uint256 reserve0, uint256 reserve1) = volatilePool.getReserves();

        token0.approve(address(volatilePool), 1 ether);
        token1.approve(address(volatilePool), 10 ether);

        (uint256 amountInUsed, uint256 amountOut) = volatilePool.swap(params);

        uint256 expectedAmountOut = Math.mulDiv(
            reserve1, Math.mulDiv(amountInUsed, 10000, 10001), reserve0 + Math.mulDiv(amountInUsed, 10000, 10001)
        );

        assertEq(amountOut, expectedAmountOut);
    }

    function test_onDepositLiquidityCallback() public {
        vm.expectRevert(Validly.Validly__onlyPool.selector);
        volatilePair.onDepositLiquidityCallback(0, 0, abi.encode(address(0)));

        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        token0.approve(address(volatilePair), 100 ether);
        token1.approve(address(volatilePair), 100 ether);

        vm.prank(address(volatilePool));
        volatilePair.onDepositLiquidityCallback(1 ether, 1 ether, abi.encode(address(this)));

        assertEq(token0.balanceOf(address(volatilePool)), 1 ether);
        assertEq(token1.balanceOf(address(volatilePool)), 1 ether);
    }

    function test_onSwapCallback() public {
        vm.expectRevert(Validly.Validly__onlyPool.selector);
        volatilePair.onSwapCallback(false, 0, 0);

        vm.prank(address(volatilePool));
        vm.expectRevert(Validly.Validly__onSwapCallback_notAllowed.selector);
        volatilePair.onSwapCallback(true, 1 ether, 1 ether);

        vm.mockCall(
            address(stablePair),
            abi.encodeWithSelector(ISovereignPool.getReserves.selector),
            abi.encode(1 ether, 1 ether)
        );

        vm.prank(address(stablePool));
        stablePair.onSwapCallback(true, 1 ether, 1 ether);

        vm.mockCall(
            address(stablePool),
            abi.encodeWithSelector(ISovereignPool.getReserves.selector),
            abi.encode(1 ether, 1 ether)
        );

        vm.prank(address(stablePool));
        ALMLiquidityQuoteInput memory input;
        input.amountInMinusFee = 1 ether;
        input.isZeroToOne = true;
        input.feeInBips = 1;
        stablePair.getLiquidityQuote(input, "", "");

        vm.prank(address(stablePool));
        vm.mockCall(
            address(stablePool), abi.encodeWithSelector(ISovereignPool.getReserves.selector), abi.encode(5e17, 5e17)
        );
        vm.expectRevert(Validly.Validly__onSwapCallback_stableInvariantViolated.selector);
        stablePair.onSwapCallback(true, 5e17, 5e17);
    }
}
