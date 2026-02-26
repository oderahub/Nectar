// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title NectarMath
/// @notice Pure math library for all Nectar pool calculations.
///         No state, no imports — pure functions only. Tested exhaustively before use.
library NectarMath {
    uint256 internal constant FEE_BPS = 500;        // 5% = 500 basis points
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─── Core Contribution Math ───────────────────────────────────────────────

    /// @notice Per-member savings target = totalTarget ÷ numMembers
    function perMemberTotal(uint256 targetAmount, uint16 numMembers)
        internal pure returns (uint256)
    {
        require(numMembers > 0, "NectarMath: zero members");
        return targetAmount / numMembers;
    }

    /// @notice Base per-cycle deposit = perMemberTotal ÷ totalCycles
    function baseContribution(uint256 perMember, uint16 totalCycles)
        internal pure returns (uint256)
    {
        require(totalCycles > 0, "NectarMath: zero cycles");
        return perMember / totalCycles;
    }

    /// @notice Late joiner per-cycle deposit = perMemberTotal ÷ remainingCycles
    function lateJoinerRate(uint256 perMember, uint16 remainingCycles)
        internal pure returns (uint256)
    {
        require(remainingCycles > 0, "NectarMath: zero remaining cycles");
        return perMember / remainingCycles;
    }

    /// @notice Final cycle amount adjusted so cumulative deposits exactly equal perMemberTotal.
    ///         previousCycles × ratePerCycle may not divide evenly; this absorbs dust.
    function finalCycleAmount(
        uint256 perMember,
        uint256 ratePerCycle,
        uint16 previousCycles
    ) internal pure returns (uint256) {
        uint256 paidSoFar = ratePerCycle * previousCycles;
        require(paidSoFar <= perMember, "NectarMath: overpaid");
        return perMember - paidSoFar;
    }

    // ─── Enrollment Guard Rules ───────────────────────────────────────────────

    /// @notice Safeguard 1: Rate must be strictly less than 2× base rate to allow join.
    ///         A rate equal to 2× is treated as a breach and blocks enrollment.
    function isWithinTwoXCap(uint256 lateRate, uint256 baseRate)
        internal pure returns (bool)
    {
        return lateRate < baseRate * 2;
    }

    /// @notice Safeguard 2: Enrollment closes when fewer than 3 cycles remain.
    function isAboveThreeCycleFloor(uint16 remainingCycles)
        internal pure returns (bool)
    {
        return remainingCycles >= 3;
    }

    /// @notice Safeguard 3: Enrollment window chosen by creator.
    ///         windowType: 0 = Standard (first 50%), 1 = Strict (first 25%), 2 = Fixed (cycle 1 only)
    function isWithinEnrollmentWindow(
        uint16 currentCycle,
        uint16 totalCycles,
        uint8 windowType
    ) internal pure returns (bool) {
        if (windowType == 0) {
            // Standard: first half (50%) of cycles
            return currentCycle <= totalCycles / 2;
        } else if (windowType == 1) {
            // Strict: first quarter (25%) of cycles
            return currentCycle <= totalCycles / 4;
        } else if (windowType == 2) {
            // Fixed: cycle 1 only
            return currentCycle == 1;
        }
        return false;
    }

    // ─── Minimum Fill Threshold ───────────────────────────────────────────────

    /// @notice Pool requires >= 50% fill AND >= 3 members at enrollment close.
    function meetsMinFillThreshold(uint16 activeMembers, uint16 maxMembers)
        internal pure returns (bool)
    {
        if (activeMembers < 3) return false;
        // 50% threshold: activeMembers * 2 >= maxMembers avoids floating-point division
        return (uint256(activeMembers) * 2 >= uint256(maxMembers));
    }

    // ─── Winner Count Adjustment ──────────────────────────────────────────────

    /// @notice Winners must always be strictly less than active members.
    ///         Returns 0 to signal pool cancellation if only 1 member remains.
    function adjustedWinnerCount(uint16 configuredWinners, uint16 activeMembers)
        internal pure returns (uint16)
    {
        if (activeMembers <= 1) return 0; // Signal cancellation
        if (configuredWinners >= activeMembers) return activeMembers - 1;
        return configuredWinners;
    }

    // ─── Protocol Fee Split ───────────────────────────────────────────────────

    /// @notice Protocol takes 5% of yield.
    function protocolFee(uint256 totalYield) internal pure returns (uint256) {
        return (totalYield * FEE_BPS) / BPS_DENOMINATOR;
    }

    /// @notice Winners split 95% of yield.
    function winnersShare(uint256 totalYield) internal pure returns (uint256) {
        return totalYield - protocolFee(totalYield);
    }

    // ─── Current Cycle Calculation (lazy evaluation) ──────────────────────────

    /// @notice Compute the cycle number for any given timestamp relative to pool start.
    ///         cycleDuration is in seconds (e.g., 86400 for daily, 604800 for weekly).
    function computeCurrentCycle(
        uint256 startTimestamp,
        uint256 currentTimestamp,
        uint32 cycleDuration
    ) internal pure returns (uint16) {
        if (currentTimestamp < startTimestamp) return 0;
        uint256 elapsed = currentTimestamp - startTimestamp;
        return uint16(elapsed / cycleDuration) + 1;
    }

    /// @notice Compute remaining cycles from current cycle to totalCycles.
    function remainingCycles(uint16 current, uint16 total)
        internal pure returns (uint16)
    {
        if (current > total) return 0;
        return total - current + 1;
    }
}
