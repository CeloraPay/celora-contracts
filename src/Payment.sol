// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error NotGateway();
error AlreadyInitialized();
error NotPayableToken();
error DepositNotExpected();
error AlreadyDeposited();
error FinalizedAlready();

contract Payment is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // created by gateway; temporary gateway set in constructor to the deployer (gateway)
    address public gateway;
    address public payer; // expected depositor (can be address(0) meaning anyone)
    address public receiver; // final recipient
    address public token; // address(0) for native CELO
    uint256 public amount; // expected amount (wei)
    uint256 public createdAt;
    uint256 public expiresAt;
    uint256 public invoiceId;
    bool public receiveFiat;

    bool public deposited;
    uint256 public depositedAmount;
    bool public finalized;
    address public depositor; // actual sender

    event Deposited(address indexed from, uint256 amount);
    event Finalized(
        bool success,
        uint256 toReceiver,
        uint256 toGateway,
        uint256 toSender,
        bool isFiat
    );

    modifier onlyGateway() {
        _onlyGateway();
        _;
    }

    function _onlyGateway() internal view {
        if (msg.sender != gateway) revert NotGateway();
    }

    constructor() {
        // when deployed by Gateway, msg.sender is the gateway contract
        gateway = msg.sender;
    }

    // initialize called by gateway right after deployment
    // only callable by the deploying gateway (constructor set gateway = deployer)
    function initialize(
        address _gateway,
        address _payer,
        address _receiver,
        address _token,
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
    }

    // For ERC20 deposits: payer must approve this contract, then call depositToken
    function depositToken(uint256 _amount) external nonReentrant {
        if (finalized) revert FinalizedAlready();
        if (token == address(0)) revert NotPayableToken();
        if (_amount != amount) revert DepositNotExpected();
        if (deposited) revert AlreadyDeposited();
        if (payer != address(0)) {
            // if payer was specified, only that address may deposit
            require(msg.sender == payer, "not authorized payer");
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);

        deposited = true;
        depositedAmount = _amount;
        depositor = msg.sender;

        emit Deposited(msg.sender, _amount);
    }

    // For native CELO deposits: send value equal to amount
    receive() external payable {
        _depositNative();
    }

    function depositNative() external payable {
        _depositNative();
    }

    function _depositNative() internal {
        if (finalized) revert FinalizedAlready();
        if (token != address(0)) revert NotPayableToken();
        if (msg.value != amount) revert DepositNotExpected();
        if (deposited) revert AlreadyDeposited();
        if (payer != address(0)) {
            require(msg.sender == payer, "not authorized payer");
        }

        deposited = true;
        depositedAmount = msg.value;
        depositor = msg.sender;

        emit Deposited(msg.sender, msg.value);
    }

    function isPay() external view onlyGateway returns (bool) {
        uint256 alreadyBalance;

        if (token == address(0)) {
            alreadyBalance = address(this).balance;
        } else {
            alreadyBalance = IERC20(token).balanceOf(address(this));
        }

        return alreadyBalance >= amount;
    }

    // finalize can only be called by gateway (which enforces admin in its own contract)
    // returns true if success (within expiry), false if expired/refunded
    function finalize(
        bool _forceExpired
    ) external onlyGateway returns (bool, uint256, uint256) {
        if (finalized) revert FinalizedAlready();

        uint256 alreadyBalance;
        if (token == address(0)) {
            alreadyBalance = address(this).balance;
        } else {
            alreadyBalance = IERC20(token).balanceOf(address(this));
        }

        bool expired = block.timestamp > expiresAt || _forceExpired;

        if (!deposited && alreadyBalance < amount) {
            // nothing deposited — nothing to do
            emit Finalized(false, 0, 0, 0, false);
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

            if(depositor != address(0) && depositorShare != 0){
                _transferFunds(token, depositor, depositorShare);
            }else{
                gatewayShare += depositorShare;
            }

            if (receiveFiat) {
                _transferFunds(token, gateway, gatewayShare + toReceiver);

                emit Finalized(true, toReceiver, gatewayShare, 0, receiveFiat);
                return (true, alreadyBalance, toReceiver);
            }

            _transferFunds(token, receiver, toReceiver);
            _transferFunds(token, gateway, gatewayShare);

            emit Finalized(true, toReceiver, gatewayShare, 0, receiveFiat);
            return (true, alreadyBalance, toReceiver);
        } else {
            // Expired: gateway 10%, refund 90% to sender
            gatewayShare = (alreadyBalance * 5) / 100;
            toSender = alreadyBalance - gatewayShare;

            _transferFunds(token, gateway, gatewayShare);
            _transferFunds(token, depositor, toSender);

            emit Finalized(false, 0, gatewayShare, toSender, receiveFiat);
            return (false, alreadyBalance, 0);
        }
    }

    function _transferFunds(
        address _token,
        address to,
        uint256 value
    ) internal {
        if (value == 0) return;

        if (_token == address(0)) {
            // native CELO — use call and require success
            (bool ok, ) = to.call{value: value}("");
            require(ok, "native transfer failed");
        } else {
            // ERC20 safe transfer (handles non-standard tokens)
            IERC20(_token).safeTransfer(to, value);
        }
    }
}
