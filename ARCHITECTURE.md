# Gnosis Safe Hedge Fund Architecture

## Overview

This is a decentralized hedge fund built on top of Gnosis Safe, designed to allow a fund manager to deploy capital off-chain while maintaining on-chain share accounting, fee management, and transparency.

## Core Concept

**The Challenge**: Traditional DeFi vaults require all assets on-chain. This limits investment strategies to DEX trades, lending protocols, etc. Real hedge funds need flexibility to trade on CEXs, invest in RWAs, or use sophisticated strategies not available on-chain.

**The Solution**: This architecture allows the fund manager to:
1. Accept deposits on-chain (users get ERC20 shares)
2. Move capital to Gnosis Safe wallet (controlled by manager)
3. Deploy capital anywhere (CEXs, RWAs, traditional markets)
4. Report AUM periodically via keeper/oracle
5. Process redemptions from on-chain liquidity or Safe wallet
6. Accrue fees based on reported AUM

## Contract Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    SafeHedgeFundVault.sol                       │
│                   (Main Contract - ERC20 / HFS)                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ • Deposits → Queue → Mint Shares                         │  │
│  │ • Redemptions → Queue → Burn Shares → Payout            │  │
│  │ • AUM Updates → Fee Accrual → NAV Calculation           │  │
│  │ • Emergency Mode → Direct Withdrawals                    │  │
│  │ • Pool Callbacks (mint/burn/addToAum/subFromAum)        │  │
│  │ • At updateAum tail: pool.sweepLiquidations()           │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Uses 4 Core Library Contracts (storage via library pattern):   │
│  ┌────────────┬────────────┬────────────┬────────────┐        │
│  │ConfigMgr   │FeeManager  │QueueMgr    │EmergencyMgr│        │
│  │(Timelock)  │(Economics) │(Deposits/  │(Crisis     │        │
│  │            │            │Redemptions)│Handling)   │        │
│  └────────────┴────────────┴────────────┴────────────┘        │
│  Located in: contracts/core/                                     │
└─────────────────────────────────────────────────────────────────┘
              ↕ Module Calls         ↕ pool callbacks
┌─────────────────────────────┐  ┌─────────────────────────────┐
│      Gnosis Safe Wallet      │  │   SharedPool (lending)      │
│   (Multi-sig, off-chain ops) │  │ contracts/lending/          │
│  • Holds majority of fund    │  │  • USDC reserve (real)      │
│  • Vault is module           │  │  • hfsReserve (derived)     │
│  • execTransactionFromModule │  │  • xy=k swaps               │
└─────────────────────────────┘  │  • Borrow against HFS coll. │
                                  │  • Auto-liquidation sweep   │
                                  └─────────────────────────────┘

See docs/LENDING.md for the lending pool design in depth.
```

## Key Components

### 1. ConfigManager.sol - Governance & Security
**Purpose**: Prevents rug pulls through timelock system

**Key Features**:
- 3-day timelock on all configuration changes
- 5-day cooldown between changes to same parameter
- Validates all values against hardcoded limits
- One active proposal per parameter

**Why It's Important**:
Users can see pending changes and exit before they take effect. Admin can't suddenly change fees to 100% or drain the fund.

---

### 2. FeeManager.sol - Economic Engine
**Purpose**: Manages all fee calculations and high water mark

**Fee Types**:
1. **Management Fee** (annual % of AUM) - Continuous compensation
2. **Performance Fee** (% of profits above HWM) - Success-based compensation
3. **Entrance Fee** (one-time on deposits) - Anti-gaming, covers deployment costs
4. **Exit Fee** (one-time on redemptions) - Anti-gaming, covers liquidation costs

**High Water Mark (HWM)**:
- Performance fees only charged on profits above previous highest NAV
- Prevents charging fees on same gains twice
- Configurable reset after significant drawdown + recovery period
- Example: HWM at $100, drops to $50, recovers to $120 → Only charge fees on $20 gain ($100→$120)

**Why It's Important**:
Fair fee structure protects investors while compensating manager for performance.

---

### 3. QueueManager.sol - Deposit/Redemption Flow
**Purpose**: Manages asynchronous processing of deposits and redemptions

**Why Queues?**:
- NAV is updated periodically (not real-time)
- Deposits/redemptions must use correct NAV for fairness
- Batch processing saves gas
- Slippage protection for users

**Flow**:
```
User Deposit:
1. transferFrom(user) → vault holds tokens
2. Queue deposit with current NAV and minShares
3. [Wait for next processing window]
4. Process queue: calculate shares at NAV, mint to user
5. Transfer tokens to Safe for deployment

