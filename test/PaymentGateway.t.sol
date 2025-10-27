// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PaymentGateway} from "../src/PaymentGateway.sol";
import {PaymentEscrow} from "../src/PaymentEscrow.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PaymentGatewayTest is Test {
    using SafeERC20 for IERC20;

    PaymentGateway public gateway;
    TestERC20 public token;

    address public owner = address(0x10);
    address public admin = address(0x10);
    address public receiver = address(0x12);
    address public payer = address(0x13);

    uint256 public paymentId;
    address payable public escrowAddr;

    function setUp() public {
        token = new TestERC20("Test Token", "TTK");

        // Deploy Gateway as owner
        vm.startPrank(owner);
        gateway = new PaymentGateway();

        // Enable token
        gateway.enableToken(address(token));
        vm.stopPrank();

        // Register receiver & assign plan
        vm.startPrank(admin);
        gateway.registerReceiver(receiver);
        vm.stopPrank();

        // Mint tokens to payer
        token.mint(payer, 1000 ether);

        // Approve gateway for ERC20 transfers
        vm.startPrank(payer);
        token.approve(address(gateway), type(uint256).max);
        vm.stopPrank();
    }

    function test_CreatePaymentAndFinalize_Success() public {
        // Create payment
        vm.startPrank(admin);
        (address escrowAddrTemp, uint256 invoiceId) = gateway.createPayment(
            payer,
            receiver,
            address(token),
            100 ether,
            15 minutes
        );
        escrowAddr = payable(escrowAddrTemp);
        paymentId = invoiceId;
        vm.stopPrank();

        // Deposit tokens via escrow
        vm.startPrank(payer);
        token.approve(escrowAddr, 100 ether);
        PaymentEscrow(escrowAddr).depositToken(100 ether);
        vm.stopPrank();

        // Finalize payment
        vm.prank(admin);
        bool success = gateway.finalizePayment(paymentId, false);

        assertTrue(success);
        assertEq(token.balanceOf(receiver), 95 ether); // 5% fee
        assertEq(token.balanceOf(address(gateway)), 5 ether);
    }

    function test_ForceFinalize_ExpiredPayment() public {
        // Create payment
        vm.startPrank(admin);
        (address escrowAddrTemp, uint256 invoiceId) = gateway.createPayment(
            payer,
            receiver,
            address(token),
            50 ether,
            15 minutes
        );
        escrowAddr = payable(escrowAddrTemp);
        paymentId = invoiceId;
        vm.stopPrank();

        // Deposit tokens via escrow
        vm.startPrank(payer);
        token.approve(escrowAddr, 50 ether);
        PaymentEscrow(escrowAddr).depositToken(50 ether);
        vm.stopPrank();

        // Warp past expiration
        vm.warp(block.timestamp + 16 minutes);

        // Force finalize
        vm.prank(admin);
        bool success = gateway.finalizePayment(paymentId, true);

        assertFalse(success);
        assertEq(token.balanceOf(receiver), 0); // expired -> receiver gets 0
        assertEq(token.balanceOf(payer), 995 ether); // refunded 90%
        assertEq(token.balanceOf(address(gateway)), 5 ether); // 10% fee
    }

    function test_ReentrancyBlocked() public {
        // Create payment
        vm.startPrank(admin);
        (address escrowAddrTemp, uint256 invoiceId) = gateway.createPayment(
            payer,
            receiver,
            address(token),
            10 ether,
            15 minutes
        );
        escrowAddr = payable(escrowAddrTemp);
        paymentId = invoiceId;
        vm.stopPrank();

        // Deposit tokens
        vm.startPrank(payer);
        token.approve(escrowAddr, 10 ether);
        PaymentEscrow(escrowAddr).depositToken(10 ether);
        vm.stopPrank();

        // Finalize payment
        vm.prank(admin);
        bool success = gateway.finalizePayment(paymentId, false);
        assertTrue(success);

        // Reentrancy check: finalize again should fail
        vm.expectRevert();
        PaymentEscrow(escrowAddr).finalize(false);
    }
}
