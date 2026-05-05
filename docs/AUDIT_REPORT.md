# SafeHedgeFund Audit Report

**Branch:** `claude/fix-critical-bugs`
**Reviewer:** Claude (Opus 4.7)
**Scope:** `contracts/SafeHedgeFundVault.sol` + `contracts/core/{ConfigManager,FeeManager,QueueManager,EmergencyManager}.sol`
**Out of scope:** `ICP/` (per request), `portal/` reviewed only for ABI surface match.

---

## 0. State of the code

This audit replaces the prior `AUDIT_REPORT.md`, which was outdated after several refactors (library inlining, the `_burn` recursion fix, decimal-handling rework). The findings below were verified against the working tree.

**Already fixed on this branch:**
- Batch deposit head-pointer drift (`processDepositBatch` → `_mintAndDeploy` callback)
- OpenZeppelin v4 → v5 import paths
- `navPerShare()` mixed-unit subtraction (was off by `DECIMAL_FACTOR` for non-18-dec tokens)
- Portal ABI mismatches against on-chain contract surface

A `forge test` harness with a `MockSafe` is in place; both regression tests pass.

---

## 1. Design choices (NOT findings)

These are explicit policy decisions, not bugs. Calling them out so they don't show up in future re-reviews.

| Decision | Where | Rationale |
|---|---|---|
| **AUM updater is trusted** — only validated against on-chain lower bound (`newAum >= onChainLiquidity`); no upper bound, no rate of change check | `FeeManager.sol:139-140` | Hedge fund needs to deploy off-chain; a tight upper bound either rejects legitimate growth or requires periodic reseeding. Mitigated by: multi-sig keeper key, monitoring, emergency mode |
| **Mgmt fees skipped if AUM update gap > 3 days** | `FeeManager.sol:197` | Avoids huge fee spikes after extended downtime; manager forfeits fees as the cost of an outage |
| **Single base token only** | constructor | Multi-asset accounting is its own project; off-chain venues handle the conversion |
| **HWM reset mechanic** (drawdown threshold + recovery window) | `FeeManager.sol:507-541` | Allows recovery from drawdowns without "double-paying" performance fees on the same gain band |
| **Non-upgradeable** | architectural | Users see the exact code they trust; "upgrade" = deploy v2, emergency-out of v1 |
| **30-day automatic emergency thresholds** | `EmergencyManager.sol:43` | Long enough to avoid false trips during holidays/long outages, short enough to protect users |
| **5 pending requests/user, 1000 queue cap** | `QueueManager.sol:6-7` | DOS prevention |

If any of these change later, the corresponding code needs a different review lens.

---

## 2. Architecture flow — does it hang together?

### 2.1 Deposit flow (queued path)

```
user                            vault                              Safe
─────                           ────────                           ──────
deposit(amount, minShares) ──►  validate, transferFrom user
                                queueDeposit (item: amount, navAtCall, minShares)
                                                       (vault holds tokens, no shares minted yet)
... time passes; AUM updates; processor schedules ...

processor                        vault                              Safe
─────────                        ────────                           ──────
processDepositQueue(N) ────────► for each item:
                                 ─ accrueEntranceFee (mutates accruedEntranceFees)
                                 ─ shares = (netAmount * 1e18) / nav
                                 ─ if shares < minShares → skip, log
                                 ─ mark item.processed
                                 ─ _mintAndDeploy:
                                       _mint(user, shares)
                                       safeTransfer(safe, netAmountNative) ────►  receives funds
                                       emit Deposited
                                 _cleanDepositQueue (advance head)
```

Logically coherent post-fix. Two issues remain (B-CRIT-2, B-MED-5).

### 2.2 Deposit flow (auto-process path)

`autoProcessDeposits=true` makes `deposit()` itself call `_tryAutoProcessDeposit` on the just-queued item. Same logic, single item. **One soft failure mode (B-HIGH-5).**

### 2.3 Redemption flow (queued path)

