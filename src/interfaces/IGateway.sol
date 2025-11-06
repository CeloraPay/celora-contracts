// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IReceiver } from "./IReceiver.sol";
import { IPaymentGateway } from "./IPaymentGateway.sol";

interface IGateway is IReceiver, IPaymentGateway {
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event TokenEnabled(address indexed token);
    event TokenDisabled(address indexed token);
    event PlanDefined(uint256 indexed planId, uint256 capacity);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event RewardDistributed(uint256 percent, uint256 totalAmount, uint256 perReceiver);

    error NotOwner();
    error NoReward();
    error NoReceivers();
    error ShareTooSmall();
    error InvalidPercent();
    error NoNativeBalance();
    error UseNativeWithdraw();
    error NativeTransferFailed();
    error WithdrawNativeFailed();
    error AlreadyAdmin(address admin);
    error NotAdminGateway(address admin);
    error TokenNotEnabled(address token);
    error InvoiceNotFound(uint256 invoiceId);
    error InvoiceNotPayed(uint256 invoiceId);
    error ReceiverPlanLimit(uint256 capacity);
    error InvalidPlanCapacity(uint256 capacity);
    error NotInitializedReceiver(address receiver);

    function getReceiversCount() external view returns (uint256);

    function isAdmin(address _addr) external view returns (bool);

    function isTokenEnabled(address _token) external view returns (bool);

    function getSupportedTokens() external view returns (address[] memory);

    function getPendingReward(address _addr) external view returns (uint256);

    function isInvoiceActive(uint256 _invoiceId) external view returns (bool);

    function getPlanCapacity(uint256 _planId) external view returns (uint256);

    function getPayment(address _addr) external view returns (SPayment memory);

    function getReadyToFinalizeInvoices() external view returns (uint256[] memory);

    function getPaymentByInvoice(uint256 _invoiceId) external view returns (address);

    function getReceiverStruct(address _addr) external view returns (Receiver memory);

    function getReceiverTokens(address _receiver) external view returns (address[] memory);

    function getReceiverTokenAmount(address _receiver, address _token) external view returns (uint256);

    function claimReward() external;

    function addAdmin(address _admin) external;

    function enableToken(address token) external;

    function removeAdmin(address _admin) external;

    function disableToken(address token) external;

    function transferOwnership(address newOwner) external;

    function distributeNativeReward(uint256 percent) external;

    function definePlan(uint256 planId, uint256 capacity) external;

    function assignPlan(address receiver, uint256 planId) external;

    function withdrawNative(uint256 amount, address payable to) external;

    function registerReceiver(address _addr, string calldata _name) external;

    function withdrawToken(address token, uint256 amount, address to) external;

    function finalizePayment(uint256 invoiceId, bool forceExpired) external returns (bool);

    function getReceiver(
        address _addr
    ) external view returns (Receiver memory receiver, TokenAmount[] memory tokenData);

    function createPayment(
        address payer,
        address receiver,
        address token,
        uint256 amount,
        uint256 durationSeconds,
        bool receiveFiat
    ) external returns (address paymentAddr, uint256 invoiceId);
}
