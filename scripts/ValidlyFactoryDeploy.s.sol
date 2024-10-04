// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {ValidlyFactory} from "../src/ValidlyFactory.sol";

contract ValidlyFactoryDeploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address protocolFactory = vm.envAddress("PROTOCOL_FACTORY");
        uint256 feeBips = vm.envUint("FEE_BIPS_VALIDLY_FACTORY");

        vm.startBroadcast(deployerPrivateKey);

        new ValidlyFactory(protocolFactory, feeBips);

        vm.stopBroadcast();
    }
}
