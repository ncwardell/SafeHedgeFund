# Lending — SharedPool Design

A unified AMM + lending market that lets HFS holders borrow USDC against their position **without selling**, using the fund's own USDC reserves as the lending capital. Same dollars provide both swap depth and lending capacity (capital efficiency by construction).

This document explains the design, the AUM/NAV mechanics, and why the contract is shaped the way it is.

---

## Goals

1. **Borrow without selling.** HFS holders can use their HFS as collateral to draw USDC. The HFS stays as collateral (no IL — they keep full upside on their fund position).
2. **Permissionless and automatic.** No admin approval per loan. Anyone with HFS can borrow up to LLTV.
3. **No idle capital.** USDC sitting in the pool serves both as swap depth (for HFS↔USDC trades) and as lending supply (for borrowers to draw).
4. **No external infrastructure.** No Morpho, no Fluid, no MEV bots. The fund's own keeper (already needed for daily AUM updates) handles everything via the existing `updateAum` flow.

## Architecture in one diagram

```
         user actions:                     keeper actions:
         ─────────────                     ───────────────
         deposit/redeem (vault.*)          updateAum (daily)
         swap            (pool.swap*)             │
         borrow/repay    (pool.*)                 │
              │                                   │
              ▼                                   ▼
   ┌─────────────────────────────────┐    ┌──────────────────┐
   │       SharedPool                │    │ SafeHedgeFundVault│
   │                                 │    │                   │
   │  usdcReserve  ──┬─ AMM swaps    │◄───┤  navPerShare()   │
   │                 ├─ borrow draws │    │  (NAV oracle)     │
   │                 └─ repays back  │    │                   │
   │                                 │    │  fs.aum (storage) │
   │  collateralOf[u]                │    │   ▲               │
   │  borrowOf[u]                    │    │   │ pool callbacks│
   │  activeBorrowers                │    │   │ on swap/liq:  │
   │                                 │    │   │  addToAum     │
   │  hfsReserve() ── derived view   │────┤   │  subFromAum   │
   │     = usdcReserve / NAV         │    │   │               │
   └─────────────────────────────────┘    └──────────────────┘
                 ▲                                  │
                 │            sweepLiquidations()   │
                 └──────────────────────────────────┘
                            (called at every updateAum)
```

## The two key insights

### 1. `hfsReserve` is a derived equation, not stored state

We never store the AMM's HFS-side reserves. They're computed on every read:

```solidity
function hfsReserve() public view returns (uint256) {
    return usdcReserve * (10 ** (18 - baseDec)) * 1e18 / vault.navPerShare();
}
```

This means:
- xy=k applies during a swap (slippage works correctly)
- Between swaps, the equation re-derives `hfsReserve` against current NAV — no manual rebalance needed
- Pool's actual HFS balance is always 0 (no real HFS sits in the pool)
- `effectiveSupply` accounting is trivial: `totalSupply - balanceOf(safe)` (no pool subtraction needed because pool holds no HFS)

### 2. `addToAum` / `subFromAum` callbacks keep NAV correct between updates

NAV = AUM / supply. AMM swaps mint or burn HFS, changing supply *immediately*. If `fs.aum` only updated daily (when keeper reports), there'd be a window between every swap and the next keeper update where NAV would be incorrect, exploitable by anyone who deposits/redeems through the vault during the gap.

Fix: when the pool moves USDC (which is also the moment supply changes), it calls back into the vault to update `fs.aum`:

```solidity
// On USDC→HFS swap (fund USDC up, supply up)
usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
usdcReserve += usdcIn;
vault.addToAum(usdcIn);                  // ← keep fs.aum in sync
vault.mintForPool(msg.sender, hfsOut);   // ← supply ↑

// On HFS→USDC swap (fund USDC down, supply down)
vault.burnFromUser(msg.sender, hfsIn);   // ← supply ↓
vault.subFromAum(usdcOut);               // ← fs.aum ↓
usdcReserve -= usdcOut;
usdc.safeTransfer(msg.sender, usdcOut);
```

