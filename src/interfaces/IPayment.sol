// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPayment {
    event Deposited(address indexed from, uint256 amount);
    event Finalized(bool success, uint256 toReceiver, bool isFiat);
    event Initialized(address _paymentAddress, uint256 _amount, IERC20 _token);

    error NotGateway();
    error NotPayableToken();
    error AlreadyDeposited();
    error FinalizedAlready();
    error AlreadyInitialized();
    error DepositNotExpected();
    error NotAuthorizedPayer();
    error NativeTransferFailed();
    error PaymentNotFound(address _addr);

    function gateway() external view returns (address);
    function payer() external view returns (address);
    function receiver() external view returns (address);
    function token() external view returns (IERC20);
    function depositor() external view returns (address);
    function receiveFiat() external view returns (bool);
    function deposited() external view returns (bool);
    function finalized() external view returns (bool);
    function amount() external view returns (uint256);
    function createdAt() external view returns (uint256);
    function expiresAt() external view returns (uint256);
    function invoiceId() external view returns (uint256);
    function depositedAmount() external view returns (uint256);

    function isPay() external view returns (bool);

    function depositToken(uint256 _amount) external;

    function depositNative() external payable;

    function finalize(bool _forceExpired) external returns (bool, uint256, uint256);

    function initialize(address _gateway, address _payer, address _receiver, IERC20 _token,
        uint256 _amount, uint256 _invoiceId, uint256 _durationSeconds, bool _receiveFiat) external;
}
