// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DeployValidlyBase} from 'scripts/base/DeployValidlyBase.sol';
import {Validly} from "src/Validly.sol";

contract Default is DeployValidlyBase {
  function run() external {
    vm.startBroadcast(vm.envUint('PRIVATE_KEY'));

    uint256[] memory feeTiers = new uint256[](3);
    
    feeTiers[0] = 10;
    feeTiers[1] = 30;
    feeTiers[2] = 100;

    _deployFactories(feeTiers);

    vm.stopBroadcast();
  }
}