// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {
    SovereignPoolSwapParams,
    SovereignPoolConstructorArgs
} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {SovereignPool} from "@valantis-core/pools/SovereignPool.sol";

import {Validly} from "../src/Validly.sol";
import {ValidlyFactory} from "../src/ValidlyFactory.sol";

contract ValidlyFactoryTest is Test {
    ValidlyFactory public factory;
    ERC20Mock public token0;
    ERC20Mock public token1;
    ProtocolFactory protocolFactory;

    function setUp() public {
        // Create dummy tokens
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();

        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);

        protocolFactory = new ProtocolFactory(address(this));

        SovereignPoolFactory poolFactory = new SovereignPoolFactory();

        protocolFactory.setSovereignPoolFactory(address(poolFactory));

        // Create ValidlyFactory
        factory = new ValidlyFactory(address(protocolFactory), 1);
    }

    function test_constructor() public {
        assertEq(address(factory.protocolFactory()), address(protocolFactory));
        assertEq(factory.feeBips(), 1);

        vm.expectRevert(ValidlyFactory.ValidlyFactory__constructor_invalidFeeBips.selector);

        new ValidlyFactory(address(protocolFactory), 10001);
    }

    function test_createPair() public {
        factory.createPair(address(token0), address(token1), true);

        vm.expectRevert(ValidlyFactory.ValidlyFactory__createPair_alreadyDeployed.selector);

        factory.createPair(address(token0), address(token1), true);
    }

    function test_createPool() public {
        SovereignPoolConstructorArgs memory args = SovereignPoolConstructorArgs(
            address(token0),
            address(token1),
            address(protocolFactory),
            address(this),
            address(0),
            address(0),
            true,
            true,
            5,
            5,
            0
        );

        address pair = factory.createPool(args, true);

        assertEq(Validly(pair).pool().token0(), address(token0));
        assertEq(Validly(pair).pool().token1(), address(token1));
    }

    function test_setPoolManagerFeeBips() public {
        test_createPair();

        bytes32 key = keccak256(abi.encode(address(token0), address(token1), true));

        address pool = factory.pools(key);

        vm.expectRevert(ValidlyFactory.ValidlyFactory__onlyProtocolManager.selector);
        vm.prank(makeAddr("ALICE"));
        factory.setPoolManagerFeeBips(pool, 100);

        factory.setPoolManagerFeeBips(pool, 100);

        assertEq(ISovereignPool(pool).poolManagerFeeBips(), 100);
    }

    function test_claimFees() public {
        test_createPair();

        bytes32 key = keccak256(abi.encode(address(token0), address(token1), true));

        address pool = factory.pools(key);

        vm.store(address(pool), bytes32(uint256(5)), bytes32(uint256(1e18)));
        vm.store(address(pool), bytes32(uint256(6)), bytes32(uint256(10e18)));

        factory.claimFees(pool);

        assertEq(SovereignPool(pool).feeProtocol0(), 1e18);
        assertEq(SovereignPool(pool).feeProtocol1(), 10e18);
    }

    function test_claimTokens() public {
        token0.mint(address(factory), 1e18);

        address ALICE = makeAddr("ALICE");

        vm.expectRevert(ValidlyFactory.ValidlyFactory__onlyProtocolManager.selector);
        vm.prank(ALICE);
        factory.claimTokens(address(token0), ALICE);

        vm.expectRevert(ValidlyFactory.ValidlyFactory__claimTokens_invalidToken.selector);
        factory.claimTokens(address(0), ALICE);

        vm.expectRevert(ValidlyFactory.ValidlyFactory__claimTokens_invalidRecipient.selector);
        factory.claimTokens(address(token0), address(0));

        factory.claimTokens(address(token0), ALICE);

        assertEq(token0.balanceOf(ALICE), 1e18);
    }
}
