// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {NectarVault} from "../src/NectarVault.sol";
import {NectarFactory} from "../src/NectarFactory.sol";
import {NectarPool} from "../src/NectarPool.sol";
import {INectarPool} from "../src/interfaces/INectarPool.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {MockSwapRouter} from "../src/mocks/MockSwapRouter.sol";
import {MockGoodDollarIdentity} from "../src/MockGoodDollarIdentity.sol";

/// @title NectarVaultTest
/// @notice Unit tests for NectarVault using mocked Aave + Uniswap.
///         Run: forge test --match-contract NectarVaultTest -vv
contract NectarVaultTest is Test {

    // ─── Contracts ───────────────────────────────────────────────────────────
    MockERC20              usdc;
    MockERC20              gdollar;
    MockAavePool           aave;
    MockSwapRouter         router;
    MockGoodDollarIdentity identity;
    NectarPool             blueprint;
    NectarFactory          factory;
    NectarVault            vault;

    // ─── Actors ──────────────────────────────────────────────────────────────
    address creator  = makeAddr("creator");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address carol    = makeAddr("carol");
    address treasury = makeAddr("treasury");
    address vrfAddr  = makeAddr("vrfModule");
    address stranger = makeAddr("stranger");

    // ─── Pool Config ─────────────────────────────────────────────────────────
    uint256 constant TARGET  = 6_000e18;
    uint16  constant MEMBERS = 6;
    uint16  constant CYCLES  = 10;
    uint16  constant WINNERS = 2;
    uint32  constant WEEKLY  = 7 days;

    // ─── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy mock tokens
        usdc    = new MockERC20("Mock USDC", "mUSDC");
        gdollar = new MockERC20("Mock GoodDollar", "mG$");
        identity = new MockGoodDollarIdentity();

        // Deploy mock DeFi protocols
        aave   = new MockAavePool();
        router = new MockSwapRouter();

        // Deploy protocol contracts
        blueprint = new NectarPool();
        // Factory needs a vault address, but vault needs factory address → deploy factory first with placeholder
        factory = new NectarFactory(
            address(blueprint),
            address(0), // vault — will update after
            vrfAddr,
            address(identity),
            treasury
        );

        // Deploy vault with factory reference
        vault = new NectarVault(
            address(factory),
            address(aave),
            address(router),
            address(usdc)
        );

        // Update factory to point to the real vault
        factory.setVault(address(vault));

        // Fund mock swap router with USDC so it can pay out swaps
        usdc.mint(address(router), 1_000_000e18);

        // Fund mock Aave with extra USDC to cover yield payouts
        usdc.mint(address(aave), 1_000_000e18);

        // Fund actors and verify identity
        address[3] memory actors = [creator, alice, bob];
        for (uint i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 100_000e18);
            gdollar.mint(actors[i], 100_000e18);
            identity.testnetSimulateFaceScan(actors[i]);
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Create a pool using USDC as the deposit token
    function _createUSDCPool() internal returns (NectarPool pool) {
        INectarPool.PoolConfig memory cfg = INectarPool.PoolConfig({
            token:            address(usdc),
            targetAmount:     TARGET,
            maxMembers:       MEMBERS,
            totalCycles:      CYCLES,
            winnersCount:     WINNERS,
            cycleDuration:    WEEKLY,
            requiresIdentity: true,
            enrollmentWindow: INectarPool.EnrollmentWindow.STANDARD,
            distributionMode: INectarPool.DistributionMode.EQUAL
        });
        vm.prank(creator);
        address poolAddr = factory.createPool(cfg);
        pool = NectarPool(poolAddr);

        // Approve everyone to the pool
        address[3] memory members = [creator, alice, bob];
        for (uint i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    /// @dev Create a pool using G$ as the deposit token
    function _createGDollarPool() internal returns (NectarPool pool) {
        INectarPool.PoolConfig memory cfg = INectarPool.PoolConfig({
            token:            address(gdollar),
            targetAmount:     TARGET,
            maxMembers:       MEMBERS,
            totalCycles:      CYCLES,
            winnersCount:     WINNERS,
            cycleDuration:    WEEKLY,
            requiresIdentity: true,
            enrollmentWindow: INectarPool.EnrollmentWindow.STANDARD,
            distributionMode: INectarPool.DistributionMode.EQUAL
        });
        vm.prank(creator);
        address poolAddr = factory.createPool(cfg);
        pool = NectarPool(poolAddr);

        // Approve everyone to the pool
        address[3] memory members = [creator, alice, bob];
        for (uint i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            gdollar.approve(address(pool), type(uint256).max);
        }
    }

    /// @dev Helper to pay all cycles for a member
    function _payAllCycles(NectarPool pool, address member, uint256 rate) internal {
        for (uint16 c = 2; c <= CYCLES; c++) {
            vm.warp(pool.poolStartTime() + (uint256(c - 1) * WEEKLY));
            vm.prank(member);
            pool.deposit(rate);
        }
    }

    // ─── 1. Constructor Tests ────────────────────────────────────────────────

    function test_Constructor_StoresAddresses() public view {
        assertEq(vault.factory(),    address(factory));
        assertEq(vault.aavePool(),   address(aave));
        assertEq(vault.swapRouter(), address(router));
        assertEq(vault.usdc(),       address(usdc));
    }

    function test_Constructor_RejectsZeroAddress() public {
        vm.expectRevert("NectarVault: zero factory");
        new NectarVault(address(0), address(aave), address(router), address(usdc));
    }

    // ─── 2. Access Control Tests ─────────────────────────────────────────────

    function test_DepositAndSupply_RejectsNonPool() public {
        vm.prank(stranger);
        vm.expectRevert("NectarVault: caller not a registered pool");
        vault.depositAndSupply(stranger, address(usdc), 1000e18);
    }

    function test_WithdrawAndReturn_RejectsNonPool() public {
        vm.prank(stranger);
        vm.expectRevert("NectarVault: caller not a registered pool");
        vault.withdrawAndReturn(stranger);
    }

    // ─── 3. USDC Path (Direct Supply) ────────────────────────────────────────

    function test_DepositUSDC_SuppliedToAave() public {
        NectarPool pool = _createUSDCPool();
        uint256 amount = 1000e18;

        // Simulate pool sending USDC to vault via depositAndSupply
        usdc.mint(address(pool), amount);
        vm.startPrank(address(pool));
        usdc.approve(address(vault), amount);
        vault.depositAndSupply(address(pool), address(usdc), amount);
        vm.stopPrank();

        // Verify deposit recorded
        assertTrue(vault.hasActiveDeposit(address(pool)));
        assertEq(vault.getPrincipal(address(pool)), amount);

        // Verify USDC was supplied to Aave
        assertEq(aave.supplied(address(vault), address(usdc)), amount);
    }

    // ─── 4. G$ Path (Swap + Supply) ──────────────────────────────────────────

    function test_DepositGDollar_SwappedThenSupplied() public {
        NectarPool pool = _createGDollarPool();
        uint256 amount = 1000e18;

        // Simulate pool sending G$ to vault
        gdollar.mint(address(pool), amount);
        vm.startPrank(address(pool));
        gdollar.approve(address(vault), amount);
        vault.depositAndSupply(address(pool), address(gdollar), amount);
        vm.stopPrank();

        // Router at 1:1 rate → vault should have supplied 1000 USDC to Aave
        assertTrue(vault.hasActiveDeposit(address(pool)));
        assertEq(vault.getPrincipal(address(pool)), amount); // 1:1 swap
    }

    // ─── 5. Withdrawal Tests ─────────────────────────────────────────────────

    function test_WithdrawAndReturn_ReturnsPrincipalPlusYield() public {
        NectarPool pool = _createUSDCPool();
        uint256 amount = 1000e18;

        // Deposit
        usdc.mint(address(pool), amount);
        vm.startPrank(address(pool));
        usdc.approve(address(vault), amount);
        vault.depositAndSupply(address(pool), address(usdc), amount);

        // Withdraw (Aave mock has 5% yield by default)
        (uint256 principal, uint256 yield, bool success) = vault.withdrawAndReturn(address(pool));
        vm.stopPrank();

        assertTrue(success, "Withdrawal should succeed");
        assertEq(principal, amount, "Principal should match deposit");
        assertEq(yield, amount * 500 / 10_000, "Yield should be 5%"); // 50e18

        // Verify deposit is no longer active
        assertFalse(vault.hasActiveDeposit(address(pool)));

        // Verify pool received the funds
        assertEq(usdc.balanceOf(address(pool)), amount + yield);
    }

    // ─── 6. Aave Utilization Lock (Graceful Degradation) ─────────────────────

    function test_WithdrawAndReturn_GracefulDegradation() public {
        NectarPool pool = _createUSDCPool();
        uint256 amount = 1000e18;

        // Deposit
        usdc.mint(address(pool), amount);
        vm.startPrank(address(pool));
        usdc.approve(address(vault), amount);
        vault.depositAndSupply(address(pool), address(usdc), amount);

        // Lock Aave (simulate 100% utilization)
        aave.setLocked(true);

        (uint256 principal, uint256 yield, bool success) = vault.withdrawAndReturn(address(pool));
        vm.stopPrank();

        assertFalse(success, "Should fail gracefully");
        assertEq(yield, 0, "No yield when locked");
        assertTrue(vault.isDelayed(address(pool)), "Should be marked delayed");
        assertTrue(vault.hasActiveDeposit(address(pool)), "Deposit still active");
    }

    function test_RetryWithdrawal_SucceedsAfterUnlock() public {
        NectarPool pool = _createUSDCPool();
        uint256 amount = 1000e18;

        // Deposit
        usdc.mint(address(pool), amount);
        vm.startPrank(address(pool));
        usdc.approve(address(vault), amount);
        vault.depositAndSupply(address(pool), address(usdc), amount);

        // Lock, attempt withdrawal (fails)
        aave.setLocked(true);
        vault.withdrawAndReturn(address(pool));
        vm.stopPrank();

        // Unlock Aave
        aave.setLocked(false);

        // Retry (callable by anyone)
        (uint256 principal, uint256 yield, bool success) = vault.retryWithdrawal(address(pool));

        assertTrue(success, "Retry should succeed after unlock");
        assertEq(principal, amount);
        assertGt(yield, 0, "Should have yield now");
        assertFalse(vault.hasActiveDeposit(address(pool)));
        assertFalse(vault.isDelayed(address(pool)));
    }

    // ─── 7. Edge Cases ───────────────────────────────────────────────────────

    function test_DepositAndSupply_RejectsZeroAmount() public {
        NectarPool pool = _createUSDCPool();

        vm.prank(address(pool));
        vm.expectRevert("NectarVault: zero amount");
        vault.depositAndSupply(address(pool), address(usdc), 0);
    }

    function test_DepositAndSupply_RejectsDuplicateDeposit() public {
        NectarPool pool = _createUSDCPool();
        uint256 amount = 1000e18;

        usdc.mint(address(pool), amount * 2);
        vm.startPrank(address(pool));
        usdc.approve(address(vault), amount * 2);
        vault.depositAndSupply(address(pool), address(usdc), amount);

        vm.expectRevert("NectarVault: pool already has active deposit");
        vault.depositAndSupply(address(pool), address(usdc), amount);
        vm.stopPrank();
    }

    function test_WithdrawAndReturn_RejectsNoDeposit() public {
        NectarPool pool = _createUSDCPool();

        vm.prank(address(pool));
        vm.expectRevert("NectarVault: no active deposit for pool");
        vault.withdrawAndReturn(address(pool));
    }

    // ─── 8. Slippage Protection ──────────────────────────────────────────────

    function test_Swap_RejectsExcessiveSlippage() public {
        NectarPool pool = _createGDollarPool();
        uint256 amount = 1000e18;

        // Set swap rate to 95% (5% slippage — exceeds our 1% cap)
        router.setRate(9500);

        gdollar.mint(address(pool), amount);
        vm.startPrank(address(pool));
        gdollar.approve(address(vault), amount);
        vm.expectRevert("MockSwap: slippage exceeded");
        vault.depositAndSupply(address(pool), address(gdollar), amount);
        vm.stopPrank();
    }

    function test_Swap_AcceptsWithinSlippage() public {
        NectarPool pool = _createGDollarPool();
        uint256 amount = 1000e18;

        // Set swap rate to 99.5% (0.5% — within our 1% cap)
        router.setRate(9950);

        gdollar.mint(address(pool), amount);
        vm.startPrank(address(pool));
        gdollar.approve(address(vault), amount);
        vault.depositAndSupply(address(pool), address(gdollar), amount);
        vm.stopPrank();

        assertTrue(vault.hasActiveDeposit(address(pool)));
        assertEq(vault.getPrincipal(address(pool)), amount * 9950 / 10_000);
    }
}
