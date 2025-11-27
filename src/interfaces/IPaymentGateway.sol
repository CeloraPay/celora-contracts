// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPaymentGateway {
    struct SPayment {
        address paymentAddr;
        address payer;
        address receiver;
        address token; // address(0) for native
        uint256 amount;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 invoiceId;
        bool receiveFiat;
        uint256 depositedAmount;
        bool finalized;
    }

    event PaymentCreated(
        uint256 indexed _invoiceId,
        address _paymentAddress,
        address indexed _payer,
        address indexed _receiver,
        address _token,
        uint256 _amount,
        uint256 _expiresAt
    );

    error PaymentNotFound(address _addr);

    event Deposited(address indexed from, uint256 amount);
    event Finalized(bool success, uint256 toReceiver, bool isFiat);
    event PaymentFinalized(uint256 indexed _invoiceId, address _paymentAddress, bool _success);

    function createPayment(
        address _payer,
        address _receiver,
        address _token,
        uint256 _amount,
        uint256 _durationSeconds,
        bool _receiveFiat
    ) external returns (address _paymentAddr, uint256 _invoiceId);

    function getPayment(address _paymnetAddr) external view returns (SPayment memory);
}