```
user                             vault                               Safe
─────                            ────────                            ──────
redeem(shares, minOut) ────────► validate balance
                                 nav = navPerShare()
                                 gross = shares * nav / 1e18
                                 net = accrueExitFee(gross)        ◄── EXIT FEE ACCRUED [#1]
                                 minRedemption / minOut checks
                                 _burn(user, shares)               ◄── SHARES GONE
                                 (autoPayout false or fails)
                                 queueRedemption (user, shares, nav, minOut)

... time passes ...

processor                        vault                               Safe
─────────                        ────────                            ──────
processRedemptionQueue(N) ─────► for each item:
                                 _payout(user, shares, nav):
                                   accrueExitFee(gross) AGAIN        ◄── EXIT FEE ACCRUED [#2]
                                   call execTransactionFromModule ──► transfer to user
                                   verify user balance grew
                                   (no-op fee transfer back, see B-HIGH-4)
                                 if !ok → keep in queue, retry later
                                                                      (each retry: ANOTHER accrue)
```

**This flow has the most serious bug in the codebase (B-CRIT-1 below).** Exit fee gets accrued multiple times per redeem.

### 2.4 AUM update flow

```
keeper ──updateAum(newAum)──► validate newAum > 0
                              validate newAum >= onChainLiquidity
                              accrueFees:
                                ── mgmt fee (time-weighted, capped at 3 days delta)
                                ── perf fee (if tempNav > HWM)
                              adjustedAum = newAum − denormalize(totalAccruedFees)
                              fs.aum = adjustedAum
                              fs.aumTimestamp = now
                              fs.navPerShare = (normalize(adjustedAum) * 1e18) / totalSupply
                              update HWM (new high / drawdown / recovery)
```

Logic is correct. Two design choices that read like bugs but are not (Section 1). One subtle correctness issue (B-MED-1 perf-fee NAV timing).

### 2.5 Emergency flow

Two trigger paths (manual via `triggerEmergency`, automatic via `checkEmergencyThreshold` after 30 days). Both snapshot AUM at trigger time. `emergencyWithdraw` then computes pro-rata against the snapshot.

**Two real bugs here (B-HIGH-1, B-HIGH-3).**

---

## 3. Burn / mint deep-dive

(You asked specifically about this.)

### 3.1 Mint sites

| # | Path | Function | When |
|---|---|---|---|
| M1 | Auto-process deposit | `_tryAutoProcessDeposit` → `_mint` (`SafeHedgeFundVault.sol:475`) | Inside the user's `deposit()` tx |
| M2 | Batch process deposit | `_mintAndDeploy` → `_mint` (`SafeHedgeFundVault.sol:498`) | Inside processor's `processDepositQueue()` tx |
| M3 | Cancel redemption | `_mintBack` → `_mint` (`SafeHedgeFundVault.sol:549`) | Re-mint to undo burn from `redeem()` |

### 3.2 Burn sites

| # | Path | Function | When |
|---|---|---|---|
| B1 | Normal redeem | `_burn` (`SafeHedgeFundVault.sol:204`) | **Immediately** in `redeem()`, before queueing or payout |
| B2 | Emergency withdraw | `_burnShares` → `_burn` (`SafeHedgeFundVault.sol:553`) | Inside `EmergencyManager.emergencyWithdraw` callback |

### 3.3 Burn-before-payout: is it dangerous?

`redeem()` burns shares before either auto-payout or queueing. Walk every fail mode:

| Step that fails | Outcome | Verdict |
|---|---|---|
| `transferFrom` (n/a — no transfer) | — | — |
| `accrueExitFee` (line 196) | Cannot fail (no external calls, no division/zero risk for sane bps) | Safe |
| `_burn` (line 204) | OZ ERC20 reverts on insufficient balance — but we checked `balanceOf >= shares` at line 192 | Safe |
| Auto-payout (`_payout` at line 207) | Returns `(false, 0)` — does NOT revert. Logged, falls through to `queueRedemption` | Safe (shares already burned, but user is now in queue) |
| `queueRedemption` (line 216) reverts (queue full / user limit) | **Whole tx reverts** → `_burn` undone too | Safe |

