// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Gateway} from "../src/Gateway.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        Gateway gateway = new Gateway();
        console2.log("GATEWAY=%s", address(gateway));

        vm.stopBroadcast();
    }
}