User Redemption:
1. Burn user's shares
2. Queue redemption with current NAV and minPayout
3. [Wait for next processing window]
4. Process queue: calculate payout, execute Safe transfer
```

**Safety Features**:
- Max 5 pending requests per user (prevents DOS)
- Max 1000 items in queue (prevents unbounded loops)
- Slippage protection (minShares/minPayout)
- Users can cancel their own queued requests
- Admin can cancel specific requests

**Why It's Important**:
Fair pricing for all participants, prevents front-running, enables batch processing for efficiency.

---

### 4. EmergencyManager.sol - Disaster Recovery
**Purpose**: Handles crisis situations when normal operation fails

**Trigger Conditions**:
1. **Manual**: Guardian triggers after pausing contract
2. **Automatic**: Contract paused for 30+ days OR AUM not updated for 30+ days

**Emergency Withdrawal**:
- Users can withdraw pro-rata share of available on-chain liquidity
- Based on snapshot of AUM at emergency trigger time
- Tracks total withdrawn to prevent over-withdrawal
- If liquidity < total claims: proportional distribution

**Example**:
- Fund has $1M AUM, $100K on-chain, 1000 shares
- User has 10 shares (1% of fund)
- Entitled to $10K (1% of $1M)
- But only $1K available (1% of $100K on-chain)
- User receives $1K

**Why It's Important**:
Last resort protection if fund manager disappears, Safe keys lost, or fraud detected.

---

### 5. SafeHedgeFundVault.sol - Main Contract
**Purpose**: Orchestrates all components, manages user interactions

**Key Responsibilities**:
- ERC20 share token issuance
- Deposit/redemption entry points
- AUM update acceptance (from keeper)
- Queue processing
- Emergency mode handling
- Access control (RBAC)

**Roles**:
- `DEFAULT_ADMIN_ROLE`: Full control, can grant other roles
- `ADMIN_ROLE`: Config proposals, fee payouts, emergency controls
- `AUM_UPDATER_ROLE`: Report off-chain AUM (keeper/oracle)
- `PROCESSOR_ROLE`: Process deposit/redemption queues (keeper)
- `GUARDIAN_ROLE`: Emergency controls, can trigger emergency mode

---

### 6. Contract Size Optimization
**Previous Architecture**: Used 8 separate library contracts (4 core + 4 helpers)

**Optimization Applied**:
- **Inlined Small Libraries**: ViewHelper, AdminHelper, ProcessingHelper, and AUMManager functions are now inlined directly into SafeHedgeFundVault.sol
- **Kept Core Libraries**: ConfigManager, FeeManager, QueueManager, and EmergencyManager remain as separate libraries due to their complexity
- **New Structure**: Core libraries moved to `contracts/core/` folder for better organization

**Why This Matters**:
- Small libraries (< 120 lines) add deployment overhead that exceeds their benefits
- Each separate library requires a deployment address stored in the main contract
- DELEGATECALL operations to tiny libraries add unnecessary bytecode
- Inlining small functions significantly reduces total contract size
- Core libraries (300-600 lines) still benefit from separation

**Result**: Main contract size reduced by eliminating 4 library deployment addresses and their associated overhead, helping address the 24KB deployment limit.

---

## Key Workflows

### Deposit Flow (Normal Operation)
```
1. User calls deposit(amount, minShares)
   ↓
