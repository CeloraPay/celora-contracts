// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IReceiver {
    struct Receiver {
        address addr;
        uint256 planId;
        uint256[] invoiceIds;
        uint256 activePayments;
        string name;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    event ReceiverRegistered(address indexed _addr, uint256 indexed _planId);
    event ReceiverPlanAssigned(address indexed _addr, uint256 _planId);
    event ActivePaymentCountChanged(address indexed receiver, uint256 newCount);

    error ReceiverAlreadyRegistered(address _addr);
    error ReceiverNotFound(address _addr);
    error InvalidPlan(uint256 _planId);

    function registerReceiver(address _addr, string calldata _name) external;

    function getReceiver(address _addr) external view returns (Receiver memory, TokenAmount[] memory);

    function assignPlan(address receiver, uint256 planId) external;
}
