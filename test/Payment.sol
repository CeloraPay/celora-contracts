// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Payment } from "../src/Payment.sol";
import { Celora } from "../src/Celora.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PaymentUnitTest is Test {
    TestERC20 public token;
    Celora public celora;

    address public owner = address(0x10);
    address public admin = address(0x10);
    address public other = address(0x40);
    address public payer = address(0x20);
    address public receiver = address(0x30);

    function setUp() public {
        token = new TestERC20("T", "T");
        vm.startPrank(owner);
        celora = new Celora();
        celora.enableToken(address(token));
        vm.stopPrank();

        vm.startPrank(admin);
        celora.registerReceiver(receiver, "Shop");
        vm.stopPrank();

        token.mint(payer, 100 ether);
    }

    function _createPayment(
        address _payer,
        address _receiver,
        address _token,
        uint256 _amount,
        uint256 _duration,
        bool _isFiat
    ) internal returns (address, uint256) {
        vm.startPrank(admin);
        (address esc, uint256 id) = celora.createPayment(_payer, _receiver, _token, _amount, _duration, _isFiat);
        vm.stopPrank();
        return (esc, id);
    }

    function test_depositToken_reverts_on_wrong_amount() public {
        (address esc, ) = _createPayment(payer, receiver, address(token), 10 ether, 1 hours, false);

        vm.startPrank(payer);
        token.approve(esc, 5 ether);
        vm.expectRevert();
        Payment(payable(esc)).depositToken(5 ether);
        vm.stopPrank();
    }

    function test_depositNative_and_finalize() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(0), 1 ether, 1 hours, false);

        vm.deal(payer, 2 ether);

        vm.prank(payer);
        (bool ok, ) = payable(esc).call{ value: 1 ether }("");
        require(ok);

        vm.prank(admin);
        bool ok2 = celora.finalizePayment(id, false);
        assertTrue(ok2);

        assertEq(address(celora).balance, (1 ether * 2) / 100);
    }

    function test_depositToken_reverts_if_token_is_native() public {
        (address esc, ) = _createPayment(payer, receiver, address(0), 1 ether, 1 hours, false);

        vm.startPrank(payer);
        vm.expectRevert();
        Payment(payable(esc)).depositToken(1 ether);
        vm.stopPrank();
    }

    function test_depositNative_reverts_if_token_is_erc20() public {
        (address esc, ) = _createPayment(payer, receiver, address(token), 1 ether, 1 hours, false);

        vm.prank(payer);
        (bool ok, ) = payable(esc).call{ value: 1 ether }("");
        assertFalse(ok);
    }

    function test_only_expected_payer_can_deposit_when_set() public {
        (address esc, ) = _createPayment(payer, receiver, address(token), 10 ether, 1 hours, false);

        token.mint(other, 20 ether);
        vm.startPrank(other);
        token.approve(esc, 10 ether);
        vm.expectRevert();
        Payment(payable(esc)).depositToken(10 ether);
        vm.stopPrank();

        token.mint(payer, 10 ether);
        vm.startPrank(payer);
        token.approve(esc, 10 ether);
        Payment(payable(esc)).depositToken(10 ether);
        vm.stopPrank();
    }

    function test_finalize_expired_refund_logic() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 50 ether, 15 minutes, false);

        _depositToken(esc, payer, 50 ether);

        vm.warp(block.timestamp + 16 minutes);

        vm.prank(admin);
        bool ok = celora.finalizePayment(id, false);
        assertFalse(ok);

        assertEq(token.balanceOf(payer), 97.5 ether);
        assertEq(token.balanceOf(address(celora)), 2.5 ether);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_finalize_successful_distribution_logic() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 100 ether, 15 minutes, false);

        _depositToken(esc, payer, 100 ether);

        vm.prank(admin);
        bool ok = celora.finalizePayment(id, false);
        assertTrue(ok);

        assertEq(token.balanceOf(receiver), 98 ether);
        assertEq(token.balanceOf(address(celora)), 2 ether);
    }

    function test_double_finalize_reverts() public {
        (address esc, uint256 id) = _createPayment(payer, receiver, address(token), 10 ether, 15 minutes, false);

        _depositToken(esc, payer, 10 ether);

        vm.prank(admin);
        bool ok = celora.finalizePayment(id, false);
        assertTrue(ok);

        vm.prank(admin);
        vm.expectRevert();
        celora.finalizePayment(id, false);
    }

    function test_direct_finalize_call_reverts_notcelora() public {
        (address esc, ) = _createPayment(payer, receiver, address(token), 10 ether, 15 minutes, false);

        _depositToken(esc, payer, 10 ether);

        vm.expectRevert();
        Payment(payable(esc)).finalize(false);
    }

    function _depositToken(address _escrow, address _payer, uint256 _amount) internal {
        vm.startPrank(_payer);
        token.approve(_escrow, _amount);
        Payment(payable(_escrow)).depositToken(_amount);
        vm.stopPrank();
    }
}