2. Vault receives tokens via transferFrom
   ↓
3. QueueManager.queueDeposit() creates queue item
   ↓
4. [Time passes - keeper monitors]
   ↓
5. Keeper calls processDepositQueue(count)
   ↓
6. For each queued deposit:
   - Calculate shares = (amount * decimalFactor * 1e18) / navPerShare
   - Check shares >= minShares (slippage protection)
   - Mint shares to user
   - Transfer tokens to Safe for deployment
   ↓
7. User receives shares, can trade or redeem later
```

### Redemption Flow (Normal Operation)
```
1. User calls redeem(shares, minPayout)
   ↓
2. Vault burns user's shares immediately
   ↓
3. Calculate payout = (shares * NAV / 1e18) - exitFee
   ↓
4. Check payout >= minPayout (slippage protection)
   ↓
5. If autoPayoutRedemptions enabled:
   - Try immediate payout from Safe
   - If successful: done
   - If fails: queue for later
   ↓
6. Else: QueueManager.queueRedemption()
   ↓
7. [Time passes - keeper monitors]
   ↓
8. Keeper calls processRedemptionQueue(count)
   ↓
9. Safe executes transfer to user via module call
```

### AUM Update Flow
```
1. Off-chain keeper calculates total AUM:
   - Vault balance
   - Safe balance
   - CEX positions
   - Other off-chain assets
   ↓
2. Keeper calls updateAum(newAum) [requires AUM_UPDATER_ROLE]
   ↓
3. FeeManager.accrueFeesOnAumUpdate():
   - Validate newAum >= on-chain liquidity (fraud prevention)
   - Accrue management fees (time-based)
   - Accrue performance fees (if above HWM)
   - Deduct all accrued fees from AUM
   - Calculate new NAV per share
   - Update high water mark
   ↓
4. New NAV used for next deposits/redemptions
```

### Fee Payout Flow
```
1. Admin calls payoutAccruedFees()
   ↓
2. FeeManager checks:
   - Total fees > 0
   - Target liquidity met (e.g., 5% of AUM on-chain)
   ↓
3. Calculate amount to pay (min of accrued vs available)
   ↓
4. Try vault balance first
   ↓
5. If insufficient, try Safe wallet via module call
   ↓
6. Reset accrued fees proportionally
   ↓
7. Transfer to feeRecipient
```

### Emergency Withdrawal Flow
```
1. Emergency triggered (manual or automatic after 30 days)
   ↓
2. EmergencyManager captures:
   - Snapshot of current AUM
   - Total supply of shares
   ↓
3. User calls emergencyWithdraw(shares)
   ↓
4. Calculate:
   - entitlement = (shares / totalSupply) * snapshotAUM
   - available = current on-chain liquidity
   - remainingClaims = snapshot - totalWithdrawn
   - payout = min(entitlement, entitlement * available / remainingClaims)
   ↓
5. Burn user's shares
   ↓
6. Transfer payout to user
   ↓
