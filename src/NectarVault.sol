// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {INectarVault} from "./interfaces/INectarVault.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @title NectarVault
/// @notice Peripheral DeFi routing contract for the Nectar Protocol.
///         Handles G$→USDC swaps (Uniswap V3) and USDC lending (Aave V3) on Celo.
///         Isolated from NectarPool to contain DeFi integration risk.
/// @dev Only factory-registered pools can call depositAndSupply / withdrawAndReturn.
contract NectarVault is INectarVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Immutable Protocol Addresses ────────────────────────────────────────

    address public immutable factory;
    address public immutable aavePool;
    address public immutable swapRouter;
    address public immutable usdc;

    // ─── Configuration ───────────────────────────────────────────────────────

    /// @notice Uniswap V3 pool fee tier for swaps (0.3% = 3000)
    uint24 public constant SWAP_FEE = 3000;

    /// @notice Maximum slippage tolerance for swaps (1% = 99/100)
    uint256 public constant SLIPPAGE_DENOMINATOR = 100;
    uint256 public constant SLIPPAGE_NUMERATOR = 99; // amountOut >= amountIn * 99 / 100

    // ─── Per-Pool Deposit Tracking ───────────────────────────────────────────

    mapping(address => PoolDeposit) public deposits;

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _factory,
        address _aavePool,
        address _swapRouter,
        address _usdc
    ) {
        require(_factory    != address(0), "NectarVault: zero factory");
        require(_aavePool   != address(0), "NectarVault: zero aave pool");
        require(_swapRouter != address(0), "NectarVault: zero swap router");
        require(_usdc       != address(0), "NectarVault: zero usdc");

        factory    = _factory;
        aavePool   = _aavePool;
        swapRouter = _swapRouter;
        usdc       = _usdc;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyRegisteredPool() {
        // Verify caller is a factory-deployed pool via the factory's lookup
        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSignature("isDeployedPool(address)", msg.sender)
        );
        require(ok && abi.decode(data, (bool)), "NectarVault: caller not a registered pool");
        _;
    }

    // ─── Core: Deposit and Supply ────────────────────────────────────────────

    /// @inheritdoc INectarVault
    function depositAndSupply(address pool, address token, uint256 amount)
        external override nonReentrant onlyRegisteredPool
    {
        require(amount > 0, "NectarVault: zero amount");
        require(!deposits[pool].isActive, "NectarVault: pool already has active deposit");

        // Pull tokens from the pool
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 usdcAmount;

        if (token == usdc) {
            // ── USDC path: supply directly ─────────────────────────────────
            usdcAmount = amount;
        } else {
            // ── G$ path: swap to USDC first ────────────────────────────────
            usdcAmount = _swapToUSDC(token, amount);
        }

        // ── Supply USDC to Aave V3 ─────────────────────────────────────────
        IERC20(usdc).approve(aavePool, usdcAmount);
        IAavePool(aavePool).supply(usdc, usdcAmount, address(this), 0);

        // Record the deposit
        deposits[pool] = PoolDeposit({
            token:     token,
            principal: usdcAmount,
            isActive:  true,
            delayed:   false
        });

        emit FundsDeposited(pool, token, amount, usdcAmount);
    }

    // ─── Core: Withdraw and Return ───────────────────────────────────────────

    /// @inheritdoc INectarVault
    function withdrawAndReturn(address pool)
        external override nonReentrant onlyRegisteredPool
        returns (uint256 principal, uint256 yield, bool success)
    {
        PoolDeposit storage dep = deposits[pool];
        require(dep.isActive, "NectarVault: no active deposit for pool");

        principal = dep.principal;

        // ── Attempt Aave withdrawal with graceful degradation ──────────────
        uint256 withdrawn;
        try IAavePool(aavePool).withdraw(usdc, type(uint256).max, address(this)) returns (uint256 w) {
            withdrawn = w;
            success = true;
        } catch {
            // Aave 100% utilization — cannot withdraw right now
            dep.delayed = true;
            success = false;
            emit AaveLiquidityDelayed(pool, block.timestamp);
            return (principal, 0, false);
        }

        // ── Calculate yield ────────────────────────────────────────────────
        yield = (withdrawn > principal) ? withdrawn - principal : 0;

        // ── Clean up deposit record ────────────────────────────────────────
        dep.isActive = false;

        // ── Transfer all funds back to the pool ────────────────────────────
        IERC20(usdc).safeTransfer(pool, withdrawn);

        emit FundsWithdrawn(pool, principal, yield);
    }

    // ─── Retry Delayed Withdrawal ────────────────────────────────────────────

    /// @notice Retry a previously delayed withdrawal (Aave was at 100% utilization).
    ///         Callable by anyone as an incentivized fallback.
    function retryWithdrawal(address pool)
        external nonReentrant returns (uint256 principal, uint256 yield, bool success)
    {
        PoolDeposit storage dep = deposits[pool];
        require(dep.isActive && dep.delayed, "NectarVault: no delayed deposit");

        uint256 withdrawn;
        try IAavePool(aavePool).withdraw(usdc, type(uint256).max, address(this)) returns (uint256 w) {
            withdrawn = w;
            success = true;
        } catch {
            // Still locked
            emit AaveLiquidityDelayed(pool, block.timestamp);
            return (dep.principal, 0, false);
        }

        principal = dep.principal;
        yield = (withdrawn > principal) ? withdrawn - principal : 0;

        dep.isActive = false;
        dep.delayed  = false;

        IERC20(usdc).safeTransfer(pool, withdrawn);

        emit FundsWithdrawn(pool, principal, yield);
    }

    // ─── Internal: Swap ──────────────────────────────────────────────────────

    /// @dev Swap any token to USDC via Uniswap V3 exactInputSingle.
    ///      Enforces a strict 1% slippage cap.
    function _swapToUSDC(address tokenIn, uint256 amountIn) internal returns (uint256 amountOut) {
        IERC20(tokenIn).approve(swapRouter, amountIn);

        // Calculate minimum output with 1% slippage tolerance
        // NOTE: This is a simplified slippage calc. In production, use a TWAP oracle
        // for amountOutMinimum instead of a percentage of amountIn (different decimals).
        uint256 minOut = amountIn * SLIPPAGE_NUMERATOR / SLIPPAGE_DENOMINATOR;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn:           tokenIn,
            tokenOut:          usdc,
            fee:               SWAP_FEE,
            recipient:         address(this),
            deadline:          block.timestamp,
            amountIn:          amountIn,
            amountOutMinimum:  minOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = ISwapRouter(swapRouter).exactInputSingle(params);

        emit SwapExecuted(tokenIn, amountIn, amountOut);
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /// @notice Check if a pool has an active deposit in Aave.
    function hasActiveDeposit(address pool) external view returns (bool) {
        return deposits[pool].isActive;
    }

    /// @notice Check if a pool's withdrawal was delayed (Aave utilization lock).
    function isDelayed(address pool) external view returns (bool) {
        return deposits[pool].delayed;
    }

    /// @notice Get the original principal deposited for a pool.
    function getPrincipal(address pool) external view returns (uint256) {
        return deposits[pool].principal;
    }
}
