// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {NectarMath} from "../src/libraries/NectarMath.sol";

/// @title NectarMathTest
/// @notice TDD test suite for all enrollment math, cycle calculations, and edge cases.
/// @dev All tests are written BEFORE the implementation. Each test documents a specific rule
///      from the Nectar PRD. Run: forge test --match-contract NectarMathTest -vv
contract NectarMathTest is Test {
    using NectarMath for *;

    // ─── Pool Setup Fixtures ──────────────────────────────────────────────────

    uint256 constant TARGET_WEEKLY  = 12_000e18; // 12,000 USDC
    uint16  constant MEMBERS        = 6;
    uint16  constant CYCLES_WEEKLY  = 10;        // 10 weeks

    uint256 constant TARGET_DAILY   = 600e18;    // 600 G$
    uint16  constant MEMBERS_DAILY  = 10;
    uint16  constant CYCLES_DAILY   = 30;        // 30 days

    uint256 constant TARGET_MONTHLY = 60_000e18; // 60,000 USDC
    uint16  constant MEMBERS_MONTHLY = 20;
    uint16  constant CYCLES_MONTHLY = 6;         // 6 months

    // ─── 1. Base Contribution Tests ──────────────────────────────────────────

    /// @notice PRD 2.1: Base contribution = Target ÷ Members ÷ Cycles
    function test_BaseContribution_WeeklyPool() public pure {
        uint256 perMember = NectarMath.perMemberTotal(TARGET_WEEKLY, MEMBERS);
        uint256 base = NectarMath.baseContribution(perMember, CYCLES_WEEKLY);
        assertEq(perMember, 2_000e18, "Per-member total wrong");
        assertEq(base,      200e18,   "Base contribution wrong");
    }

    function test_BaseContribution_DailyPool() public pure {
        uint256 perMember = NectarMath.perMemberTotal(TARGET_DAILY, MEMBERS_DAILY);
        uint256 base = NectarMath.baseContribution(perMember, CYCLES_DAILY);
        assertEq(perMember, 60e18, "Per-member total wrong");
        assertEq(base,      2e18,  "Base contribution wrong (should be 2 G$/day)");
    }

    function test_BaseContribution_MonthlyPool() public pure {
        uint256 perMember = NectarMath.perMemberTotal(TARGET_MONTHLY, MEMBERS_MONTHLY);
        uint256 base = NectarMath.baseContribution(perMember, CYCLES_MONTHLY);
        assertEq(perMember, 3_000e18, "Per-member total wrong");
        assertEq(base,      500e18,   "Base contribution wrong");
    }

    // ─── 2. Late Joiner Rate Tests ────────────────────────────────────────────

    /// @notice PRD 2.2: Late joiner rate = PerMemberTotal ÷ RemainingCycles
    function test_LateJoiner_Week4_Of10() public pure {
        // Joining at start of week 4 means 7 cycles remain (weeks 4–10).
        uint256 perMember = NectarMath.perMemberTotal(TARGET_WEEKLY, MEMBERS);
        uint256 rate = NectarMath.lateJoinerRate(perMember, 10 - 4 + 1);
        // 2000e18 / 7 = 285714285714285714285 (in wei, 18-decimal token)
        assertApproxEqAbs(rate, 285_714_285_714_285_714_285, 1e6, "Late joiner week 4 rate wrong");
    }

    function test_LateJoiner_Day10_Of30() public pure {
        uint256 perMember = NectarMath.perMemberTotal(TARGET_DAILY, MEMBERS_DAILY);
        // Joining day 10 means 21 cycles remain.
        uint256 rate = NectarMath.lateJoinerRate(perMember, 21);
        // 60 / 21 ≈ 2.857 G$/day
        assertApproxEqAbs(rate, 2_857_142_857_142_857_142, 1e6, "Late joiner day 10 rate wrong");
    }

    function test_LateJoiner_Month2_Of6() public pure {
        uint256 perMember = NectarMath.perMemberTotal(TARGET_MONTHLY, MEMBERS_MONTHLY);
        // Joining month 2 means 5 cycles remain.
        uint256 rate = NectarMath.lateJoinerRate(perMember, 5);
        assertEq(rate, 600e18, "Late joiner month 2 rate wrong (3000/5=600)");
    }

    // ─── 3. Two-X Cap Tests ───────────────────────────────────────────────────

    /// @notice PRD 2.2 Safeguard 1: Rate must not exceed 2× the base rate.
    function test_TwoXCap_Passes_Week5() public pure {
        uint256 baseRate = 200e18; // 200 USDC/week
        uint256 lateRate = 333e18; // Joining week 5 gives 2000/6 ≈ 333 USDC/week
        bool allowed = NectarMath.isWithinTwoXCap(lateRate, baseRate);
        assertTrue(allowed, "Week 5 joining should pass 2x cap");
    }

    function test_TwoXCap_Fails_Week6_Exactly() public pure {
        uint256 baseRate = 200e18;
        uint256 lateRate = 400e18; // Exactly 2x — should be blocked per PRD
        bool allowed = NectarMath.isWithinTwoXCap(lateRate, baseRate);
        assertFalse(allowed, "Exactly 2x should FAIL the cap (must be strictly less than 2x)");
    }

    function test_TwoXCap_Fails_400_On_200Base() public pure {
        uint256 baseRate = 200e18;
        uint256 lateRate = 401e18; // Exceeds 2x cap
        bool allowed = NectarMath.isWithinTwoXCap(lateRate, baseRate);
        assertFalse(allowed, "Rate above 2x should fail");
    }

    function test_TwoXCap_DailyPool_Day15() public pure {
        // Daily pool: 2 G$/day base. 2x cap = 4 G$/day.
        // Joining day 15 of 30: rate = 60/16 = 3.75 — just under 4, should pass.
        uint256 perMember = NectarMath.perMemberTotal(TARGET_DAILY, MEMBERS_DAILY);
        uint256 rate = NectarMath.lateJoinerRate(perMember, 16);
        bool allowed = NectarMath.isWithinTwoXCap(rate, 2e18);
        assertTrue(allowed, "Day 15 (3.75 G$/day) should pass 2x cap");
    }

    function test_TwoXCap_DailyPool_Day16_Blocked() public pure {
        // Joining day 16: rate = 60/15 = 4.0 — exactly 2x, should be blocked.
        uint256 perMember = NectarMath.perMemberTotal(TARGET_DAILY, MEMBERS_DAILY);
        uint256 rate = NectarMath.lateJoinerRate(perMember, 15);
        bool allowed = NectarMath.isWithinTwoXCap(rate, 2e18);
        assertFalse(allowed, "Day 16 (4 G$/day = exactly 2x) should be blocked");
    }

    function test_TwoXCap_MonthlyPool_Month4_Blocked() public pure {
        // Monthly pool: 500 USDC/month base, 2x cap = 1000. Month 4 rate = 3000/3 = 1000.
        uint256 perMember = NectarMath.perMemberTotal(TARGET_MONTHLY, MEMBERS_MONTHLY);
        uint256 rate = NectarMath.lateJoinerRate(perMember, 3);
        bool allowed = NectarMath.isWithinTwoXCap(rate, 500e18);
        assertFalse(allowed, "Month 4 (1000 USDC = exactly 2x) should be blocked");
    }

    // ─── 4. Three-Cycle Floor Tests ────────────────────────────────────────────

    /// @notice PRD 2.2 Safeguard 2: Cannot join if fewer than 3 cycles remain.
    function test_ThreeCycleFloor_Passes_3Remaining() public pure {
        bool ok = NectarMath.isAboveThreeCycleFloor(3);
        assertTrue(ok, "3 cycles remaining should be allowed");
    }

    function test_ThreeCycleFloor_Fails_2Remaining() public pure {
        bool ok = NectarMath.isAboveThreeCycleFloor(2);
        assertFalse(ok, "2 cycles remaining should block enrollment");
    }

    function test_ThreeCycleFloor_Fails_1Remaining() public pure {
        bool ok = NectarMath.isAboveThreeCycleFloor(1);
        assertFalse(ok, "1 cycle remaining should block enrollment");
    }

    function test_ThreeCycleFloor_Passes_10Remaining() public pure {
        bool ok = NectarMath.isAboveThreeCycleFloor(10);
        assertTrue(ok, "10 cycles remaining should clearly pass floor");
    }

    // ─── 5. Enrollment Window Tests ────────────────────────────────────────────

    /// @notice PRD 2.1: Standard = first 50% of cycles, Strict = first 25%, Fixed = cycle 1 only.
    function test_EnrollmentWindow_Standard_Week5_Open() public pure {
        // Standard on 10-week pool: open through week 5 (cycles 1–5)
        bool open = NectarMath.isWithinEnrollmentWindow(5, 10, 0); // 0 = Standard
        assertTrue(open, "Week 5 should be within Standard window");
    }

    function test_EnrollmentWindow_Standard_Week6_Closed() public pure {
        bool open = NectarMath.isWithinEnrollmentWindow(6, 10, 0);
        assertFalse(open, "Week 6 should be outside Standard window");
    }

    function test_EnrollmentWindow_Strict_Week2_Open() public pure {
        // Strict on 10-week pool: open through week 2 (first 25%)
        bool open = NectarMath.isWithinEnrollmentWindow(2, 10, 1); // 1 = Strict
        assertTrue(open, "Week 2 should be within Strict window");
    }

    function test_EnrollmentWindow_Strict_Week3_Closed() public pure {
        bool open = NectarMath.isWithinEnrollmentWindow(3, 10, 1);
        assertFalse(open, "Week 3 should be outside Strict window");
    }

    function test_EnrollmentWindow_Fixed_Cycle1_Open() public pure {
        // Fixed: only cycle 1
        bool open = NectarMath.isWithinEnrollmentWindow(1, 10, 2); // 2 = Fixed
        assertTrue(open, "Cycle 1 should be open with Fixed window");
    }

    function test_EnrollmentWindow_Fixed_Cycle2_Closed() public pure {
        bool open = NectarMath.isWithinEnrollmentWindow(2, 10, 2);
        assertFalse(open, "Cycle 2 should be closed with Fixed window");
    }

    // ─── 6. Final Cycle Rounding Tests ──────────────────────────────────────────

    /// @notice PRD 2.3: The final cycle amount is adjusted to hit the exact per-member total.
    function test_FinalCycleRounding_HitsExactTotal() public pure {
        // Late joiner weekly pool: 2000 USDC / 7 cycles
        // Pay 285 for 6 cycles = 1710 → final cycle = 2000 - 1710 = 290? No.
        // Actually: NectarMath rounds to nearest integer per cycle.
        // 2000e18 / 7 = 285714285714285714 per cycle
        // 6 cycles = 1714285714285714284, final = 2000e18 - that = 285714285714285716
        uint256 perMember = 2_000e18;
        uint256 rate = NectarMath.lateJoinerRate(perMember, 7);
        uint256 finalCycle = NectarMath.finalCycleAmount(perMember, rate, 6);
        uint256 totalPaid = rate * 6 + finalCycle;
        assertEq(totalPaid, perMember, "Total from 7 cycles must equal exact per-member total");
    }

    // ─── 7. Protocol Fee Tests ───────────────────────────────────────────────

    /// @notice PRD 8: Protocol takes 5% of yield, winners get 95%.
    function test_ProtocolFee_300USDC_Yield() public pure {
        uint256 totalYield = 300e18;
        uint256 fee = NectarMath.protocolFee(totalYield);
        uint256 winnersShare = NectarMath.winnersShare(totalYield);
        assertEq(fee, 15e18,  "Protocol fee should be 15 USDC");
        assertEq(winnersShare, 285e18, "Winners share should be 285 USDC");
        assertEq(fee + winnersShare, totalYield, "Fee + winners must equal total yield");
    }

    function test_ProtocolFee_ZeroYield_NoOp() public pure {
        uint256 totalYield = 0;
        uint256 fee = NectarMath.protocolFee(totalYield);
        assertEq(fee, 0, "Protocol fee on 0 yield should be 0");
    }

    // ─── 8. Minimum Fill Threshold Tests ─────────────────────────────────────

    /// @notice PRD 2.7: At least 50% of slots AND at least 3 members required.
    function test_FillThreshold_3Members_Of6() public pure {
        // 50% of 6 = 3; minimum 3; effective minimum = 3. Passing with exactly 3 members.
        bool ok = NectarMath.meetsMinFillThreshold(3, 6);
        assertTrue(ok, "3/6 members should meet 50% threshold");
    }

    function test_FillThreshold_2Members_Of6_Fails() public pure {
        bool ok = NectarMath.meetsMinFillThreshold(2, 6);
        assertFalse(ok, "2/6 members should fail 50% threshold");
    }

    function test_FillThreshold_3Members_Of3_Passes() public pure {
        // 50% of 3 = 1.5 → ceil = 2; but min 3 members overrides. Need all 3.
        bool ok = NectarMath.meetsMinFillThreshold(3, 3);
        assertTrue(ok, "3/3 members passes both checks");
    }

    function test_FillThreshold_2Members_Of3_Fails() public pure {
        bool ok = NectarMath.meetsMinFillThreshold(2, 3);
        // 50% of 3 = 2, but the min-3-members rule also requires >= 3. Fails.
        assertFalse(ok, "2/3 must fail: fewer than 3 members present");
    }

    function test_FillThreshold_10Members_Of20_Passes() public pure {
        bool ok = NectarMath.meetsMinFillThreshold(10, 20);
        assertTrue(ok, "10/20 = exactly 50% should pass");
    }

    function test_FillThreshold_9Members_Of20_Fails() public pure {
        bool ok = NectarMath.meetsMinFillThreshold(9, 20);
        assertFalse(ok, "9/20 is below 50% and should fail");
    }

    // ─── 9. Winner Count Adjustment Tests ─────────────────────────────────────

    /// @notice PRD 2.6: Winners must always be strictly less than active members.
    function test_WinnerAdjustment_SufficientMembers() public pure {
        uint16 adjusted = NectarMath.adjustedWinnerCount(2, 4);
        assertEq(adjusted, 2, "Winner count should be unchanged when members > winners");
    }

    function test_WinnerAdjustment_MembersEqualWinners_Reduces() public pure {
        // 2 active members, 2 winners → must reduce to 1
        uint16 adjusted = NectarMath.adjustedWinnerCount(2, 2);
        assertEq(adjusted, 1, "Winners must be reduced to activeMembers - 1");
    }

    function test_WinnerAdjustment_OneMemberLeft_ForceCancel() public pure {
        // Only 1 member remaining → pool must cancel, no draw possible
        uint16 adjusted = NectarMath.adjustedWinnerCount(2, 1);
        assertEq(adjusted, 0, "0 winners signals pool cancellation (1 member left)");
    }

    // ─── 10. Fuzz Tests ──────────────────────────────────────────────────────

    /// @notice Fuzz: late joiner rate is always ≤ perMemberTotal
    function testFuzz_LateJoinerRate_NeverExceedsTotal(
        uint256 perMember,
        uint16 remainingCycles
    ) public pure {
        vm.assume(perMember > 0 && perMember < 1_000_000_000e18);
        vm.assume(remainingCycles > 0 && remainingCycles <= 30);
        uint256 rate = NectarMath.lateJoinerRate(perMember, remainingCycles);
        assertLe(rate, perMember, "Late joiner rate should never exceed per-member total");
    }

    /// @notice Fuzz: protocol fee + winner share always sums to total yield
    function testFuzz_FeeAndShare_SumToTotal(uint256 totalYield) public pure {
        vm.assume(totalYield < 100_000_000e18);
        uint256 fee = NectarMath.protocolFee(totalYield);
        uint256 share = NectarMath.winnersShare(totalYield);
        assertEq(fee + share, totalYield, "Fee + share must equal total yield");
    }
}
