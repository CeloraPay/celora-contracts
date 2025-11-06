// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { Celora } from "../src/Celora.sol";

contract Deploy is Script {
    function run() external {
        // Start broadcasting to the network using your private key
        vm.startBroadcast();

        // Deploy the Celora contract
        Celora celora = new Celora(); // constructor has no parameters

        // Log deployed address
        console2.log("Celora deployed at:", address(celora));

        vm.stopBroadcast();

        // Optional: Print instructions for verification
        console2.log("Deployment finished. You can now verify the contract on block explorer.");
    }
}
