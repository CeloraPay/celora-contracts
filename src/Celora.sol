// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Payment } from "./Payment.sol";
import { IGateway } from "./interfaces/IGateway.sol";

contract Celora is ReentrancyGuard, AccessControl, IGateway {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public owner;
    address[] private tokenList;
    address[] public paymentsList;
    address[] public receiversList;

    uint256 public nextInvoiceId;
    uint256[] private activeInvoiceIds;

    mapping(address => bool) public admins;
    mapping(address => SPayment) private payments;
    mapping(address => bool) public enabledTokens;
    mapping(address => Receiver) private receivers;
    mapping(uint256 => uint256) public planCapacity;
    mapping(uint256 => bool) public isActiveInvoice;
    mapping(address => uint256) public pendingRewards;
    mapping(uint256 => address) public invoiceToPayment;
    mapping(address => address[]) private receiverTokens;
    mapping(address => mapping(address => uint256)) private receiversTokenAmounts;

    modifier onlyOwner() {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        enabledTokens[address(0)] = true;
        nextInvoiceId = 1;
        planCapacity[1] = 10;
        emit AdminAdded(msg.sender);
    }

    receive() external payable {}

    /// @notice Get all supported tokens
    /// @return Array of token addresses
    function getSupportedTokens() external view returns (address[] memory) {
        return tokenList;
    }

    /// @notice Check if an address is admin
    /// @param _addr Address to check
    /// @return True if admin
    function isAdmin(address _addr) external view returns (bool) {
        return admins[_addr];
    }

    /// @notice Get SPayment info by payment contract address
    /// @param _addr Payment contract address
    /// @return SPayment struct
    function getPayment(address _addr) external view returns (SPayment memory) {
        if (payments[_addr].paymentAddr == address(0)) revert PaymentNotFound(_addr);
        return payments[_addr];
    }

    /// @notice Check if a token is enabled
    /// @param _token Token address
    /// @return True if token is enabled
    function isTokenEnabled(address _token) external view returns (bool) {
        return enabledTokens[_token];
    }

    /// @notice Get receiver struct
    /// @param _addr Receiver address
    /// @return Receiver struct
    function getReceiverStruct(address _addr) external view returns (Receiver memory) {
        if (receivers[_addr].addr == address(0)) revert ReceiverNotFound(_addr);
        return receivers[_addr];
    }

    /// @notice Get capacity of a plan
    /// @param _planId Plan ID
    /// @return Capacity
    function getPlanCapacity(uint256 _planId) external view returns (uint256) {
        return planCapacity[_planId];
    }

    /// @notice Check if invoice is active
    /// @param _invoiceId Invoice ID
    /// @return True if active
    function isInvoiceActive(uint256 _invoiceId) external view returns (bool) {
        return isActiveInvoice[_invoiceId];
    }

    /// @notice Get pending reward for an address
    /// @param _addr Address of receiver
    /// @return Pending reward amount
    function getPendingReward(address _addr) external view returns (uint256) {
        return pendingRewards[_addr];
    }

    /// @notice Get payment contract address by invoice ID
    /// @param _invoiceId Invoice ID
    /// @return Payment contract address
    function getPaymentByInvoice(uint256 _invoiceId) external view returns (address) {
        return invoiceToPayment[_invoiceId];
    }

    /// @notice Get list of token addresses held by a receiver
    /// @param _receiver Receiver address
    /// @return Array of token addresses
    function getReceiverTokens(address _receiver) external view returns (address[] memory) {
        return receiverTokens[_receiver];
    }

    /// @notice Get token balance for a receiver
    /// @param _receiver Receiver address
    /// @param _token Token address
    /// @return Token amount
    function getReceiverTokenAmount(address _receiver, address _token) external view returns (uint256) {
        return receiversTokenAmounts[_receiver][_token];
    }

    /// @notice Get receiver info and token balances
    /// @param _addr Receiver address
    /// @return receiver Receiver struct
    /// @return tokenData Array of TokenAmount structs
    function getReceiver(address _addr) external view returns (Receiver memory, TokenAmount[] memory) {
        if (receivers[_addr].addr == address(0)) {
            revert ReceiverNotFound(_addr);
        }

        address[] memory tokens = receiverTokens[_addr];
        TokenAmount[] memory tokenData = new TokenAmount[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            tokenData[i] = TokenAmount({ token: tokens[i], amount: receiversTokenAmounts[_addr][tokens[i]] });
        }

        return (receivers[_addr], tokenData);
    }

    /// @notice Transfer contract ownership to newOwner
    /// @param newOwner Address of new owner
    function transferOwnership(address newOwner) external onlyOwner {
        grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);

        emit OwnerChanged(msg.sender, newOwner);
    }

    /// @notice Add a new admin
    /// @param _admin Address to grant ADMIN_ROLE
    function addAdmin(address _admin) external onlyOwner {
        if (hasRole(ADMIN_ROLE, _admin)) revert AlreadyAdmin(_admin);

        grantRole(ADMIN_ROLE, _admin);

        emit AdminAdded(_admin);
    }

    /// @notice Remove an admin
    /// @param _admin Address to revoke ADMIN_ROLE
    function removeAdmin(address _admin) external onlyOwner {
        if (!hasRole(ADMIN_ROLE, _admin)) revert NotAdminGateway(_admin);

        revokeRole(ADMIN_ROLE, _admin);

        emit AdminRemoved(_admin);
    }

    /// @notice Enable a token for payments
    /// @param token Token address to enable
    function enableToken(address token) external onlyOwner {
        if (!enabledTokens[token]) {
            enabledTokens[token] = true;
            tokenList.push(token);
            emit TokenEnabled(token);
        }
    }

    /// @notice Disable a token for payments
    /// @param token Token address to disable
    function disableToken(address token) external onlyOwner {
        enabledTokens[token] = false;
        emit TokenDisabled(token);
    }

    /// @notice Register a receiver
    /// @param _addr Receiver address
    /// @param _name Receiver name
    function registerReceiver(address _addr, string calldata _name) external onlyAdmin {
        if (receivers[_addr].addr != address(0)) {
            revert ReceiverAlreadyRegistered(_addr);
        }

        Receiver storage r = receivers[_addr];
        r.addr = _addr;
        r.planId = 1;
        r.name = _name;
        receiversList.push(_addr);

        emit ReceiverRegistered(_addr, 1);
    }

    /// @notice Define plan capacity
    /// @param planId Plan ID
    /// @param capacity Max active payments
    function definePlan(uint256 planId, uint256 capacity) external onlyOwner {
        if (capacity <= 0) revert InvalidPlanCapacity(capacity);

        planCapacity[planId] = capacity;

        emit PlanDefined(planId, capacity);
    }

    /// @notice Assign plan to receiver
    /// @param receiver Receiver address
    /// @param planId Plan ID
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

    /// @notice Create a new payment
    /// @param payer Payer address
    /// @param receiver Receiver address
    /// @param token Token address
    /// @param amount Payment amount
    /// @param durationSeconds Payment expiration in seconds
    /// @param receiveFiat Flag if payment is fiat
    /// @return paymentAddr Address of created payment contract
    /// @return invoiceId Invoice ID
    function createPayment(
        address payer,
        address receiver,
        address token,
        uint256 amount,
        uint256 durationSeconds,
        bool receiveFiat
    ) external nonReentrant onlyAdmin returns (address paymentAddr, uint256 invoiceId) {
        if (!enabledTokens[token]) revert TokenNotEnabled(token);
        if (receivers[receiver].addr == address(0)) revert NotInitializedReceiver(receiver);

        uint256 planId = receivers[receiver].planId;

        uint256 capacity = planCapacity[planId];
        if (receivers[receiver].activePayments >= capacity) revert ReceiverPlanLimit(capacity);

        invoiceId = nextInvoiceId++;

        receivers[receiver].activePayments += 1;
        receivers[receiver].invoiceIds.push(invoiceId);
        emit ActivePaymentCountChanged(receiver, receivers[receiver].activePayments);

        Payment payment = new Payment();
        paymentAddr = address(payment);

        invoiceToPayment[invoiceId] = paymentAddr;
        activeInvoiceIds.push(invoiceId);
        isActiveInvoice[invoiceId] = true;

        payments[paymentAddr] = SPayment({
            paymentAddr: paymentAddr,
            payer: payer,
            receiver: receiver,
            token: token,
            amount: amount,
            invoiceId: invoiceId,
            receiveFiat: receiveFiat,
            depositedAmount: 0,
            finalized: false,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + durationSeconds
        });

        payment.initialize(
            address(this),
            payer,
            receiver,
            IERC20(token),
            amount,
            invoiceId,
            durationSeconds,
            receiveFiat
        );

        emit PaymentCreated(invoiceId, paymentAddr, payer, receiver, token, amount, block.timestamp + durationSeconds);

        return (paymentAddr, invoiceId);
    }

    /// @notice Get all invoices ready to finalize
    /// @return Array of invoice IDs
    function getReadyToFinalizeInvoices() external view returns (uint256[] memory) {
        uint256 len = activeInvoiceIds.length;
        uint256[] memory tmp = new uint256[](len);
        uint256 idx = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 invoiceId = activeInvoiceIds[i];
            address paymentAddr = invoiceToPayment[invoiceId];
            if (paymentAddr == address(0)) continue;

            Payment payment = Payment(payable(paymentAddr));

            try payment.isPay() returns (bool payed) {
                if ((!payed && block.timestamp > payment.expiresAt()) || (payed && !payment.finalized())) {
                    tmp[idx++] = invoiceId;
                }
            } catch {
                continue;
            }
        }

        uint256[] memory readyIds = new uint256[](idx);
        for (uint256 i = 0; i < idx; i++) {
            readyIds[i] = tmp[i];
        }

        return readyIds;
    }

    /// @notice Finalize a payment
    /// @param invoiceId Invoice ID
    /// @param forceExpired Force expired finalization
    /// @return success True if payment finalized successfully
    function finalizePayment(uint256 invoiceId, bool forceExpired) external onlyAdmin nonReentrant returns (bool) {
        address paymentAddr = invoiceToPayment[invoiceId];
        if (paymentAddr == address(0)) revert InvoiceNotFound(invoiceId);

        Payment payment = Payment(payable(paymentAddr));

        address rcv = payment.receiver();
        bool expired = block.timestamp > payment.expiresAt();
        bool isPayed = payment.isPay();

        if (!isPayed && expired) {
            _finalizeNotPayAndExpired(invoiceId);

            return true;
        }

        if (!isPayed) revert InvoiceNotPayed(invoiceId);

        _updateReceiverActivePayment(rcv);

        (bool success, uint256 receiveAmount, uint256 toReceiverAmount) = payment.finalize(forceExpired);

        IERC20 token = payment.token();
        address tokenAddr = address(token);

        if (receiversTokenAmounts[rcv][tokenAddr] == 0) {
            receiverTokens[rcv].push(tokenAddr);
        }

        receiversTokenAmounts[rcv][tokenAddr] += toReceiverAmount;
        payments[paymentAddr].depositedAmount = receiveAmount;
        payments[paymentAddr].finalized = success;

        _changeIsActiveInvoice(invoiceId);

        emit PaymentFinalized(invoiceId, paymentAddr, success);

        return success;
    }

    /// @notice Distribute native rewards to receivers
    /// @param percent Percentage of native balance to distribute
    function distributeNativeReward(uint256 percent) external onlyAdmin nonReentrant {
        if (percent == 0 || percent > 100) revert InvalidPercent();

        uint256 bal = address(this).balance;
        if (bal == 0) revert NoNativeBalance();

        uint256 total = (bal * percent) / 100;
        uint256 count = receiversList.length;
        if (count == 0) revert NoReceivers();

        uint256 per = total / count;
        if (per == 0) revert ShareTooSmall();

        for (uint256 i = 0; i < count; i++) {
            pendingRewards[receiversList[i]] += per;
        }

        emit RewardDistributed(percent, total, per);
    }

    /// @notice Claim pending reward for sender
    function claimReward() external nonReentrant {
        uint256 amount = pendingRewards[msg.sender];
        if (amount == 0) revert NoReward();

        pendingRewards[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @notice Withdraw ERC20 token from gateway
    /// @param token Token address
    /// @param amount Amount to withdraw
    /// @param to Recipient address
    function withdrawToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(0)) revert UseNativeWithdraw();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Withdraw native from gateway
    /// @param amount Amount to withdraw
    /// @param to Recipient address
    function withdrawNative(uint256 amount, address payable to) external onlyOwner {
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert WithdrawNativeFailed();
    }

    /// @notice Get number of registered receivers
    /// @return Count of receivers
    function getReceiversCount() external view returns (uint256) {
        return receiversList.length;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _onlyAdmin() internal view {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert NotAdminGateway(msg.sender);
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

    function _finalizeNotPayAndExpired(uint256 invoiceId) internal {
        address paymentAddr = invoiceToPayment[invoiceId];
        Payment payment = Payment(payable(paymentAddr));
        address rcv = payment.receiver();

        _updateReceiverActivePayment(rcv);
        _changeIsActiveInvoice(invoiceId);

        payments[paymentAddr].finalized = true;
    }

    function _changeIsActiveInvoice(uint256 invoiceId) internal {
        if (isActiveInvoice[invoiceId]) {
            isActiveInvoice[invoiceId] = false;
            _removeActiveInvoice(invoiceId);
        }
    }

    function _updateReceiverActivePayment(address receiver) internal {
        if (receiver != address(0) && receivers[receiver].activePayments > 0) {
            receivers[receiver].activePayments -= 1;
            emit ActivePaymentCountChanged(receiver, receivers[receiver].activePayments);
        }
    }
}
