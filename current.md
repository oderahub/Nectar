# Nectar Protocol — Current Sprint Status

> **Last updated:** 2026-02-26  
> **Sprint scope:** Core smart contracts + comprehensive test coverage  
> **Out of scope this sprint:** Chainlink VRF integration, Keeper automation, frontend, mainnet deployment

---

## What Is Nectar Protocol?

Nectar is a **trustless, no-loss savings protocol** on the Celo blockchain. It combines group savings (rotating savings circles / ROSCAs) with DeFi yield generation to create a system where members save together, their pooled funds earn yield via Aave V3, and winners are selected randomly to receive bonus payouts — all while guaranteeing every participant gets at least their principal back.

The protocol specifically targets the **GoodDollar (G$)** ecosystem on Celo, using GoodDollar's identity verification (FaceTec scans) as an anti-Sybil mechanism. Pools can also accept USDC directly.

---

## What We Built & Why

### 1. `NectarMath.sol` — The Economic Engine

**What it does:** Pure math library containing all the protocol's economic calculations in isolated, gas-efficient functions.

**Why we built it first:** Following TDD, we needed the math to be rock-solid before building any stateful contracts on top. Every function is stateless and independently testable.

**Key functions:**
- `perMemberAmount()` — Divides the pool target evenly across members
- `lateJoinerRate()` — Calculates a higher deposit-per-cycle rate for members who join mid-pool, so they catch up to early joiners
- `isBelowTwoXCap()` — Enforces that late joiners never pay more than **2× the base rate** (protects against exploitative join timing)
- `isAboveThreeCycleFloor()` — Ensures at least **3 deposit cycles remain** when a new member joins (prevents last-minute joins that would compress all payments into 1-2 cycles)
- `fillThreshold()` — Checks if at least **50% of max slots** are filled before proceeding to yield phase (prevents under-filled pools from wasting gas on DeFi operations)
- `protocolFee()` — Calculates the **5% treasury fee** on earned yield
- `remainingCycles()` — Helper to compute cycles left for a member
- `adjustWinners()` — Reduces the winner count if too many members withdrew, or forces cancellation if only 1 member remains
- `finalCycleRounding()` — Handles the last cycle's deposit to ensure the total deposited hits the exact target (avoids dust from integer division)

**Tests:** 36 unit tests + 2 fuzz tests (256 runs each) covering every edge case — rounding, boundary conditions, zero values, extreme inputs.

---

### 2. `NectarFactory.sol` — The Deployment Hub

**What it does:** Single entry point for creating new savings pools using the **EIP-1167 Minimal Proxy Clone** pattern.

**Why we built it:**
- **Gas efficiency:** Deploying full contract copies for each pool would cost ~3M gas. Clones cost ~50K gas — a 98% reduction.
- **Centralized governance:** The factory enforces global limits (max 3 active pools per wallet) and stores addresses for the vault, VRF module, identity contract, and treasury.
- **Trust chain:** The factory's `isDeployedPool` mapping creates a verifiable on-chain trust chain. Only pools deployed through the factory can interact with the vault and other protocol peripherals.

**Key design decisions:**
- `isDeployedPool` mapping is **public** so `NectarVault` can verify callers via `staticcall`
- `activePoolCount` tracks per-creator pool limits
- Pool initialization uses `initialise()` (not constructor) because clones don't execute constructors

---

### 3. `NectarPool.sol` — The Core Savings Contract

**What it does:** Manages the entire lifecycle of a single savings pool — from enrollment through deposit collection, phase transitions, and eventually settlement.

**Why it's the largest contract:** It's the state machine that orchestrates everything. Each pool progresses through: `ENROLLMENT → SAVING → YIELDING → DRAWING → SETTLED` (or `CANCELLED`).

**Lifecycle phases:**

| Phase | What Happens |
|---|---|
| **ENROLLMENT** | Members join, pay their first deposit. Late joiners get recalculated rates. |
| **SAVING** | Enrollment window closes. Members make weekly deposits. Missed cycles tracked. |
| **YIELDING** | All funds sent to NectarVault for Aave V3 lending. Yield accrues. |
| **DRAWING** | VRF randomness requested. Winners selected. |
| **SETTLED** | Funds distributed: winners get principal + yield share. Non-winners get principal. Everyone claims. |
| **CANCELLED** | Pool didn't meet 50% fill threshold. All principals refunded. |

**Key features we implemented:**

- **Lazy eviction (`_lazyEvict`):** If a member misses **2+ consecutive deposit cycles**, they are automatically removed on their next interaction (deposit/batchDeposit). Their principal is queued in `claimable[]` for refund. This is gas-efficient because it doesn't require active monitoring — eviction logic runs lazily when the member (or anyone) next touches the contract.