**Conclusion:** Burn-before-payout is *safe* in the sense that a user can never lose shares without either getting paid or being queued. The only fragility is that `queueRedemption` *must* always revert on failure (it currently does). Adding a non-reverting failure path there would break the invariant. **Recommend:** add a comment at line 204 documenting this invariant so future edits don't accidentally violate it.

### 3.4 The mint failure mode that does lose money

Auto-process path, `SafeHedgeFundVault.sol:462-470`:

```solidity
if (ok) {
    if (shares == 0) {
        emit DepositAutoProcessFailed(...);
        return;       // <── early return, but processSingleDeposit ALREADY:
                      //     • marked item.processed = true
                      //     • decremented pendingDeposits[user]
                      //     • accrued entrance fee
                      //     User's tokens are in the vault, the queue item is
                      //     burned, no shares were minted, no refund happens.
    }
    address user = ...
    _mint(user, shares);
    baseToken.safeTransfer(safeWallet, netNative);
    emit Deposited(user, amount, shares);
}
```

`processSingleDeposit` returns `ok=true` only after slippage passes; that check is `sharesMinted < item.minOutput`. If `minOutput == 0` (user trusted the auto-process), shares could legitimately compute to zero (e.g., NAV inflated faster than deposit value) and the `ok=true` path falls into this trap. **B-HIGH-5.**

### 3.5 The cancel-after-fee-accrual leak

Both auto-process and batch paths call `accrueEntranceFee` *before* the slippage / zero-shares checks. If those checks fail, the function returns without marking the item processed and without decrementing `pendingDeposits` — but `accruedEntranceFees` was already incremented. The user can then `cancelMyDeposits` and walk away with their full deposit, while the fee remains accrued against no actual revenue. Across many failed retries this inflates accrued fees indefinitely. **B-CRIT-2.**

---

## 4. Findings

