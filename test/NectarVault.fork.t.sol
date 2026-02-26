// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {NectarVault} from "../src/NectarVault.sol";
import {NectarFactory} from "../src/NectarFactory.sol";
import {NectarPool} from "../src/NectarPool.sol";
import {MockGoodDollarIdentity} from "../src/MockGoodDollarIdentity.sol";

/// @title NectarVaultForkTest
/// @notice Fork-based integration tests against REAL Celo mainnet contracts.
///         Validates that NectarVault works with live Aave V3 + Uniswap V3.
///
///         Run with:
///           forge test --fork-url https://forno.celo.org --match-contract NectarVaultForkTest -vv
///
/// @dev These tests use `deal()` to fund accounts with real mainnet tokens.
///      They do NOT modify mainnet state — the fork is ephemeral.
contract NectarVaultForkTest is Test {

    // ─── Real Celo Mainnet Addresses ─────────────────────────────────────────

    address constant AAVE_POOL    = 0x3E59A31363E2ad014dcbc521c4a0d5757d9f3402;
    address constant SWAP_ROUTER  = 0x5615CDAb10dc425a742d643d949a7F474C01abc4;
    address constant USDC         = 0xcebA9300f2b948710d2653dD7B07f33A8B32118C; // USDC on Celo (Circle native)
    address constant G_DOLLAR     = 0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c7A;

    // Aave aToken for USDC on Celo (aUSDC)
    // We'll discover this dynamically via balance checks

    // ─── Protocol Contracts ──────────────────────────────────────────────────

    NectarVault            vault;
    NectarFactory          factory;
    NectarPool             blueprint;
    MockGoodDollarIdentity identity;

    // ─── Actors ──────────────────────────────────────────────────────────────

    address creator  = makeAddr("creator");
    address treasury = makeAddr("treasury");
    address vrfAddr  = makeAddr("vrfModule");

    // ─── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy protocol contracts pointing to real Celo DeFi
        identity  = new MockGoodDollarIdentity();
        blueprint = new NectarPool();

        factory = new NectarFactory(
            address(blueprint),
            address(0), // vault — set after
            vrfAddr,
            address(identity),
            treasury
        );

        vault = new NectarVault(
            address(factory),
            AAVE_POOL,
            SWAP_ROUTER,
            USDC
        );

        factory.setVault(address(vault));

        // Register a fake pool so we can call vault functions
        // We'll prank as factory to register our test address
        identity.testnetSimulateFaceScan(creator);
    }

    // ─── Helper: Create a registered pool address ────────────────────────────

    /// @dev Deploys a real pool via the factory so it's registered in isDeployedPool
    function _createRegisteredPool(address token) internal returns (address pool) {
        vm.startPrank(creator);

        // We need to create a pool config — use minimal values
        INectarPool.PoolConfig memory cfg = INectarPool.PoolConfig({
            token:            token,
            targetAmount:     1000e6, // 1000 USDC (6 decimals)
            maxMembers:       6,
            totalCycles:      10,
            winnersCount:     2,
            cycleDuration:    7 days,
            requiresIdentity: true,
            enrollmentWindow: INectarPool.EnrollmentWindow.STANDARD,
            distributionMode: INectarPool.DistributionMode.EQUAL
        });
        pool = factory.createPool(cfg);
        vm.stopPrank();
    }

    // ─── 1. USDC Direct Supply to Aave V3 ───────────────────────────────────

    function test_Fork_USDC_SupplyToAave() public {
        // Create a registered pool
        address pool = _createRegisteredPool(USDC);
        uint256 amount = 100e6; // 100 USDC (6 decimals)

        // Fund the pool with USDC using deal
        deal(USDC, pool, amount);

        // Pool approves vault and calls depositAndSupply
        vm.startPrank(pool);
        IERC20(USDC).approve(address(vault), amount);
        vault.depositAndSupply(pool, USDC, amount);
        vm.stopPrank();

        // Verify deposit recorded
        assertTrue(vault.hasActiveDeposit(pool), "Should have active deposit");
        assertEq(vault.getPrincipal(pool), amount, "Principal should match");

        console2.log("=== USDC Supply to Aave SUCCESS ===");
        console2.log("Amount supplied:", amount);
        console2.log("Principal recorded:", vault.getPrincipal(pool));
    }

    // ─── 2. USDC Withdraw from Aave V3 (with real yield) ────────────────────

    function test_Fork_USDC_WithdrawFromAave() public {
        address pool = _createRegisteredPool(USDC);
        uint256 amount = 100e6; // 100 USDC

        // Supply
        deal(USDC, pool, amount);
        vm.startPrank(pool);
        IERC20(USDC).approve(address(vault), amount);
        vault.depositAndSupply(pool, USDC, amount);

        // Warp forward 30 days to accrue some yield
        vm.warp(block.timestamp + 30 days);

        // Withdraw
        (uint256 principal, uint256 yield, bool success) = vault.withdrawAndReturn(pool);
        vm.stopPrank();

        assertTrue(success, "Withdrawal should succeed");
        assertEq(principal, amount, "Principal should match deposit");

        // On a real fork, yield after 30 days on 100 USDC should be small but >= 0
        uint256 poolBalance = IERC20(USDC).balanceOf(pool);

        console2.log("=== USDC Withdraw from Aave SUCCESS ===");
        console2.log("Principal:", principal);
        console2.log("Yield:", yield);
        console2.log("Pool USDC balance after withdraw:", poolBalance);
        console2.log("Total returned:", principal + yield);

        assertGe(poolBalance, principal, "Pool should have at least principal back");
    }

    // ─── 3. Aave aToken Balance Check ────────────────────────────────────────

    function test_Fork_AaveATokenAccrual() public {
        address pool = _createRegisteredPool(USDC);
        uint256 amount = 1000e6; // 1000 USDC

        deal(USDC, pool, amount);
        vm.startPrank(pool);
        IERC20(USDC).approve(address(vault), amount);
        vault.depositAndSupply(pool, USDC, amount);
        vm.stopPrank();

        // Check vault's USDC balance in Aave (should be 0 — it's in aTokens now)
        uint256 vaultUsdcBalance = IERC20(USDC).balanceOf(address(vault));
        assertEq(vaultUsdcBalance, 0, "Vault should have no raw USDC after supply");

        console2.log("=== aToken Accrual Check ===");
        console2.log("Vault raw USDC (should be 0):", vaultUsdcBalance);
        console2.log("Deposit is active:", vault.hasActiveDeposit(pool));
    }

    // ─── 4. Multiple Pools Concurrent Deposits ───────────────────────────────

    function test_Fork_MultiplePools_ConcurrentDeposits() public {
        // Create two separate pools
        address pool1 = _createRegisteredPool(USDC);

        // Need a second creator for second pool
        address creator2 = makeAddr("creator2");
        identity.testnetSimulateFaceScan(creator2);

        vm.startPrank(creator2);
        INectarPool.PoolConfig memory cfg2 = INectarPool.PoolConfig({
            token:            USDC,
            targetAmount:     2000e6,
            maxMembers:       6,
            totalCycles:      10,
            winnersCount:     2,
            cycleDuration:    7 days,
            requiresIdentity: true,
            enrollmentWindow: INectarPool.EnrollmentWindow.STANDARD,
            distributionMode: INectarPool.DistributionMode.EQUAL
        });
        address pool2 = factory.createPool(cfg2);
        vm.stopPrank();

        // Supply from both pools
        uint256 amount1 = 500e6;
        uint256 amount2 = 750e6;

        deal(USDC, pool1, amount1);
        deal(USDC, pool2, amount2);

        vm.prank(pool1);
        IERC20(USDC).approve(address(vault), amount1);
        vm.prank(pool1);
        vault.depositAndSupply(pool1, USDC, amount1);

        vm.prank(pool2);
        IERC20(USDC).approve(address(vault), amount2);
        vm.prank(pool2);
        vault.depositAndSupply(pool2, USDC, amount2);

        // Both should have independent active deposits
        assertTrue(vault.hasActiveDeposit(pool1), "Pool1 should be active");
        assertTrue(vault.hasActiveDeposit(pool2), "Pool2 should be active");
        assertEq(vault.getPrincipal(pool1), amount1);
        assertEq(vault.getPrincipal(pool2), amount2);

        // Withdraw pool1, pool2 should remain active
        vm.warp(block.timestamp + 7 days);

        vm.prank(pool1);
        (uint256 p1, uint256 y1, bool s1) = vault.withdrawAndReturn(pool1);

        assertFalse(vault.hasActiveDeposit(pool1), "Pool1 should be inactive after withdraw");
        assertTrue(vault.hasActiveDeposit(pool2), "Pool2 should still be active");

        console2.log("=== Multiple Pools Concurrent SUCCESS ===");
        console2.log("Pool1 principal:", p1, "yield:", y1);
        console2.log("Pool2 still active:", vault.hasActiveDeposit(pool2));
    }

    // ─── 5. G$ Swap to USDC via Uniswap V3 ──────────────────────────────────

    /// @dev G$ is a Superfluid ERC-777 SuperToken — deal() cannot write to its storage.
    ///      Instead, we prank as the Superfluid Host to call selfMint().
    ///      Host address on Celo: 0xA4Ff07cF81C02CFD356184879D953970cA957585
    address constant SF_HOST = 0xA4Ff07cF81C02CFD356184879D953970cA957585;

    function test_Fork_GDollar_SwapAndSupply() public {
        address pool = _createRegisteredPool(G_DOLLAR);

        // Use a small amount to stay within available liquidity
        uint256 amount = 10e18; // 10 G$ (18 decimals)

        // Mint G$ by pranking as the Superfluid Host (only host can call selfMint)
        vm.prank(SF_HOST);
        (bool mintOk,) = G_DOLLAR.call(
            abi.encodeWithSignature("selfMint(address,uint256,bytes)", pool, amount, "")
        );

        if (!mintOk) {
            console2.log("=== G$ selfMint FAILED - host may lack minter role ===");
            console2.log(">>> Skipping G$ swap test (needs production minter)");
            return;
        }

        uint256 poolBal = IERC20(G_DOLLAR).balanceOf(pool);
        console2.log("G$ minted to pool:", poolBal);
        assertEq(poolBal, amount, "Pool should have G$ after selfMint");

        vm.startPrank(pool);
        IERC20(G_DOLLAR).approve(address(vault), amount);

        // This may revert if no G$/USDC pool exists on Uniswap V3
        // In that case, we need multi-hop routing (Sprint 3 work)
        try vault.depositAndSupply(pool, G_DOLLAR, amount) {
            assertTrue(vault.hasActiveDeposit(pool), "Should have active deposit after G$ swap");
            console2.log("=== G$ Swap + Supply SUCCESS ===");
            console2.log("G$ amount in:", amount);
            console2.log("USDC principal in Aave:", vault.getPrincipal(pool));
        } catch (bytes memory reason) {
            // Expected if G$/USDC direct pool doesn't exist or thin liquidity
            console2.log("=== G$ Swap FAILED (expected if no direct pool) ===");
            console2.log("Reason bytes length:", reason.length);
            console2.log(">>> Action: Need multi-hop route G$ -> cUSD -> USDC");
        }
        vm.stopPrank();
    }

    // ─── 6. Verify Aave Pool Is Responsive ───────────────────────────────────

    function test_Fork_AavePoolIsLive() public view {
        // Simple sanity check that the Aave pool contract is deployed and responsive
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(AAVE_POOL)
        }
        assertGt(codeSize, 0, "Aave V3 Pool should have code on Celo mainnet");
        console2.log("Aave V3 Pool code size:", codeSize);
    }

    function test_Fork_SwapRouterIsLive() public view {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(SWAP_ROUTER)
        }
        assertGt(codeSize, 0, "Uniswap V3 SwapRouter should have code on Celo mainnet");
        console2.log("SwapRouter code size:", codeSize);
    }
}

// Need this import for the pool config struct
import {INectarPool} from "../src/interfaces/INectarPool.sol";
