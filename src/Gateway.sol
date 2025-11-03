// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Payment} from "./Payment.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";
import {IPayment} from "./interfaces/IPayment.sol";

error NotOwner();
error NotAdminGateway();
error AlreadyAdmin(address admin);
error NotInitializedReceiver();
error TokenNotEnabled(address token);
error InvalidPercent();

contract Gateway is ReentrancyGuard, IReceiver, IPayment {
    using SafeERC20 for IERC20;

    address public owner;
    mapping(address => bool) public admins;

    mapping(address => bool) public enabledTokens;
    address[] private tokenList;

    mapping(address => Receiver) private receivers;
    address[] public receiversList;

    mapping(address => SPayment) private payments;
    address[] public paymentsList;

    mapping(uint256 => uint256) public planCapacity;

    uint256 public nextInvoiceId;
    mapping(uint256 => address) public invoiceToPayment;

    uint256[] private activeInvoiceIds;
    mapping(uint256 => bool) public isActiveInvoice;

    mapping(address => uint256) public pendingRewards;

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event TokenEnabled(address indexed token);
    event TokenDisabled(address indexed token);
    event PlanDefined(uint256 indexed planId, uint256 capacity);

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

    function registerReceiver(
        address _addr,
        string calldata _description
    ) external onlyAdmin {
        if (receivers[_addr].addr != address(0)) {
            revert ReceiverAlreadyRegistered(_addr);
        }

        Receiver storage r = receivers[_addr];

        r.addr = _addr;
        r.planId = 1;
        r.description = _description;
        r.receivedAmount = 0;
        receiversList.push(_addr);

        emit ReceiverRegistered(_addr, 1);
    }

    function getReceiver(
        address _addr
    ) external view returns (Receiver memory) {
        if (receivers[_addr].addr == address(0)) {
            revert ReceiverNotFound(_addr);
        }

        return receivers[_addr];
    }

    function definePlan(uint256 planId, uint256 capacity) external onlyOwner {
        require(capacity > 0, "capacity must be >0");
        planCapacity[planId] = capacity;
        emit PlanDefined(planId, capacity);
    }

    function assignPlan(address receiver, uint256 planId) external onlyAdmin {
        if (receivers[receiver].addr == address(0)) {
            revert ReceiverNotFound(receiver);
        }

        if (planCapacity[planId] == 0) {
            revert InvalidPlan(planId);
        }

        receivers[receiver].planId = planId;
        emit ReceiverPlanAssigned(receiver, planId);
    }

    function createPayment(
        address payer,
        address receiver,
        address token,
        uint256 amount,
        uint256 durationSeconds,
        bool receiveFiat
    )
        external
        nonReentrant
        onlyAdmin
        returns (address paymentAddr, uint256 invoiceId)
    {
        if (!enabledTokens[token]) revert TokenNotEnabled(token);
        if (receivers[receiver].addr == address(0))
            revert NotInitializedReceiver();

        uint256 planId = receivers[receiver].planId;
        require(planId != 0, "receiver has no plan assigned");

        uint256 capacity = planCapacity[planId];
        require(
            receivers[receiver].activePayments < capacity,
            "receiver plan limit reached"
        );

        invoiceId = nextInvoiceId++;

        receivers[receiver].activePayments += 1;
        receivers[receiver].invoiceIds.push(invoiceId);
        emit ActivePaymentCountChanged(
            receiver,
            receivers[receiver].activePayments
        );

        Payment payment = new Payment();
        paymentAddr = address(payment);

        invoiceToPayment[invoiceId] = paymentAddr;
        activeInvoiceIds.push(invoiceId);
        isActiveInvoice[invoiceId] = true;

        payment.initialize(
            address(this),
            payer,
            receiver,
            token,
            amount,
            invoiceId,
            durationSeconds,
            receiveFiat
        );

        SPayment storage p = payments[paymentAddr];
        p.paymentAddr = paymentAddr;
        p.payer = payer;
        p.receiver = receiver;
        p.token = token;
        p.amount = amount;
        p.invoiceId = invoiceId;
        p.receiveFiat = receiveFiat;
        p.depositedAmount = 0;
        p.finalized = false;
        p.createdAt = block.timestamp;
        p.expiresAt = block.timestamp + durationSeconds;

        emit PaymentCreated(
            invoiceId,
            paymentAddr,
            payer,
            receiver,
            token,
            amount,
            block.timestamp + durationSeconds
        );

        return (paymentAddr, invoiceId);
    }

    function getPayment(address _addr) external view returns (SPayment memory) {
        if (payments[_addr].paymentAddr == address(0)) {
            revert PaymentNotFound(_addr);
        }

        return payments[_addr];
    }

    function _removeActiveInvoice(uint256 invoiceId) internal {
        uint256 len = activeInvoiceIds.length;

        for (uint256 i = 0; i < len; i++) {
            if (activeInvoiceIds[i] == invoiceId) {
                activeInvoiceIds[i] = activeInvoiceIds[len - 1];
                activeInvoiceIds.pop();
                break;
            }
        }
    }

    function getReadyToFinalizeInvoices()
        external
        view
        returns (uint256[] memory)
    {
        uint256 len = activeInvoiceIds.length;
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 id = activeInvoiceIds[i];
            address paymentAddr = invoiceToPayment[id];

            if (paymentAddr == address(0)) continue;

            Payment payment = Payment(payable(paymentAddr));

            try payment.isPay() returns (bool payed) {
                if (payed && !payment.finalized()) {
                    count++;
                }
            } catch {
                continue;
            }
        }

        uint256[] memory readyIds = new uint256[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 id = activeInvoiceIds[i];
            address paymentAddr = invoiceToPayment[id];

            if (paymentAddr == address(0)) continue;

            Payment payment = Payment(payable(paymentAddr));

            try payment.isPay() returns (bool payed) {
                if (payed && !payment.finalized()) {
                    readyIds[idx++] = id;
                }
            } catch {
                continue;
            }
        }

        return readyIds;
    }

    function finalizePayment(
        uint256 invoiceId,
        bool forceExpired
    ) external onlyAdmin nonReentrant returns (bool) {
        address paymentAddr = invoiceToPayment[invoiceId];
        require(paymentAddr != address(0), "invoice not found");

        Payment payment = Payment(payable(paymentAddr));

        bool isPayed = payment.isPay();
        require(isPayed, "invoice not payed");    

        address rcv = payment.receiver();

        if (rcv != address(0) && receivers[rcv].activePayments > 0) {
            receivers[rcv].activePayments -= 1;
            emit ActivePaymentCountChanged(rcv, receivers[rcv].activePayments);
        }

        (
            bool success,
            uint256 receiveAmount,
            uint256 toReceiverAmount
        ) = payment.finalize(forceExpired);
        emit PaymentFinalized(invoiceId, paymentAddr, success);

        receivers[rcv].receivedAmount += toReceiverAmount;
        payments[paymentAddr].depositedAmount = receiveAmount;
        payments[paymentAddr].finalized = success;

        if (isActiveInvoice[invoiceId]) {
            isActiveInvoice[invoiceId] = false;
            _removeActiveInvoice(invoiceId);
        }

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
