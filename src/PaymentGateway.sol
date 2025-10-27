// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PaymentEscrow} from "./PaymentEscrow.sol";

error NotOwner();
error NotAdminGateway();
error AlreadyAdmin(address admin);
error NotInitializedReceiver();
error TokenNotEnabled(address token);
error InvalidPercent();

contract PaymentGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    mapping(address => bool) public admins;

    mapping(address => bool) public enabledTokens;
    address[] private tokenList;

    mapping(address => bool) public registeredReceiver;
    address[] public receiversList;

    mapping(uint256 => uint256) public planCapacity;
    mapping(address => uint256) public receiverPlan;
    mapping(address => uint256) public activePayments;

    uint256 public nextInvoiceId;
    mapping(uint256 => address) public invoiceToEscrow;

    mapping(address => uint256) public pendingRewards;

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event TokenEnabled(address indexed token);
    event TokenDisabled(address indexed token);
    event ReceiverRegistered(address indexed receiver);
    event PlanDefined(uint256 indexed planId, uint256 capacity);
    event ReceiverPlanAssigned(address indexed receiver, uint256 planId);
    event ActivePaymentCountChanged(address indexed receiver, uint256 newCount);
    event PaymentCreated(
        uint256 indexed invoiceId,
        address escrowAddress,
        address indexed payer,
        address indexed receiver,
        address token,
        uint256 amount,
        uint256 expiresAt
    );
    event PaymentFinalized(
        uint256 indexed invoiceId,
        address escrowAddress,
        bool success
    );
    event RewardDistributed(
        uint256 percent,
        uint256 totalAmount,
        uint256 perReceiver
    );

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() internal view {
        if (!admins[msg.sender]) revert NotAdminGateway();
    }

    constructor() {
        owner = msg.sender;
        admins[msg.sender] = true;
        enabledTokens[address(0)] = true;
        nextInvoiceId = 1;
        planCapacity[1] = 10;
        emit AdminAdded(msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        address old = owner;
        owner = newOwner;
        emit OwnerChanged(old, newOwner);
    }

    function addAdmin(address _admin) external onlyOwner {
        if (admins[_admin]) revert AlreadyAdmin(_admin);
        admins[_admin] = true;
        emit AdminAdded(_admin);
    }

    function removeAdmin(address _admin) external onlyOwner {
        admins[_admin] = false;
        emit AdminRemoved(_admin);
    }

    function enableToken(address token) external onlyOwner {
        if (!enabledTokens[token]) {
            enabledTokens[token] = true;
            tokenList.push(token);
            emit TokenEnabled(token);
        }
    }

    function disableToken(address token) external onlyOwner {
        enabledTokens[token] = false;
        emit TokenDisabled(token);
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return tokenList;
    }

    function registerReceiver(address receiver) external onlyAdmin {
        if (!registeredReceiver[receiver]) {
            registeredReceiver[receiver] = true;
            receiversList.push(receiver);
            emit ReceiverRegistered(receiver);

            receiverPlan[receiver] = 1;
            emit ReceiverPlanAssigned(receiver, 1);
        }
    }

    function definePlan(uint256 planId, uint256 capacity) external onlyOwner {
        require(capacity > 0, "capacity must be >0");
        planCapacity[planId] = capacity;
        emit PlanDefined(planId, capacity);
    }

    function assignPlan(address receiver, uint256 planId) external onlyAdmin {
        require(registeredReceiver[receiver], "receiver not registered");
        require(planCapacity[planId] > 0, "plan not defined");
        receiverPlan[receiver] = planId;
        emit ReceiverPlanAssigned(receiver, planId);
    }

    function createPayment(
        address payer,
        address receiver,
        address token,
        uint256 amount,
        uint256 durationSeconds,
        bool isFiat
    )
        external
        nonReentrant
        onlyAdmin
        returns (address escrowAddr, uint256 invoiceId)
    {
        if (!enabledTokens[token]) revert TokenNotEnabled(token);
        if (!registeredReceiver[receiver]) revert NotInitializedReceiver();

        uint256 planId = receiverPlan[receiver];
        require(planId != 0, "receiver has no plan assigned");

        uint256 capacity = planCapacity[planId];
        require(
            activePayments[receiver] < capacity,
            "receiver plan limit reached"
        );

        invoiceId = nextInvoiceId++;

        activePayments[receiver] += 1;
        emit ActivePaymentCountChanged(receiver, activePayments[receiver]);

        PaymentEscrow escrow = new PaymentEscrow();
        escrowAddr = address(escrow);

        invoiceToEscrow[invoiceId] = escrowAddr;

        escrow.initialize(
            address(this),
            payer,
            receiver,
            token,
            amount,
            invoiceId,
            durationSeconds,
            isFiat
        );

        emit PaymentCreated(
            invoiceId,
            escrowAddr,
            payer,
            receiver,
            token,
            amount,
            block.timestamp + durationSeconds
        );

        return (escrowAddr, invoiceId);
    }

    function finalizePayment(
        uint256 invoiceId,
        bool forceExpired
    ) external onlyAdmin nonReentrant returns (bool) {
        address escrowAddr = invoiceToEscrow[invoiceId];
        require(escrowAddr != address(0), "invoice not found");

        PaymentEscrow escrow = PaymentEscrow(payable(escrowAddr));

        address rcv = escrow.receiver();

        if (rcv != address(0) && activePayments[rcv] > 0) {
            activePayments[rcv] -= 1;
            emit ActivePaymentCountChanged(rcv, activePayments[rcv]);
        }

        bool success = escrow.finalize(forceExpired);
        emit PaymentFinalized(invoiceId, escrowAddr, success);

        return success;
    }

    receive() external payable {}

    function distributeNativeReward(
        uint256 percent
    ) external onlyAdmin nonReentrant {
        if (percent == 0 || percent > 100) revert InvalidPercent();
        uint256 bal = address(this).balance;
        require(bal > 0, "no native balance");
        uint256 total = (bal * percent) / 100;
        uint256 count = receiversList.length;
        require(count > 0, "no receivers");
        uint256 per = total / count;
        require(per > 0, "share too small");

        for (uint256 i = 0; i < count; i++) {
            pendingRewards[receiversList[i]] += per;
        }

        emit RewardDistributed(percent, total, per);
    }

    function claimReward() external nonReentrant {
        uint256 amount = pendingRewards[msg.sender];
        require(amount > 0, "no reward");
        pendingRewards[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "native transfer failed");
    }

    function withdrawToken(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner {
        require(token != address(0), "use native withdraw");
        IERC20(token).safeTransfer(to, amount);
    }

    function withdrawNative(
        uint256 amount,
        address payable to
    ) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw native failed");
    }

    function getReceiversCount() external view returns (uint256) {
        return receiversList.length;
    }
}