7. Track totalWithdrawn to prevent over-distribution
```

## Security Features

### 1. Reentrancy Protection
- All external functions use `nonReentrant` modifier
- State changes before external calls
- Uses OpenZeppelin's ReentrancyGuard

### 2. Access Control
- Role-based access (OpenZeppelin AccessControl)
- Separate roles for different operations
- DEFAULT_ADMIN can grant/revoke roles

### 3. Decimal Normalization
- All internal calculations use 18 decimals
- Prevents precision loss with different token decimals
- Conversion: `amount * 10^(18-baseDecimals)`

### 4. AUM Validation
- New AUM must be >= on-chain liquidity
- Prevents keeper from reporting fraudulent low AUM
- Max 3-day staleness enforced

### 5. Queue Limits
- Max 1000 items in queue (DOS prevention)
- Max 5 pending requests per user (DOS prevention)
- Slippage protection on all queue items

### 6. Fee Limits
- Hardcoded maximum fees in ConfigManager
- Management: max 5% annual
- Performance: max 30%
- Entrance/Exit: max 5%

### 7. Emergency Safeguards
- 30-day threshold before automatic trigger
- Pro-rata distribution of available liquidity
- Tracks withdrawals to prevent double-claims

### 8. Pause Functionality
- Admin can pause deposits/redemptions
- Emergency withdrawals still work when paused
- Protects fund during crisis

## Gas Optimization

### Optimized Library Pattern
- **Core Libraries**: ConfigManager, FeeManager, QueueManager, EmergencyManager use external library pattern (located in `contracts/core/`)
- **Inlined Helpers**: Small utility functions inlined directly to eliminate library deployment overhead
- **Size Reduction**: Eliminated 4 library deployments, each of which added ~4KB+ overhead
- **Storage Efficiency**: Functions delegatecalled, use main contract storage

### Batch Processing
- Process multiple deposits/redemptions in one transaction
- Configurable batch size (max 200)
- Amortizes gas costs across multiple users

### Storage Cleanup
- Queues automatically clean processed items
- Proposals deleted after execution
- Reduces storage costs over time

### Contract Size Management
- Main contract previously exceeded 24KB limit (38,266 bytes)
- Structural reorganization targets significant size reduction
- Small libraries (< 120 lines) inlined to eliminate deployment overhead
- Large libraries (> 300 lines) kept separate to maintain modularity

## Economic Model

### Share Pricing
```
NAV per Share = (Total AUM - Accrued Fees) / Total Share Supply

Initial NAV = 1.0 (in base token terms)

Example with USDC (6 decimals):
- Deposit $100
- NAV = $1.00
- Shares received = 100 / 1.00 = 100 shares

After fund grows to $150 AUM with 100 shares:
- NAV = $150 / 100 = $1.50 per share
- New deposit $100 receives 100 / 1.50 = 66.67 shares
```

### Fee Impact on NAV
```
Total Fees = mgmtFees + perfFees + entranceFees + exitFees

Adjusted AUM = Reported AUM - Total Fees

NAV = Adjusted AUM / Total Supply

This ensures fees reduce AUM and dilute existing shareholders,
effectively collecting fees without actual transfers until payout.
```

### High Water Mark Example
```
Starting point:
- NAV = $1.00, HWM = $1.00

Year 1: NAV grows to $1.50
- Performance fee on $0.50 gain (NAV $1.00 → $1.50)
- HWM raised to $1.50

Year 2: NAV drops to $1.20
- No performance fee (below HWM)
- HWM stays at $1.50

Year 3: NAV recovers to $1.70
- Performance fee only on $0.20 gain (HWM $1.50 → $1.70)
- HWM raised to $1.70