### B-CRIT-1 — Exit fee accrued 2× to N× per redeem
**Files:** `SafeHedgeFundVault.sol:196` and `SafeHedgeFundVault.sol:508` (inside `_payout`)
**Severity:** Critical (overcharges users, inflates manager's accrued fee balance)

`redeem()` calls `feeStorage.accrueExitFee(gross)` at line 196 to compute `net` for the slippage check. Both `_payout` (auto-payout, line 207) and the queued `processRedemptionQueue` path call `_payout`, which itself calls `accrueExitFee(gross)` at line 508. The result:

| Path | accrueExitFee calls | Multiplier |
|---|---|---|
| Auto-payout success | line 196 + line 508 | **2×** |
| Queued, processor succeeds first try | line 196 + line 508 | 2× |
| Queued, processor retries (e.g., Safe rejects N times) | line 196 + N × line 508 | **(1+N)×** |

`accrueExitFee` mutates `fs.accruedExitFees`, so each call adds another fee tranche to the accrual ledger. Eventually `payoutAccruedFees` will pay out a multiple of the legitimate fee.

**Fix:** make line 196 a *preview* (compute fee without mutation) for the slippage check, and only mutate inside `_payout` once the actual transfer succeeds. Add a `previewExitFee(gross)` view alongside the existing `accrueExitFee`.

---

### B-CRIT-2 — Entrance-fee accrual leaks on failed processings
**Files:** `QueueManager.sol:117` and `QueueManager.sol:169`
**Severity:** Critical (accrued-fee ledger diverges from realized revenue; user can cancel and exit cleanly while leaving phantom accrued fees behind)

Both `processSingleDeposit` and `_processDepositItem` call `accrueEntranceFee(item.amount)` *before* the slippage / zero-shares checks. If those checks fail, the item is *not* marked processed (it'll be retried next pass), but the entrance fee was already added to `accruedEntranceFees`. Each retry adds another tranche.

If the user then cancels (`cancelMyDeposits`), `_transferBack` returns the full original `item.amount` — so the user paid no net fee, but the manager's accrued-fee balance keeps the phantom amount.

**Fix:** preview the fee + shares purely, gate them behind the slippage / zero-shares check, and only call the mutating `accrueEntranceFee` after the checks pass.

---

### B-HIGH-1 — Emergency snapshot accounts entitlement, not payout
**File:** `EmergencyManager.sol:212`
**Severity:** High (breaks pro-rata fairness during underfunded emergencies)

```solidity
uint256 entitlement = (shares * es.emergencySnapshot) / totalSupply;
...
uint256 payoutAmount = available >= remainingClaims
    ? entitlement
    : (entitlement * available) / remainingClaims;

burn(msg.sender, shares);
es.emergencyTotalWithdrawn += entitlement;   // ← should be payoutAmount
```

When liquidity is short, a user receives `payoutAmount` but the snapshot ledger increments by the (larger) `entitlement`. `remainingClaims` then under-counts the available pool for late withdrawers, who systematically receive less than their fair share — or zero — even when funds are still available.

**Fix:** `es.emergencyTotalWithdrawn += payoutAmount;`

---

### B-HIGH-2 — Cancellation gas bomb (per-user index mappings unused)
**Files:** `QueueManager.sol:229-273` (`cancelDeposits`, `cancelRedemptions`)
**Severity:** High (DOS for a user with deposits scattered across a long queue)

`QueueStorage` already maintains `userDepositIndices[user]` and `userRedemptionIndices[user]` (populated on every queue), but the cancellation paths still loop the entire queue from `head` to `tail` looking for the user's items. With a 1000-item queue this can hit block gas limits — and the user can't cancel their own queued deposit.

**Fix:** iterate `userDepositIndices[user]` directly instead of scanning the whole queue. Mind the case where indices may already be processed (`item.processed`).

---

### B-HIGH-3 — Emergency withdrawal still depends on Safe access
**File:** `SafeHedgeFundVault.sol:540-542` → `EmergencyManager.executePayout`
**Severity:** High (contradicts the architectural promise that emergency mode protects users when Safe is gone)

`emergencyWithdraw` calls `_emergencyPayout` which calls `EmergencyManager.executePayout`. That function tries the vault's own balance first, and if insufficient, **reverts** with `ModuleNotEnabled` when the Safe module is disabled — the very scenario emergency mode is meant to protect against (compromised manager disables the module).

The architecture doc (`ARCHITECTURE.md`, Known Limitations §3) claims "Emergency mode doesn't require Safe access" — that's only true when the vault holds enough liquidity by itself, which is exactly *not* the case if the manager has deployed everything.

**Fix:** in emergency mode, pay only from `baseToken.balanceOf(address(this))`. If insufficient, pay what's available (the pro-rata math already handles partial liquidity). Skip the Safe call entirely — it's a hedge fund crisis function, not a normal-operation function.

---

### B-HIGH-4 — `_payout` fee transfer encodes wrong amount; double-counts on success
**File:** `SafeHedgeFundVault.sol:520-537`
**Severity:** High (currently dead code that always silently fails — but would drain Safe if it ever succeeded)

```solidity
if (success && feeNative > 0) {
    bytes memory feeData = abi.encodeWithSelector(IERC20.transfer.selector, address(this), feeNative);
    ...
    if (feeOk) {
        feeStorage.accruedExitFees += feeNative;  // double count: accrueExitFee already added it
    }
}
```

Two problems:
1. `feeNative` returned from `accrueExitFee` is in **18-decimal normalized** form (the function takes a normalized `gross`, the variable name is a misnomer inherited from the entrance fee path). Passing it as the amount to an ERC-20 `transfer` from the Safe means we'd attempt to move e.g. `1e19` raw USDC units (~10 trillion native USDC) for what should be 10 USDC of fee. Safe doesn't have it → call always fails → block is dead code in practice.
2. *If* it ever did succeed, the inner `accruedExitFees += feeNative` would double-count (the same fee was already added inside `accrueExitFee`).

**Fix:** delete this whole block. Exit fee revenue is already at the Safe (the user's gross payout came out of the Safe; the Safe sent only `net` to the user, kept `fee`). `payoutAccruedFees` already correctly pulls from the Safe via `_executeFeePayout`. The `_payout`-internal fee bounce is unnecessary and incorrect.

---

### B-HIGH-5 — Auto-process zero-shares strands user tokens
See §3.4 above. **File:** `SafeHedgeFundVault.sol:462-470`. Bug pattern: `processSingleDeposit` mutates state assuming the caller will mint, but the caller bails on `shares == 0`.

**Fix:** in `processSingleDeposit`, treat `shares == 0` as a slippage failure (return `false` without mutating). Mirrors the corresponding logic now in `_processDepositItem`.

---

### B-MED-1 — Performance fee uses pre-fee NAV, HWM uses post-fee NAV
**File:** `FeeManager.sol:205-210` vs `FeeManager.sol:152-157`
**Severity:** Medium (manager-favorable rounding, persistent)

```solidity
uint256 tempNav = (normalize(newAum) * 1e18) / totalSupply;       // pre-fee
if (tempNav > fs.highWaterMark && fs.performanceFeeBps > 0) {
    perfFee = ((tempNav - fs.highWaterMark) * fs.performanceFeeBps * totalSupply) / FEE_DENOMINATOR / 1e18;
    fs.accruedPerformanceFees += perfFee;
}
...
newNavPerShare = (normalize(adjustedAum) * 1e18) / totalSupply;    // post-fee
fs.navPerShare = newNavPerShare;
_updateHighWaterMark(fs, newNavPerShare);                          // updates HWM with post-fee NAV
```

Performance fee is charged against `tempNav` (pre-fee), but the HWM is then bumped only to `newNavPerShare` (post-fee). Next update can charge perf fee again on the spread between `newNavPerShare` and `tempNav`. Over time this slowly favors the manager.

**Fix:** either charge perf fee against `newNavPerShare` (iterative resolution), or update HWM to `tempNav` instead of `newNavPerShare`. Pick whichever your fee policy actually intends.

---

### B-MED-2 — `getTotalAum` ≠ `feeStorage.aum`
**File:** `SafeHedgeFundVault.sol:675-680`
**Severity:** Medium (semantic confusion; emergency math depends on which is "AUM")

`getTotalAum()` returns *current on-chain liquidity* minus accrued fees. `feeStorage.aum` is *the last reported value*. These can diverge significantly (the whole point of the fund is that capital lives off-chain). Emergency code path uses `getTotalAum()`; AUM-update path uses `feeStorage.aum`.

This is fine *if* documented as "available-now AUM" vs "official AUM," but the names don't communicate that. Plus `checkEmergencyThreshold` snapshots `getTotalAum()` rather than `feeStorage.aum`, which means emergency snapshot reflects a (likely much lower) on-chain figure, and entitlements get computed against that low number.

**Fix:** rename to `getOnChainLiquidity()` and `getReportedAum()`; explicitly choose which one feeds emergency math (probably `feeStorage.aum`).

---

### B-MED-3 — `pauseTimestamp` not cleared on `unpause`
**File:** `SafeHedgeFundVault.sol:418-425`
**Severity:** Medium (false-positive auto-emergency window)

`pause()` sets `pauseTimestamp = block.timestamp`. `unpause()` only calls OZ `_unpause()`. After unpause the stale timestamp lingers; if the contract is paused again, `pauseTimestamp` is overwritten so the live check is fine — but `checkEmergencyThreshold` reads `pauseTimestamp` regardless of paused state and could trip on stale data if conditions converge.

**Fix:** `unpause()` should also `delete emergencyStorage.pauseTimestamp`.

---

### B-MED-4 — `_getDecimals` silent fallback to 18
**File:** `SafeHedgeFundVault.sol:694-697`
**Severity:** Medium

If the base token reverts on `decimals()` (or returns nothing), the constructor silently assumes 18 decimals → `DECIMAL_FACTOR = 1`. Safer to revert; the deployer should pass a token that responds, or explicitly opt in to 18-dec via a constructor flag.

---

### B-MED-5 — Repeated batch retries continuously call `accrueEntranceFee` (per-loop)
Already covered by B-CRIT-2. Listed here again for the batch path specifically — fix once at the source.

---

### B-LOW-1 — Dead overflow check
**File:** `QueueManager.sol:66-70` and similar in redemption queue.

```solidity
if (qs.depositQueueTail == type(uint256).max) revert QueueOverflow();
qs.depositQueueTail++;
```

`==` only catches the exact-max case. Solidity 0.8 catches the actual overflow on `++` anyway, so the manual check is dead. Either delete or use `>=`.

---

### B-LOW-2 — `rescueETH` uses `.transfer`
**File:** `SafeHedgeFundVault.sol:444-451`

`payable(rescueTreasury).transfer(bal)` forwards 2300 gas. If `rescueTreasury` is a contract with non-trivial fallback (likely — it's a treasury), this fails. Use `call{value: bal}("")` with success check.

---

### B-LOW-3 — Doc rot: `AUMManager.sol`
`README.md` and `ARCHITECTURE.md` reference an `AUMManager.sol` library that no longer exists (was inlined). Update both docs to reflect the four core libs.

---

### B-LOW-4 — Dead helpers
`_emitDeposited`, `_emitTokensRescued`, `_emitETHRescued`, `_revertCannotRescueBase` (`SafeHedgeFundVault.sol:572-586`) are unused since the inlining refactor. Delete.

---

## 5. Test coverage gaps

The new `test/SafeHedgeFundVault.t.sol` has only the B1 regression test and a happy-path round trip. To regression-test the findings above you'd want:

- **B-CRIT-1:** `forge test` that does `redeem` with `exitFeeBps=100` (1%), then asserts `accruedFees().exit` equals **exactly** `1%` of the redemption — pre-fix it would be 2× or more.
- **B-CRIT-2:** queue a deposit with tight `minShares`; run `processDepositQueue` 3 times (each fails slippage); assert `accruedFees().entrance` is unchanged.
- **B-HIGH-1:** trigger emergency with snapshot $1M, $100K on-chain, two users 50% each. Both call `emergencyWithdraw`. Assert both receive $50K (not the first $50K, second $0).
- **B-HIGH-3:** disable the Safe module, trigger emergency, vault holds enough for partial payout — `emergencyWithdraw` should pay what the vault has, not revert.
- **B-HIGH-5:** auto-process a deposit where NAV inflation would compute `shares == 0`; assert tokens are refundable via cancel.
- **Decimals fuzz:** parameterized tests with token decimals ∈ {6, 8, 18}.

The `MockSafe` already supports module-toggling for the B-HIGH-3 scenario.

---

## 6. Fix ordering

1. **B-CRIT-1, B-CRIT-2** — fee-accrual leaks. Both are the same shape (mutate-before-check). One refactoring pass: introduce `previewEntranceFee` / `previewExitFee` views, use those for slippage decisions, only call the mutating versions on the success path.
2. **B-HIGH-4** — delete the broken fee-bounce in `_payout`. Pure deletion; no design tradeoff.
3. **B-HIGH-1, B-HIGH-3** — emergency math + Safe-independence. These are the user-facing crisis paths and should be airtight before mainnet.
4. **B-HIGH-2** — cancellation indexing. Real DOS risk in production.
5. **B-HIGH-5** — close the zero-shares strand.
6. **B-MED-***: minor correctness + ergonomics. Bundle into one cleanup PR.
7. **B-LOW-***: housekeeping. Whenever convenient.

---

## 7. Things explicitly NOT findings

Repeating from §1, in case future re-readers wonder:
- AUM updater being trusted (no upper bound on `newAum`)
- Mgmt fees zero-out after >3 day gap
- 30-day emergency thresholds
- Single base token
- Non-upgradeable

If any of these become un-acceptable later, the fix is *more code* (oracle aggregation, fee catch-up, etc.), not a bug fix.