Now NAV stays correct continuously, even between daily keeper updates. No exploit window.

### Why this is enough

The keeper still reports daily. Their job is to compute total fund AUM (Safe USDC + pool USDC + off-chain assets like Aave positions, RWAs, etc.) and call `updateAum`. Between updates, only events that change supply *and* fund USDC need fs.aum patches:

| Event | Changes supply? | Changes fund USDC? | Needs fs.aum patch? |
|---|---|---|---|
| AMM swap (USDC→HFS) | ✓ +hfsOut | ✓ +usdcIn | YES — `addToAum(usdcIn)` |
| AMM swap (HFS→USDC) | ✓ −hfsIn | ✓ −usdcOut | YES — `subFromAum(usdcOut)` |
| Borrow USDC | no | USDC out, but loan claim of equal value in | NO (net-zero asset) |
| Repay USDC | no | USDC in, loan claim out | NO (net-zero asset) |
| Liquidation | ✓ −col (burn) | no USDC moved | YES — `subFromAum(debt)` for the written-off loan |
| Manager moves USDC Safe→Aave | no | bucket shift, total unchanged | NO (keeper handles at next daily update) |
| Vault deposit | ✓ +shares | ✓ +amount | (covered by keeper's daily update; small staleness window — see Limitations) |

This is the elegant part: the only events that can corrupt NAV between updates are exactly the ones the pool handles directly. Everything else is either net-zero (borrow/repay) or covered by the keeper's normal flow.

## Liquidation flow

Triggered automatically at the tail of every `updateAum`. NAV is a step function — it only changes when the keeper reports — so the only moment a position can become unhealthy is during an AUM update. We sweep at exactly that moment.

```solidity
// In vault.updateAum:
emit AumUpdated(adjustedAum, newNav);
lastAumBlock = block.number;
if (sharedPool != address(0)) {
    ISharedPool(sharedPool).sweepLiquidations();
}
```

```solidity
// In pool.sweepLiquidations (vault-only):
for each active borrower:
    if unhealthy at new NAV:
        burn collateral (vault.burnFromUser(this, col))
        subFromAum(debt)  // write off the loan asset
        clear borrowOf[u], collateralOf[u]
        remove from activeBorrowers
```

At the LLTV threshold (default 50%), the seized collateral is worth 2× the debt. The fund:
- Loses `debt` of loan asset (USDC was loaned out, never coming back)
- Reduces supply by `col` HFS (worth `col × NAV = 2 × debt`)
- Net: NAV ↑ for remaining holders by approximately `debt`

In a bad-debt scenario (collateral has crashed below debt), the gap is absorbed by the pool's USDC reserves (= fund's value, = all HFS holders proportionally).

## Block-level swap freeze

The `notFrozen` modifier blocks swaps in the same block as `updateAum`:

```solidity
modifier notFrozen() {
    if (block.number == vault.lastAumBlock()) revert SwapFrozenThisBlock();
    _;
}
```

This defangs a specific MEV attack: front-running `updateAum` with a swap to capture the NAV delta. With the freeze, an attacker who sees `updateAum` in the mempool can't sandwich it with swaps in the same block.

The freeze lasts one block. Normal users wait one block for legitimate swaps. AUM updates are rare (daily), so the cost is negligible.

## Configuration

All lending parameters live on `ConfigManager` (the same timelocked governance system as the existing fee parameters):

| Key | Bounds | Default | Description |
|---|---|---|---|
| `swapFeeBps` | ≤ 100 (1%) | 30 (0.30%) | Fee charged on each swap, retained in pool |
| `lltvBps` | 1000–9000 | 5000 (50%) | Max borrow as fraction of collateral value |
| `borrowRateBps` | ≤ 5000 | 800 (8% APR) | Fixed borrow rate |