This ensures manager doesn't get paid twice for same performance.
```

## Integration Points

### Gnosis Safe Integration
- Vault contract enabled as Safe module
- Allows vault to call `execTransactionFromModule()`
- Used for:
  - Transferring deposits to Safe for deployment
  - Paying redemptions from Safe
  - Paying fees from Safe

### Keeper/Oracle Integration
- Off-chain service monitors fund positions
- Calculates total AUM across all venues
- Calls `updateAum()` periodically (e.g., daily)
- Processes queues via `processDepositQueue()` and `processRedemptionQueue()`

### Frontend Integration
- Read NAV via `navPerShare()`
- Estimate deposits via `estimateShares(amount)`
- Estimate redemptions via `estimatePayout(shares)`
- Check queue status via `queueLengths()`
- Monitor pending requests via `getUserDepositIndices()` and `getUserRedemptionIndices()`

## Upgrade Path

**Note**: This contract is NOT upgradeable. Immutability provides security guarantees.

**To "upgrade"**:
1. Deploy new version of vault
2. Pause old vault
3. Trigger emergency mode on old vault
4. Users withdraw from old vault
5. Users deposit to new vault
6. Fund manager migrates positions

**Why Non-Upgradeable?**:
- Prevents admin from adding backdoors
- Users know exact code they're interacting with
- Security through immutability
- Aligns with DeFi principles

## Testing Recommendations

### Unit Tests
- Test each library function in isolation
- Edge cases: zero amounts, zero supply, max values
- Fee calculations with various time deltas
- HWM logic through multiple scenarios
- Queue processing with various batch sizes

### Integration Tests
- Full deposit → AUM update → redemption flow
- Emergency mode activation and withdrawals
- Config proposal lifecycle (propose → execute)
- Fee accrual and payout with liquidity checks
- Safe module integration (mock Safe contract)

### Scenario Tests
- Bull market: continuous AUM growth
- Bear market: drawdown and HWM reset
- Flash crash: emergency mode activation
- Keeper failure: stale AUM and auto-emergency
- High demand: queue management under load

## Known Limitations

1. **Centralization of AUM Reporting**:
   - Keeper controls AUM updates
   - Could report incorrect values (within on-chain liquidity constraint)
   - Mitigation: Multi-sig on keeper keys, monitoring, emergency mode

2. **Liquidity Constraints**:
   - Redemptions depend on on-chain liquidity
   - If most capital deployed off-chain, redemptions may queue
   - Mitigation: Target liquidity requirement, manager responsibility

3. **Safe Dependency**:
   - Relies on Gnosis Safe functioning correctly
   - Safe keys must be accessible
   - Mitigation: Emergency mode doesn't require Safe access

4. **Gas Costs**:
   - Queue processing can be expensive with large queues
   - Batch limits help but don't eliminate issue
   - Mitigation: Configurable batch size, keeper optimization

5. **No Direct Withdrawals**:
   - Normal redemptions burn shares before payout
   - User loses shares even if payout fails
   - Mitigation: Slippage protection, payout verification

## Lending: SharedPool

A separate `contracts/lending/SharedPool.sol` provides an AMM-based swap facility AND a lending market against HFS collateral, all backed by a single USDC reserve. Same dollars do double duty.

**Core property**: `hfsReserve` is a derived equation (`usdcReserve / NAV`), never stored. xy=k swaps still apply slippage, and the slippage value is captured for existing HFS holders via callback functions on the vault that update `fs.aum` atomically with each swap. NAV stays correct between daily keeper updates.

**Liquidations** are bundled into `updateAum`. NAV is a step function that only changes when the keeper reports, so the only moment a position can become unhealthy is during an AUM update — we sweep at exactly that moment, no separate keeper or external bots needed.

**Configuration** (swap fee, LLTV, borrow rate) goes through the existing `ConfigManager` timelock + cooldown machinery.

See **`docs/LENDING.md`** for the full design, math, callback flow, and operational notes for the keeper.

## Future Enhancements (Not Implemented)

- Multi-asset support (currently single base token)
- Automated AUM reporting via oracles
- Partial redemptions (currently all-or-nothing per queue item)
- Priority queue (currently FIFO)
- Dynamic fee rates based on performance
- Lock-up periods for new deposits
- Whitelist/blacklist for compliance

---

## File Structure

```
contracts/
├── SafeHedgeFundVault.sol          # Main contract with inlined helper functions
├── core/                            # Core library contracts (complex, kept separate)
│   ├── ConfigManager.sol            # Timelock-based configuration management
│   ├── FeeManager.sol               # Fee calculations and HWM logic
│   ├── QueueManager.sol             # Deposit/redemption queue management
│   └── EmergencyManager.sol         # Emergency withdrawal functionality
└── lending/
    └── SharedPool.sol               # Unified AMM + lending market (see docs/LENDING.md)
```

**Organization Rationale**:
- **Main Contract**: Contains all business logic and inlined helper functions
- **Core Folder**: Houses complex, reusable library contracts (>300 lines each)
- **Inlined Functions**: ViewHelper, AdminHelper, ProcessingHelper, and AUMManager functions are integrated directly into the main contract for size optimization

---

**Last Updated**: 2025-11-20
**Version**: 1.1.0 (Structural Optimization)
