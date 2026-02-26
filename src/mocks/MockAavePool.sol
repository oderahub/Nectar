// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title MockAavePool
/// @notice Simplified Aave V3 Pool mock for unit testing NectarVault.
///         Tracks deposits per user and returns them on withdraw with configurable yield.
contract MockAavePool {
    mapping(address => mapping(address => uint256)) public supplied; // user => asset => amount
    uint256 public yieldBps = 500; // 5% yield by default (in basis points)
    bool public locked; // Simulate 100% utilization

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /*referralCode*/ ) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        supplied[onBehalfOf][asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(!locked, "AAVE_UTILIZATION_LOCKED");

        address user = msg.sender;
        uint256 deposited = supplied[user][asset];
        require(deposited > 0, "MockAave: nothing supplied");

        // Calculate total = principal + yield
        uint256 yieldAmount = deposited * yieldBps / 10_000;
        uint256 total = deposited + yieldAmount;

        // Withdraw full amount if type(uint256).max requested
        uint256 toWithdraw = (amount == type(uint256).max) ? total : amount;
        require(toWithdraw <= total, "MockAave: insufficient balance");

        supplied[user][asset] = 0;
        IERC20(asset).transfer(to, toWithdraw);
        return toWithdraw;
    }

    // ─── Test Helpers ────────────────────────────────────────────────────────

    /// @dev Set the yield in basis points (100 = 1%)
    function setYieldBps(uint256 _bps) external {
        yieldBps = _bps;
    }

    /// @dev Toggle 100% utilization lock simulation
    function setLocked(bool _locked) external {
        locked = _locked;
    }

    /// @dev Mint extra tokens to simulate yield accrual
    function simulateYield(address asset, uint256 extraAmount) external {
        // The test contract should mint tokens to this mock to cover yield payouts
    }
}
