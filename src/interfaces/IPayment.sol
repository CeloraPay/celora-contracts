// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPayment {
    struct Payment {
        address paymentAddr;
        address payer;
        address receiver;
        address token; // address(0) for native CELO
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

    event PaymentFinalized(
        uint256 indexed _invoiceId,
        address _paymentAddress,
        bool _success
    );

    error PaymentNotFound(address _addr);

    function createPayment(
        address _payer,
        address _receiver,
        address _token,
        uint256 _amount,
        uint256 _durationSeconds,
        bool _receiveFiat
    ) external returns (address _paymentAddr, uint256 _invoiceId);

    function getPayment(
        address _paymnetAddr
    ) external view returns (Payment memory);
}
