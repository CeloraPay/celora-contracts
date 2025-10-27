// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PaymentGateway} from "../src/PaymentGateway.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        PaymentGateway gateway = new PaymentGateway();
        console2.log("GATEWAY=%s", address(gateway));

        vm.stopBroadcast();
    }
}
