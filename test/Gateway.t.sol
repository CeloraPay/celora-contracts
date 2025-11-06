// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Gateway } from "../src/Gateway.sol";
import { Payment } from "../src/Payment.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GatewayUnitTest is Test {
    Gateway public gateway;
    TestERC20 public token;

    address public owner = address(0x10);
    address public admin = address(0x10); // owner is admin by constructor
    address public receiver = address(0x12);
    address public payer = address(0x13);
    address public other = address(0x20);

    function setUp() public {
        token = new TestERC20("Test Token", "TTK");

        // Deploy Gateway as owner (owner will be admin too)
        vm.startPrank(owner);
        gateway = new Gateway();
        // enable ERC20 token
        gateway.enableToken(address(token));
        vm.stopPrank();

        // Register receiver (admin)
        vm.startPrank(admin);
        gateway.registerReceiver(receiver, "Shop");
        vm.stopPrank();

        // Mint tokens to payer and other
        token.mint(payer, 1000 ether);
        token.mint(other, 1000 ether);
    }

    // helpers
    function _createPayment(
        address _payer,
        address _receiver,
        address _token,
        uint256 _amount,
        uint256 _duration,
        bool _isFiat
    ) internal returns (address escrowAddr, uint256 invoiceId) {
        vm.startPrank(admin);
        (address esc, uint256 id) = gateway.createPayment(_payer, _receiver, _token, _amount, _duration, _isFiat);
        vm.stopPrank();
        return (esc, id);
    }

    function _depositToken(address _escrow, address _payer, uint256 _amount) internal {
        vm.startPrank(_payer);
        token.approve(_escrow, _amount);
        Payment(payable(_escrow)).depositToken(_amount);
        vm.stopPrank();
    }

    function _transferToEscrow(address _escrow, address _payer, uint256 _amount) internal {
        vm.startPrank(_payer);
        token.approve(_payer, _amount);
        bool success = token.transferFrom(_payer, _escrow, _amount);
        if (!success) revert("Transfer failed");
        vm.stopPrank();
    }

    // ------------------ PAYMENT CREATION & FINALIZE ------------------
    function test_createPayment_and_finalize_with_depositToken() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 100 ether, 15 minutes, false);

        _depositToken(esc, payer, 100 ether);

        vm.prank(admin);
        bool ok = gateway.finalizePayment(id, false);
        assertTrue(ok);

        assertEq(token.balanceOf(receiver), 98 ether);
        assertEq(token.balanceOf(address(gateway)), 2 ether);

        uint256[] memory ready = gateway.getReadyToFinalizeInvoices();
        for (uint256 i = 0; i < ready.length; i++) {
            assertTrue(ready[i] != id);
        }
    }

    function test_createPayment_and_finalize_with_direct_transfer() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 100 ether, 15 minutes, false);

        _transferToEscrow(esc, payer, 100 ether);

        vm.prank(admin);
        bool ok = gateway.finalizePayment(id, false);
        assertTrue(ok);

        assertEq(token.balanceOf(receiver), 98 ether);
        assertEq(token.balanceOf(address(gateway)), 2 ether);

        vm.prank(admin);
        vm.expectRevert();
        gateway.finalizePayment(id, false);
    }

    function test_createPayment_and_finalize_with_too_money_with_depositToken() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 50 ether, 15 minutes, false);

        _depositToken(esc, payer, 50 ether);
        _transferToEscrow(esc, payer, 50 ether);

        vm.prank(admin);
        bool ok = gateway.finalizePayment(id, false);
        assertTrue(ok);

        assertEq(token.balanceOf(receiver), 49 ether);
        assertEq(token.balanceOf(address(gateway)), 1 ether);
        assertEq(token.balanceOf(payer), 950 ether);

        uint256[] memory ready = gateway.getReadyToFinalizeInvoices();
        for (uint256 i = 0; i < ready.length; i++) {
            assertTrue(ready[i] != id);
        }
    }

    function test_createPayment_and_finalize_with_too_money_with_direct() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 50 ether, 15 minutes, false);

        _transferToEscrow(esc, payer, 100 ether);

        vm.prank(admin);
        bool ok = gateway.finalizePayment(id, false);
        assertTrue(ok);

        assertEq(token.balanceOf(receiver), 49 ether);
        assertEq(token.balanceOf(address(gateway)), 51 ether);

        vm.prank(admin);
        vm.expectRevert();
        gateway.finalizePayment(id, false);
    }

    function test_createPayment_and_notPayed_and_expired_finalize() public {
        (, uint256 id) = _createPayment(payer, receiver, address(token), 50 ether, 15 minutes, false);

        vm.warp(block.timestamp + 16 minutes);

        vm.prank(admin);
        bool ok = gateway.finalizePayment(id, false);
        assertTrue(ok);

        assertEq(token.balanceOf(receiver), 0 ether);
        assertEq(token.balanceOf(address(gateway)), 0 ether);
    }

    function test_fiatFlow_gateway_receives_all() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 100 ether, 15 minutes, true);

        _depositToken(esc, payer, 100 ether);

        vm.prank(admin);
        bool ok = gateway.finalizePayment(id, false);
        assertTrue(ok);

        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(address(gateway)), 100 ether);
    }

    function test_expired_forceRefund_behavior() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 50 ether, 15 minutes, false);

        _depositToken(esc, payer, 50 ether);

        vm.warp(block.timestamp + 16 minutes);

        vm.prank(admin);
        bool ok = gateway.finalizePayment(id, true);
        assertFalse(ok);

        assertEq(token.balanceOf(payer), 997.5 ether);
        assertEq(token.balanceOf(address(gateway)), 2.5 ether);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_getReadyToFinalizeInvoices_returns_only_ready() public {
        (address esc1, uint256 id1) = _createPayment(payer, receiver, address(token), 10 ether, 15 minutes, false);
        (, uint256 id2) = _createPayment(payer, receiver, address(token), 20 ether, 15 minutes, false);
        (address esc3, uint256 id3) = _createPayment(payer, receiver, address(token), 30 ether, 15 minutes, false);

        _depositToken(esc1, payer, 10 ether);
        _transferToEscrow(esc3, payer, 30 ether);

        uint256[] memory ready = gateway.getReadyToFinalizeInvoices();

        bool found1 = false;
        bool found3 = false;
        bool found2 = false;
        for (uint256 i = 0; i < ready.length; i++) {
            if (ready[i] == id1) found1 = true;
            if (ready[i] == id3) found3 = true;
            if (ready[i] == id2) found2 = true;
        }
        assertTrue(found1 && found3 && !found2);
    }

    function test_getReadyExpiredToFinalizeInvoices_returns_only_ready() public {
        (, uint256 id1) = _createPayment(payer, receiver, address(token), 10 ether, 20 minutes, false);
        (, uint256 id2) = _createPayment(payer, receiver, address(token), 20 ether, 15 minutes, false);
        (, uint256 id3) = _createPayment(payer, receiver, address(token), 30 ether, 15 minutes, false);

        vm.warp(block.timestamp + 16 minutes);

        uint256[] memory ready = gateway.getReadyToFinalizeInvoices();

        bool found1 = false;
        bool found3 = false;
        bool found2 = false;
        for (uint256 i = 0; i < ready.length; i++) {
            if (ready[i] == id1) found1 = true;
            if (ready[i] == id2) found2 = true;
            if (ready[i] == id3) found3 = true;
        }

        assertTrue(!found1 && found3 && found2);
    }

    function test_onlyAdmin_can_create_and_finalize() public {
        vm.prank(other);
        vm.expectRevert();
        gateway.createPayment(payer, receiver, address(token), 10 ether, 15 minutes, false);

        (, uint256 id) = _createPayment(payer, receiver, address(token), 10 ether, 15 minutes, false);

        vm.prank(other);
        vm.expectRevert();
        gateway.finalizePayment(id, false);
    }

    function test_planCapacity_enforced() public {
        vm.startPrank(owner);
        gateway.definePlan(2, 1);
        vm.stopPrank();

        vm.startPrank(admin);
        gateway.assignPlan(receiver, 2);
        vm.stopPrank();

        _createPayment(payer, receiver, address(token), 1 ether, 1 hours, false);

        vm.prank(admin);
        vm.expectRevert();
        gateway.createPayment(payer, receiver, address(token), 1 ether, 1 hours, false);
    }

    function test_distributeNativeReward_edgeCases() public {
        vm.prank(admin);
        vm.expectRevert();
        gateway.distributeNativeReward(0);

        vm.prank(admin);
        vm.expectRevert();
        gateway.distributeNativeReward(101);

        // normal case
        vm.deal(address(gateway), 10 ether);
        vm.prank(admin);
        gateway.distributeNativeReward(50);

        // pending rewards correctly set
        assertEq(gateway.pendingRewards(receiver), 5 ether);
    }
}