- **`checkAndEvict()` public function:** Allows keepers or any external caller to trigger eviction for a specific member without needing to be that member. Useful for protocol hygiene and testing.

- **`_transitionToSavingIfNeeded()`:** Lazy state transition from ENROLLMENT to SAVING. The pool doesn't need an explicit "start saving" call — it auto-detects when the enrollment window has closed (first 50% of total cycles) and transitions state.

- **`batchDeposit()`:** Handles the "missed exactly 1 cycle" case gracefully. If a member missed one cycle but not two (which would trigger eviction), they can catch up by paying for both the missed cycle and the current one in a single transaction.

- **Emergency withdrawal:** Members can exit during ENROLLMENT or SAVING phases and reclaim their full principal. The contract correctly handles the state cleanup (marking as removed, decrementing active count, adjusting winner count).

- **GoodDollar identity check:** At `joinPool()`, the contract calls `IGoodDollarIdentity.isWhitelisted()` to verify the member has completed a FaceTec scan. This is checked only at join time — mid-cycle identity expiration does NOT block deposits (per architecture rules).

**Tests:** 39 integration tests covering pool creation, joining, deposits, batch deposits, emergency withdrawals, lazy eviction, full settlement lifecycle (mock VRF), no-prize settlement, claim guards, cancelled pool refunds, factory limits, and fuzz testing of join rate invariants.

---

### 4. `NectarVault.sol` — The DeFi Yield Engine

**What it does:** Peripheral contract that handles all external DeFi protocol interactions — isolating risk from the core pool logic.

**Why it's separate:** If there's a bug or exploit in Aave V3 or Uniswap V3, it should NOT compromise member deposits or the pool's internal accounting. The vault is the blast radius containment layer.

**Two token paths:**
1. **USDC pools:** Funds are supplied directly to Aave V3 — no swap needed.
2. **G$ pools:** Funds are first swapped from G$ → USDC via Uniswap V3 `exactInputSingle`, then supplied to Aave.

**Key features:**

- **1% slippage cap:** All swaps enforce `amountOutMinimum = amountIn * 99 / 100`. This prevents sandwich attacks and protects against extreme price movements during the swap.

- **Aave 100% utilization fallback:** When Aave has all its USDC lent out (100% utilization), `withdraw()` reverts. Instead of bricking the pool, we wrap the call in `try/catch`, emit an `AaveLiquidityDelayed` event, and mark the deposit as `delayed`. The pool stays in `DRAWING` state and a separate `retryWithdrawal()` function can be called later by anyone (incentivized keeper or any user).

- **Per-pool deposit tracking:** Each pool's deposit is tracked independently via `mapping(address => PoolDeposit)`. This means multiple pools can have funds in Aave simultaneously without interfering with each other.

- **Access control:** Only factory-registered pools can call `depositAndSupply` and `withdrawAndReturn`. This is verified via `staticcall` to the factory's `isDeployedPool` mapping.

**Celo mainnet addresses (hardcoded for production):**
| Contract | Address |
|---|---|
| Aave V3 Pool | `0x3176252C3E57a8a1B898952b1239c585c5F89104` |
| Uniswap V3 SwapRouter | `0x5615CDAb3dDc9B98bF3031aA4BfA784364D36806` |
| G$ Token | `0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c7A` |
| USDC (Celo native) | `0x01C5C0122039549AD1493B8220cABEdD739BC44E` |

**Tests:** 14 unit tests using mock Aave and mock Uniswap contracts. Covers both token paths, yield calculation, graceful degradation, retry logic, access control, slippage protection, and edge cases.

---

### 5. Supporting Infrastructure

**Mock contracts (for testing):**
- `MockERC20.sol` — Minimal ERC20 with public `mint()` for testing
- `MockGoodDollarIdentity.sol` — Simulates FaceTec identity verification
- `MockAavePool.sol` — Tracks supplies, returns configurable yield, can simulate 100% utilization lock
- `MockSwapRouter.sol` — Simulates Uniswap V3 swaps with configurable exchange rate

**Interfaces:**
- `INectarPool.sol` — Full pool interface with all enums, structs, events, and function signatures
- `INectarVault.sol` — Vault interface with `depositAndSupply`, `withdrawAndReturn`
- `IAavePool.sol` — Minimal Aave V3 `supply()` + `withdraw()` interface
- `ISwapRouter.sol` — Minimal Uniswap V3 `exactInputSingle` interface
- `IGoodDollarIdentity.sol` — GoodDollar identity check interface

**Build configuration (`foundry.toml`):**
- `via_ir = true` — Required to avoid "stack too deep" errors from large struct tuple unpacking
- `optimizer = true` with 200 runs — Keeps bytecode compact
- RPC endpoints configured for `celo_mainnet` and `celo_sepolia`

---

## Test Results Summary

