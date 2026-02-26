// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title INectarPool
/// @notice Shared interface for NectarPool and the Factory clones.
interface INectarPool {
    // ─── Enums ───────────────────────────────────────────────────────────────

    enum PoolState {
        ENROLLMENT,
        SAVING,
        YIELDING,
        DRAWING,
        SETTLED,
        CANCELLED
    }
    enum Frequency {
        DAILY,
        WEEKLY,
        MONTHLY
    }
    enum EnrollmentWindow {
        STANDARD,
        STRICT,
        FIXED
    }
    enum DistributionMode {
        EQUAL,
        WEIGHTED,
        GRAND_PRIZE
    }

    // ─── Structs ─────────────────────────────────────────────────────────────

    struct PoolConfig {
        address token; // G$ or USDC
        uint256 targetAmount; // Pool's total savings goal
        uint16 maxMembers; // Max participants (3–50)
        uint16 totalCycles; // Number of contribution periods
        uint16 winnersCount; // Number of prize winners
        uint32 cycleDuration; // Seconds per cycle
        bool requiresIdentity; // GoodDollar identity required?
        EnrollmentWindow enrollmentWindow;
        DistributionMode distributionMode;
    }

    struct MemberState {
        uint16 joinCycle; // The cycle number they joined on
        uint16 cyclesPaid; // Number of successful cycle deposits
        uint256 assignedRate; // Their per-cycle deposit amount
        uint256 totalPaid; // Cumulative deposit total
        bool isRemoved; // Evicted for consecutive misses
        bool hasClaimed; // Has claimed principal/yield after settlement
        uint16 lastPaidCycle; // The last cycle they successfully paid
    }

    // ─── Events ──────────────────────────────────────────────────────────────

    event MemberJoined(address indexed member, uint16 joinCycle, uint256 assignedRate);
    event DepositMade(address indexed member, uint16 cycle, uint256 amount);
    event MemberRemoved(address indexed member, uint256 refundAmount);
    event PoolCancelled(string reason);
    event PhaseTransitioned(PoolState from, PoolState to);
    event AaveLiquidityDelayed(uint256 timestamp);
    event WinnersDrawn(address[] winners, uint256 prizePerWinner);
    event FundsClaimed(address indexed member, uint256 amount);

    // ─── Functions ───────────────────────────────────────────────────────────

    /// @notice Initialize pool (called once by factory after clone deployment)
    function initialize(
        PoolConfig calldata config,
        address creator,
        address vault,
        address vrfModule,
        address identityContract
    ) external;

    /// @notice Join the pool and make the first contribution immediately
    function joinPool() external;

    /// @notice Deposit exactly the assigned amount for the current cycle
    function deposit(uint256 amount) external;

    /// @notice Catch up a missed cycle + current cycle in one tx (batch deposit)
    function batchDeposit(uint256 totalAmount) external;

    /// @notice Emergency withdrawal during SAVING phase only
    function emergencyWithdraw() external;

    /// @notice Transition pool to YIELDING phase (Keeper or public incentive call)
    function endSavingsPhase() external;

    /// @notice Attempt to end yield phase and trigger draw (Keeper or public incentive)
    function endYieldPhase() external;

    /// @notice Claim settled funds (winners get principal + yield, non-winners get principal)
    function claim() external;

    /// @notice Returns the current cycle number based on timestamps
    function currentCycle() external view returns (uint16);

    /// @notice Returns the recalculated rate for a late joiner joining at currentCycle
    function calculateJoinRate(uint16 atCycle) external view returns (uint256 rate, bool canJoin);

    /// @notice Returns the current pool state
    function state() external view returns (PoolState);
}