Changes go through 3-day timelock + 5-day cooldown. Same machinery as the existing config keys.

## Permissions

| Function | Caller |
|---|---|
| `supply` / `swap` / `depositCollateral` / `withdrawCollateral` / `borrow` / `repay` | Anyone |
| `sweepLiquidations` | Vault only (called from `updateAum`) |
| `vault.mintForPool` / `burnFromUser` / `addToAum` / `subFromAum` | Pool only |
| `vault.setSharedPool` | `ADMIN_ROLE` (one-time wiring) |

## Limitations and known gaps

These are explicit design choices for v1. Each gets a v2 entry if needed.

1. **Fund-only USDC supply in practice.** Anyone can call `supply()` but there are no LP shares yet, so external suppliers are effectively donating to the fund. That's fine for F&F (the fund itself is the only realistic supplier). LP shares with proportional withdrawals are a v2 concern.

2. **Vault deposit/redeem still has the daily-staleness window.** Between a deposit/redeem and the next keeper update, NAV uses stale `fs.aum`. This is the same staleness that existed pre-pool. Fixing it would mean adding `addToAum` / `subFromAum` callbacks to the vault's own deposit/redeem flow. Worth doing in v2 for completeness, but not urgent — the staleness only matters if there's a meaningful AUM swing between updates, which is rare for a fund that updates daily.

3. **Fixed-rate borrow.** No utilization curve, no rate adjustments based on demand. Simple to reason about, fine at small scale. Variable-rate IRM is a v2 concern.

4. **No flash-loan protection.** Same-block deposit + swap + redeem could in theory extract value if there's any inconsistency. The block-level swap freeze blocks the swap leg in the `updateAum` block; broader flash-loan resistance would require more analysis.

5. **Liquidation has no third-party incentive.** Auto-sweep is the only mechanism. If the keeper goes down, positions can rot until the keeper resumes. For F&F scale, an SLA on the keeper is sufficient. At scale, an external `liquidate(borrower)` function with a bonus would help.

6. **Pool's actual HFS balance always = 0.** This is by design (virtual `hfsReserve`). It means borrower collateral is the *only* HFS that the pool actually holds. This is fine but worth noting for accounting consistency checks.

## Test coverage

`test/SharedPool.t.sol` — 17 tests covering:

- `hfsReserve` is derived correctly from `usdcReserve` and NAV
- `hfsReserve` auto-tracks after swap (no rebalance state)
- xy=k slippage applies in both directions
- **NAV captures slippage value immediately** (the core property of the addToAum design)
- **No stale-NAV exploit** between swap and keeper update
- Borrow / repay are NAV-neutral (no callbacks needed for net-zero events)
- Liquidation correctly subtracts debt from `fs.aum` via `subFromAum`
- Sweep on `updateAum` clears unhealthy positions
- LLTV enforcement on borrow
- Withdraw-collateral revert on health violation
- Block-level swap freeze
- Access control on pool-only and vault-only callbacks

## Operational notes for the keeper

The keeper runs daily and reports total fund AUM. Steps:

1. Compute total fund USDC: `safe USDC + pool USDC` (both on-chain, easy to query)
2. Compute off-chain: Aave positions (current value), CEX balances, RWAs, etc.
3. Compute outstanding loan claims: `pool.totalBorrowed()` (already counted in pool USDC at borrow time? No — when USDC leaves pool for a borrower, that USDC is no longer in pool.usdcReserve, but the loan is owed back. Keeper must include outstanding loans in their report.)
4. Sum: total = `pool.usdcReserve() + pool.totalBorrowed() + safe.balanceOf(USDC) + offchain`
5. Call `vault.updateAum(total)`

`updateAum` will trigger the liquidation sweep automatically. If any positions go unhealthy at the new NAV, they're cleared in the same transaction. The keeper sees one event per liquidation in the transaction logs.
