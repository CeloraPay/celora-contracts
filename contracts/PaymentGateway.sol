// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./PaymentEscrow.sol";

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

    // allowed payment tokens (token address => enabled). address(0) reserved for native CELO
    mapping(address => bool) public enabledTokens;
    address[] private tokenList;

    // receivers must be registered before they can receive payments
    mapping(address => bool) public registeredReceiver;
    address[] public receiversList;

    // payments created
    uint256 public nextInvoiceId;
    mapping(uint256 => address) public invoiceToEscrow;

    // pull pattern for native rewards
    mapping(address => uint256) public pendingRewards;

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event TokenEnabled(address indexed token);
    event TokenDisabled(address indexed token);
    event ReceiverRegistered(address indexed receiver);
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
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert NotAdminGateway();
        _;
    }

    constructor() {
        owner = msg.sender;
        admins[msg.sender] = true;
        enabledTokens[address(0)] = true; // native CELO enabled by default
        nextInvoiceId = 1;
        emit AdminAdded(msg.sender);
    }

    // Owner management
    function transferOwnership(address newOwner) external onlyOwner {
        address old = owner;
        owner = newOwner;
        emit OwnerChanged(old, newOwner);
    }

    // Admin management (owner can add/remove)
    function addAdmin(address _admin) external onlyOwner {
        if (admins[_admin]) revert AlreadyAdmin(_admin);
        admins[_admin] = true;
        emit AdminAdded(_admin);
    }

    function removeAdmin(address _admin) external onlyOwner {
        admins[_admin] = false;
        emit AdminRemoved(_admin);
    }

    // Enable / disable tokens
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

    // register receiver
    function registerReceiver(address receiver) external onlyAdmin {
        if (!registeredReceiver[receiver]) {
            registeredReceiver[receiver] = true;
            receiversList.push(receiver);
            emit ReceiverRegistered(receiver);
        }
    }

    // create payment — only admin
    function createPayment(
        address payer,
        address receiver,
        address token,
        uint256 amount,
        uint256 durationSeconds
    )
        external
        nonReentrant
        onlyAdmin
        returns (address escrowAddr, uint256 invoiceId)
    {
        // checks
        if (!enabledTokens[token]) revert TokenNotEnabled(token);
        if (!registeredReceiver[receiver]) revert NotInitializedReceiver();

        // effects
        invoiceId = nextInvoiceId++;
        // deploy escrow
        PaymentEscrow escrow = new PaymentEscrow();
        escrowAddr = address(escrow);

        // record mapping BEFORE external call (prevents some reentrancy classes)
        invoiceToEscrow[invoiceId] = escrowAddr;

        // interactions
        escrow.initialize(
            address(this),
            payer,
            receiver,
            token,
            amount,
            invoiceId,
            durationSeconds
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
    }

    // finalize: only admin calls gateway.finalizePayment -> gateway calls escrow.finalize
    function finalizePayment(
        uint256 invoiceId,
        bool forceExpired
    ) external onlyAdmin nonReentrant returns (bool) {
        address escrowAddr = invoiceToEscrow[invoiceId];
        require(escrowAddr != address(0), "invoice not found");

        PaymentEscrow escrow = PaymentEscrow(payable(escrowAddr));
        bool success = escrow.finalize(forceExpired);
        emit PaymentFinalized(invoiceId, escrowAddr, success);
        return success;
    }

    // Allow gateway to receive native CELO fees from escrows
    receive() external payable {}

    // Distribute percent% of gateway's native CELO balance equally among all registered receivers,
    // but use Pull pattern: add to pendingRewards for each receiver, they claim later.
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

    // claim pending native reward (pull)
    function claimReward() external nonReentrant {
        uint256 amount = pendingRewards[msg.sender];
        require(amount > 0, "no reward");
        pendingRewards[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "native transfer failed");
    }

    // Helper: withdraw ERC20 fees collected in gateway to owner
    function withdrawToken(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner {
        require(token != address(0), "use native withdraw");
        IERC20(token).safeTransfer(to, amount);
    }

    // Helper: withdraw native
    function withdrawNative(
        uint256 amount,
        address payable to
    ) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw native failed");
    }

    // view helpers
    function getReceiversCount() external view returns (uint256) {
        return receiversList.length;
    }
}