```
forge test -vv
94 tests passed, 0 failed, 0 skipped (5 test suites)
```

| Test Suite | Tests | Status |
|---|---|---|
| `NectarMathTest` | 36 + 2 fuzz (256 runs each) | ✅ All pass |
| `NectarPoolTest` | 39 (incl. 1 fuzz) | ✅ All pass |
| `NectarVaultTest` | 14 | ✅ All pass |
| **Total** | **94** | ✅ **All pass** |

**Contract sizes (well within 24KB limit):**
| Contract | Runtime Size | Headroom |
|---|---|---|
| NectarPool | 10.2 KB | 57% free |
| NectarFactory | 3.2 KB | 86% free |
| NectarVault | ~4 KB (est.) | ~83% free |

---

## What's NOT in This Sprint

The following are explicitly **deferred to future sprints**:

1. **Chainlink VRF (`NectarVRF.sol`)** — Winner randomness generation. Currently mocked in tests via direct `fulfillDraw()` calls.
2. **Chainlink Automation (Keepers)** — Automated phase transitions (`checkUpkeep`/`performUpkeep`).
3. **Frontend** — No UI exists yet.
4. **Fork-based integration tests** — Tests currently use mocks, not real Celo mainnet state.
5. **Mainnet deployment** — No deploy scripts or migration tooling.

---

## Roadmap

### Sprint 2 — Chainlink Integration & Automation
- [ ] Implement `NectarVRF.sol` — Chainlink VRF V2+ consumer for provably fair winner selection
- [ ] Implement Keeper contract — `checkUpkeep()` / `performUpkeep()` for automated SAVING→YIELDING→DRAWING transitions
- [ ] Add incentivized fallback: public `withdrawAndRequestDraw()` so any user can trigger transitions if Keepers go offline
- [ ] Wire `NectarPool.endYieldPhase()` to actually call `NectarVRF.requestDraw()`
- [ ] Integration tests using mocked VRF coordinator

### Sprint 3 — Fork Tests & Security
- [ ] Fork-based integration tests against real Celo mainnet Aave V3 + Uniswap V3
- [ ] Verify G$→USDC swap path works with real liquidity (check if direct pool exists or needs G$→CELO→USDC routing)
- [ ] Gas optimization pass
- [ ] Invariant testing / formal verification for critical math functions
- [ ] Internal security review + fix any findings

### Sprint 4 — Testnet Deployment
- [ ] Write Foundry deploy scripts (`script/Deploy.s.sol`)
- [ ] Deploy to Celo (testnet)
- [ ] End-to-end testing with real Chainlink VRF and Keeper infrastructure
- [ ] Monitor gas costs and optimize if needed

### Sprint 5 — Frontend
- [ ] Design UI/UX for pool creation, joining, deposits, and claims
- [ ] Implement web frontend (Next.js + wagmi/viem)
- [ ] Connect to deployed testnet contracts
- [ ] User testing and iteration

### Sprint 6 — Audit & Mainnet
- [ ] External smart contract audit
- [ ] Address audit findings
- [ ] Celo mainnet deployment
- [ ] Monitoring and alerting setup
- [ ] Documentation and launch

---

## File Structure

```
nectar-protocol/
├── ARCHITECTURE.md              # Core design rules and constraints
├── current.md                   # This file — sprint status
├── foundry.toml                 # Build config (via_ir, optimizer, RPCs)
├── src/
│   ├── NectarPool.sol           # Core savings pool state machine
│   ├── NectarFactory.sol        # EIP-1167 clone factory
│   ├── NectarVault.sol          # DeFi yield engine (Aave + Uniswap)
│   ├── MockERC20.sol            # Test helper — mintable ERC20
│   ├── MockGoodDollarIdentity.sol # Test helper — identity mock
│   ├── interfaces/
│   │   ├── INectarPool.sol      # Pool interface + enums/structs
│   │   ├── INectarVault.sol     # Vault interface
│   │   ├── IAavePool.sol        # Minimal Aave V3 interface
│   │   ├── ISwapRouter.sol      # Minimal Uniswap V3 interface
│   │   └── IGoodDollarIdentity.sol # GoodDollar identity interface
│   ├── libraries/
│   │   └── NectarMath.sol       # Pure economic calculations
│   └── mocks/
│       ├── MockAavePool.sol     # Test mock — Aave V3
│       └── MockSwapRouter.sol   # Test mock — Uniswap V3
├── test/
│   ├── NectarMath.t.sol         # 38 tests (36 unit + 2 fuzz)
│   ├── NectarPool.t.sol         # 39 tests (integration + 1 fuzz)
│   └── NectarVault.t.sol        # 14 tests (mock-based)
└── lib/
    ├── forge-std/               # Foundry test framework
    └── openzeppelin-contracts/  # OpenZeppelin v5
```
