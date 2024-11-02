// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DeployValidlyBase} from 'scripts/base/DeployValidlyBase.sol';
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Validly} from "src/Validly.sol";

contract Default is DeployValidlyBase {
  ERC20Mock public token0;
  ERC20Mock public token1;

  Validly volatilePair;
  Validly stablePair;
  Validly exoticPair;

  address volatilePool;
  address stablePool;
  address exoticPool;

  function run() external {
    vm.startBroadcast(vm.envUint('PRIVATE_KEY'));

    token0 = new ERC20Mock();
    token1 = new ERC20Mock();

    uint256[] memory feeTiers = new uint256[](3);
    
    feeTiers[0] = 10;
    feeTiers[1] = 30;
    feeTiers[2] = 100;

    _deployFactories(feeTiers);

    (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);

    (stablePair, stablePool) = _createPair(address(token1), address(token0), 10, true);
    (volatilePair, volatilePool) = _createPair(address(token0), address(token1), 30, false);
    (exoticPair, exoticPool) = _createPair(address(token0), address(token1), 100, false);

    vm.stopBroadcast();
  }
}