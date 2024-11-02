// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';
import 'forge-std/console.sol';

import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {SovereignPool} from "@valantis-core/pools/SovereignPool.sol";
import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {Validly} from "src/Validly.sol";
import {ValidlyFactory} from "src/ValidlyFactory.sol";

abstract contract DeployValidlyBase is Script {
  using stdJson for string;

  mapping(uint256 feeBips => ValidlyFactory factory) validlyFactories;
  ProtocolFactory protocolFactory;
  SovereignPoolFactory poolFactory;

  function _deployFactories(uint256[] memory feeTiers) public {
    protocolFactory = new ProtocolFactory(vm.envAddress('SENDER'));

    poolFactory = new SovereignPoolFactory();

    protocolFactory.setSovereignPoolFactory(address(poolFactory));

    // create a factory for each fee tier
    for (uint256 i = 0; i < feeTiers.length; ) {
        validlyFactories[feeTiers[i]] = new ValidlyFactory(address(protocolFactory), feeTiers[i]);
        ++i;
    }
  }

  function _createPair(address tokenA, address tokenB, uint256 feeBips, bool isStable) internal returns (Validly, address) {
    Validly pair = Validly(validlyFactories[feeBips].createPair(address(tokenA), address(tokenB), isStable));
    return (pair, address(pair.pool()));
  }
}
