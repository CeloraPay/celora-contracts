// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPayment } from "./interfaces/IPayment.sol";

contract Payment is ReentrancyGuard, IPayment {
    using SafeERC20 for IERC20;

     /// @notice Gateway address that deployed this contract
    address public gateway;

    /// @notice Expected depositor address (can be address(0) meaning anyone)
    address public payer;

    /// @notice Final recipient of the funds
    address public receiver;

    /// @notice Actual depositor address
    address public depositor;

    /// @notice ERC20 token contract; zero address means native CELO
    IERC20 public token;

    /// @notice Flag indicating if payment is in fiat
    bool public receiveFiat;

    /// @notice Flag indicating whether the payment has been deposited
    bool public deposited;

    /// @notice Flag indicating whether the payment has been finalized
    bool public finalized;

    /// @notice Expected deposit amount (wei)
    uint256 public amount;

    /// @notice Timestamp when contract was initialized
    uint256 public createdAt;

    /// @notice Timestamp when payment expires
    uint256 public expiresAt;

    /// @notice Unique invoice ID
    uint256 public invoiceId;

    /// @notice Actual deposited amount
    uint256 public depositedAmount;

    /// @notice Restricts function to only be called by the gateway
    modifier onlyGateway() {
        _onlyGateway();
        _;
    }

    /// @notice Sets the deploying address as the gateway
    constructor() {
        gateway = msg.sender;
    }

    /// @notice Initializes the payment contract
    /// @param _gateway Gateway address
    /// @param _payer Expected depositor
    /// @param _receiver Final recipient
    /// @param _token ERC20 token contract; use zero address for native CELO
    /// @param _amount Expected deposit amount
    /// @param _invoiceId Invoice ID
    /// @param _durationSeconds Duration in seconds until expiration
    /// @param _receiveFiat Whether payment is in fiat
    function initialize(
        address _gateway,
        address _payer,
        address _receiver,
        IERC20 _token,
        uint256 _amount,
        uint256 _invoiceId,
        uint256 _durationSeconds,
        bool _receiveFiat
    ) external onlyGateway {
        if (createdAt != 0) revert AlreadyInitialized();

        gateway = _gateway; // set canonical gateway (same as deployer normally)
        payer = _payer;
        receiver = _receiver;
        token = _token;
        amount = _amount;
        invoiceId = _invoiceId;
        receiveFiat = _receiveFiat;
        createdAt = block.timestamp;
        expiresAt = block.timestamp + _durationSeconds;

        emit Initialized(address(this), _amount, _token);
    }

    /// @notice Deposit ERC20 token into the contract
    /// @param _amount Amount to deposit
    function depositToken(uint256 _amount) external nonReentrant {
        if (finalized) revert FinalizedAlready();
        if (address(token) == address(0)) revert NotPayableToken();
        if (_amount != amount) revert DepositNotExpected();
        if (deposited) revert AlreadyDeposited();
        if (payer != address(0) && msg.sender != payer) revert NotAuthorizedPayer();

        token.safeTransferFrom(msg.sender, address(this), _amount);

        deposited = true;
        depositedAmount = _amount;
        depositor = msg.sender;

        emit Deposited(msg.sender, _amount);
    }

    /// @notice Deposit native CELO by sending value equal to amount
    receive() external payable {
        _depositNative();
    }

    /// @notice Deposit native CELO manually
    function depositNative() external payable {
        _depositNative();
    }

    /// @notice Checks if payment has been fulfilled
    /// @return True if already deposited amount is equal or greater than expected
    function isPay() external view onlyGateway returns (bool) {
        uint256 alreadyBalance = _currentBalance();

        return alreadyBalance >= amount;
    }

    /// @notice Finalizes the payment
    /// @param _forceExpired Force the payment to expire
    /// @return success True if payment finalized successfully
    /// @return totalBalance Total balance held in the contract
    /// @return toReceiver Amount transferred to receiver
    function finalize(bool _forceExpired)
        external
        onlyGateway
        returns (bool, uint256, uint256)
    {
        if (finalized) revert FinalizedAlready();

        uint256 alreadyBalance = _currentBalance();
        bool expired = block.timestamp > expiresAt || _forceExpired;

        if (alreadyBalance < amount && expired) {
            finalized = true;
            emit Finalized(false, 0, false);
            return (false, 0, 0);
        }

        if (!deposited && alreadyBalance < amount) {
            // nothing deposited — nothing to do
            emit Finalized(false, 0, false);
            return (false, 0, 0);
        }

        uint256 gatewayShare;
        uint256 toReceiver;
        uint256 toSender;
        uint256 depositorShare;

        finalized = true;

        if (!expired) {
            // Success within time: gateway 2%, receiver 98%
            gatewayShare = (amount * 2) / 100;
            toReceiver = amount - gatewayShare;
            depositorShare = alreadyBalance - amount;

            if (depositor != address(0) && depositorShare != 0) {
                _transferFunds(token, depositor, depositorShare);
            } else {
                gatewayShare += depositorShare;
            }

            if (receiveFiat) {
                _transferFunds(token, gateway, gatewayShare + toReceiver);

                emit Finalized(true, toReceiver, receiveFiat);
                return (true, alreadyBalance, toReceiver);
            }

            _transferFunds(token, receiver, toReceiver);
            _transferFunds(token, gateway, gatewayShare);

            emit Finalized(true, toReceiver, receiveFiat);
            return (true, alreadyBalance, toReceiver);
        } else {
            // Expired: gateway 10%, refund 90% to sender
            gatewayShare = (alreadyBalance * 5) / 100;
            toSender = alreadyBalance - gatewayShare;

            _transferFunds(token, gateway, gatewayShare);
            _transferFunds(token, depositor, toSender);

            emit Finalized(false, 0, receiveFiat);
            return (false, alreadyBalance, 0);
        }
    }

    /// @notice Deposit native CELO logic
    function _depositNative() internal {
        if (finalized) revert FinalizedAlready();
        if (address(token) != address(0)) revert NotPayableToken();
        if (msg.value != amount) revert DepositNotExpected();
        if (deposited) revert AlreadyDeposited();
        if (payer != address(0) && msg.sender != payer) revert NotAuthorizedPayer();

        deposited = true;
        depositedAmount = msg.value;
        depositor = msg.sender;

        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Restricts function to gateway only
    function _onlyGateway() internal view {
        if (msg.sender != gateway) revert NotGateway();
    }

    /// @notice Returns current balance of token or native CELO in contract
    /// @return Current balance
    function _currentBalance() internal view returns (uint256) {
        if (address(token) == address(0)) {
            return address(this).balance;
        } else {
            return token.balanceOf(address(this));
        }
    }   

    /// @notice Transfer funds to an address, either native CELO or ERC20
    /// @param _token Token to transfer; zero address = native CELO
    /// @param to Recipient address
    /// @param value Amount to transfer
    function _transferFunds(IERC20 _token, address to, uint256 value) internal {
        if (value == 0) return;

        if (address(token) == address(0)) {
            // native CELO — use call and require success
            (bool ok, ) = to.call{ value: value }("");
            
            if(!ok) revert NativeTransferFailed();
        } else {
            // ERC20 safe transfer (handles non-standard tokens)
            _token.safeTransfer(to, value);
        }
    }
}
