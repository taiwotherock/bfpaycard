// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/Math.sol";

contract YieldCreditCardStorage
{
   
    enum TxStatus { NONE, AUTHORIZED, CAPTURED, REFUNDED, VOIDED }
    enum CardType {
        PREPAID,        // collateral only
        CHARGE,         // must pay full in 30 days
        CREDIT          // revolving credit
    }

    struct Transaction {
        address user;
        uint256 amount;
        TxStatus status;
        bytes32 refNo;
    }

    struct CardBalance {
        uint256 collateral;
        uint256 locked;
        uint256 debt;
        uint256 creditLimit;
        bool blocked;
        CardType cardType;
    }

    struct Proposal {
        address target;
        bytes data;
        uint256 approvals;
        bool executed;
        uint256 createdAt;
        uint256 expiresAt; 
    }

    enum AdminAction {
        INCREASE_CREDIT_LIMIT,
        APPROVE_WITHDRAWAL,
        UNBLOCK_CARD,
        REFUND,
        SET_FEE_WALLET,
        SET_SETTLEMENT_WALLET,
        SET_PENALTY_WALLET
    }

    struct WithdrawalRequest {
        address user;
        uint256 amount;
        bool approved;
        bool executed;
        bool cancelled;   // ✅ ADD
    }

}