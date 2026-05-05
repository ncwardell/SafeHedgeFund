# SafeHedgeFund Audit Report

**Branches reviewed:** `claude/fix-critical-bugs` (vault) + `claude/shared-pool` (lending)
**Reviewer:** Claude (Opus 4.7)
**Scope:** `contracts/SafeHedgeFundVault.sol`, `contracts/core/*`, `contracts/lending/SharedPool.sol`
**Out of scope:** `portal/` reviewed only for ABI surface. (`ICP/` removed from repo.)

---

## 0. Security model — what is Gnosis Safe actually protecting?

The Safe is a great primitive for the *off-chain* threat model: stolen keys, rogue insiders, nation-state coercion. But the Safe protects funds only when the smart-contract module attached to it can't be tricked into asking the Safe for the wrong thing.

This vault *is* a Safe module. Every successful exploit of this contract becomes a clean call to the Safe via `execTransactionFromModule` — at which point the Safe sees a properly authenticated request from a known module and signs it off. Multisig signers don't get a second chance to review.

So the relevant questions for this audit are:

1. **Can a caller construct an arbitrary module call?** No. The three call sites (`_payout`, `EmergencyManager.executePayout`, `FeeManager._executeFeePayout`) all hardcode the target as `address(baseToken)` (immutable), the operation as `Call` (not DelegateCall), and the data as `IERC20.transfer(<bounded recipient>, amount)` where the recipient comes from `msg.sender` or a queue item, never from arbitrary calldata. Verified by hand against the three sources.

2. **Can a caller cause the contract to ask for too much?** This is where the real bugs lived. Pre-fix, the redeem path overcharged exit fees by 2× to N× (B-CRIT-1) and the deposit path leaked entrance fees on every retry of a failing item (B-CRIT-2). Both have been fixed via a preview/record split in FeeManager.

3. **Can role compromise hurt users?** Partially. AUM_UPDATER is explicitly trusted (design choice §1) — a compromised key can manipulate NAV within `[onChainLiquidity, ∞]`. ADMIN_ROLE controls config (rate-limited by 3-day timelock + 5-day cooldown), pause, and rescue. GUARDIAN_ROLE can trigger emergency mode (which, post-B-HIGH-3 fix, no longer depends on the Safe being reachable).

4. **Can the Safe being unreachable brick user funds?** Pre-fix yes — the emergency path went through the module. Post-B-HIGH-3 emergencyWithdraw pays only from the vault's own balance, so a manager who disables the module can't trap users behind a non-functional crisis path.

5. **Reentrancy on the module call?** All entry points that hit `_payout` (`redeem`, `processRedemptionQueue`) carry `nonReentrant`. The user-side recipient cannot re-enter the vault during the Safe-mediated transfer.

The remaining open findings (`B-MED-*`, `B-LOW-*`) are correctness, ergonomics, and dead-code issues — none of them give a caller a way to extract more than their fair share or interfere with another user's withdrawal. The criticals and the user-facing high-severity issues are all fixed on this branch.

---

## 1. State of the code — what's been fixed in this branch

| Finding | Severity | State | Commit |
|---|---|---|---|
| B1 — batch deposit head-pointer drift | Critical | **Fixed** | `36b5798` |
| B2 — OZ v4 imports | Critical (build) | **Fixed** | `36b5798` |
| B18 — navPerShare mixed-unit subtraction | Critical | **Fixed** | `36b5798` |
| B10 — frontend ABI mismatches | High | **Fixed** | `ee96921` |
| B-CRIT-1 — exit fee accrued 2×–N× per redeem | Critical | **Fixed** | this PR |
| B-CRIT-2 — entrance fee leaks on failed processings | Critical | **Fixed** | this PR |
| B-CRIT-3 — emergencyWithdraw uses live totalSupply (newly found) | Critical | **Fixed** | this PR |
| B-HIGH-2 — cancellation gas bomb | High | **Fixed** | this PR |
| B-HIGH-3 — emergency depends on Safe access | High | **Fixed** | this PR |
| B-HIGH-4 — `_payout` fee transfer encodes wrong amount | High | **Fixed** (deleted) | this PR |
| B-HIGH-5 — auto-process zero-shares strand | High | **Fixed** | this PR |
| B-HIGH-1 (audit residue) — entitlement vs payout in emergency | — | **Withdrawn**: math review showed `+= entitlement` is the correct accounting. See §3 for the analysis. |
| B-MED-1 — perf fee charged on pre-fee NAV, HWM updated to post-fee NAV | Medium | **Fixed** (cleanup PR) |
| B-MED-3 — pauseTimestamp not cleared on unpause | Medium | **Fixed** (cleanup PR) |
| B-LOW-5 — round-trip rounding loss at exact minDeposit (non-18-dec) | Low | **Fixed** (cleanup PR) |

Open findings (correctness/ergonomics, none escalating to fund loss): B-MED-2, B-MED-4, B-LOW-1 through B-LOW-4. See §5.

---

## 2. Design choices (NOT findings)

These are explicit policy decisions, called out so they don't get re-flagged in future re-reviews.

| Decision | Where | Rationale |
|---|---|---|
| **AUM updater is trusted** — `newAum` validated only against on-chain lower bound | `FeeManager.sol:139-140` | Hedge fund needs to deploy off-chain; tight upper bound rejects legitimate growth. Mitigated by multi-sig keeper key, monitoring, emergency path |
| **Mgmt fees skipped if AUM update gap > 3 days** | `FeeManager.sol:197` | Avoids huge fee spike after extended downtime; manager forfeits fees as the cost of an outage |
| **Single base token only** | constructor | Multi-asset accounting is its own project; off-chain venues handle conversions |
| **HWM reset mechanic** (drawdown threshold + recovery window) | `FeeManager.sol:507-541` | Allows recovery from drawdowns without double-paying performance fees on the same gain band |
| **Non-upgradeable** | architectural | Users see the exact code they trust; "upgrade" = deploy v2, emergency-out of v1 |
| **30-day automatic emergency thresholds** | `EmergencyManager.sol:43` | Long enough to avoid false trips during holidays/long outages, short enough to protect users |
| **5 pending requests/user, 1000 queue cap** | `QueueManager.sol:6-7` | DOS prevention |
| **Deposit shares computed at process time, not queue time** | `QueueManager.sol:170` | Fairness: user gets the realized NAV, not a predicted one. Slippage protected by `minShares` |

---

## 3. Why B-HIGH-1 was withdrawn (and what was actually wrong)

The original audit flagged `es.emergencyTotalWithdrawn += entitlement` as a bug, claiming late withdrawers would receive less than their fair share if early withdrawers got partial payouts. I initially "fixed" this by tracking `+= payoutAmount` — until writing the regression test surfaced that the *original* code was algorithmically correct.

The pro-rata invariant the algorithm wants to maintain is: every user gets the same fraction of their entitlement, where the fraction = `available_at_their_turn / remainingClaims_at_their_turn`. For that ratio to stay constant across sequential calls:

- After each call: `available -= entitlement * scale` and `remainingClaims -= entitlement`
- New scale = `(avail - e*s) / (claims - e)` = `(avail - (avail/claims)*e) / (claims - e)` = `avail/claims` ✓

Tracking `+= entitlement` keeps `remainingClaims` = "sum of entitlements not yet claimed". Tracking `+= payoutAmount` instead would make `remainingClaims` shrink slower than `available`, which actually makes scale *decrease* for late withdrawers and strand liquidity in the vault.

**The real bug** the test exposed was elsewhere: `emergencyWithdraw` divided entitlement by `totalSupply()` (live), but each withdrawal burns shares, so subsequent users computed entitlement against a smaller denominator and over-claimed. Architecture doc actually said the supply was supposed to be snapshotted — it just wasn't. That's now B-CRIT-3 below, and it's fixed.

Lesson: write the test first. The audit chain-of-reasoning was internally consistent but didn't survive contact with executable math.

---

## 4. New finding: B-CRIT-3 — emergency divides by live totalSupply

**File:** `EmergencyManager.sol:emergencyWithdraw` (pre-fix), `SafeHedgeFundVault.sol:emergencyWithdraw` (caller)
**Severity:** Critical (breaks pro-rata fairness once any user withdraws)
**Status:** **Fixed in this PR**

Pre-fix:

```solidity
uint256 entitlement = (shares * es.emergencySnapshot) / totalSupply;  // ← live totalSupply
```

After alice burns 50 of 100 shares, totalSupply is 50. Bob (also holding 50 shares) computes:

```
entitlement = 50 * snapshot / 50 = snapshot   // the entire snapshot!
```

When `available >= remainingClaims`, the formula then pays bob the entire entitlement = the full snapshot, which is way more than his fair share. Even when liquidity is short and the proportional fallback fires, the inflated entitlement pumps the numerator and bob still over-claims.

Architecture doc explicitly said both AUM and supply were supposed to be snapshotted. Code only snapshotted AUM.

**Fix:**
- Add `emergencySnapshotSupply` field to `EmergencyStorage`.
- `triggerEmergency` and `checkEmergencyThreshold` now take `currentSupply` and store it.
- `emergencyWithdraw` uses `es.emergencySnapshotSupply` instead of the live value.

Regression test: `test_BHIGH1_BCRIT3_emergencySplitsAvailableProportionally` — two users with equal shares, partial vault liquidity, both must receive exactly equal payouts (`assertEq`, not approximate).

---

## 5. Findings — fixed in this PR

For each, the structural fix and the regression test that demonstrates it.

### B-CRIT-1 — exit fee accrued 2×–N× per redeem
- **Was:** `redeem()` mutated `accruedExitFees` for the slippage check; `_payout` mutated it again on every actual transfer; processor retries piled up more.
- **Fix:** split FeeManager into `previewExitFee` (view) and `recordExitFee` (mutator). `redeem()` previews; `_payout` only records *after* the Safe transfer is verified to have moved the user's balance. Same pattern for entrance fee.
- **Test:** `test_BCRIT1_exitFeeAccruedExactlyOnce_queuedPath`, `test_BCRIT1_exitFeeAccruedExactlyOnce_autoPayoutPath` — assert exit fee equals exactly 1× the gross fee.

### B-CRIT-2 — entrance fee leaks on failed processings
- **Was:** `_processDepositItem` and `processSingleDeposit` mutated the fee ledger before slippage / zero-shares checks. Failed retries piled up phantom accruals; user could cancel and walk away with a clean refund leaving phantom fee on the books.
- **Fix:** preview-then-record. Fee is committed only after the operation is irreversibly successful (item marked processed, mint scheduled).
- **Test:** `test_BCRIT2_failedSlippageDoesNotLeakEntranceFee` — three failed-slippage process passes followed by a cancel; assert `accruedFees().entrance == 0` throughout.

### B-CRIT-3 — emergency divides by live totalSupply
- See §4 above.

### B-HIGH-2 — cancellation gas bomb
- **Was:** `cancelDeposits` / `cancelRedemptions` looped the entire queue (head→tail) looking for the user's items. Per-user index mappings already existed but were unused — a user with deposits scattered across a long queue could hit gas limits trying to cancel.
- **Fix:** iterate `userDepositIndices[user]` / `userRedemptionIndices[user]` directly. Skip entries where the underlying queue item has been deleted (`amount == 0`) or already processed.
- **Test:** `test_BHIGH2_cancellationFindsOnlyUserItems` — queue items from three users, each cancels independently and recovers exactly their queued total.

### B-HIGH-3 — emergency depends on Safe access
- **Was:** `EmergencyManager.executePayout` tried vault first, then fell through to `execTransactionFromModule` → reverted with `ModuleNotEnabled` if the module had been disabled. Defeats the purpose of emergency mode.
- **Fix:** `executePayout` now pays only from the vault's own balance. Deleted the Safe call and the `isModuleEnabled` parameter. Vault's `_emergencyPayout` updated. The pro-rata math in `emergencyWithdraw` already handles partial liquidity correctly — passing `baseToken.balanceOf(address(this))` as `available` means the formula scales payouts within whatever the vault holds, no Safe needed.
- **Test:** `test_BHIGH3_emergencyWithdrawWorksWithSafeDisabled` — explicitly `safe.disableModule(vault)`, then verify a user can still withdraw against vault liquidity.

### B-HIGH-4 — `_payout` fee transfer encodes wrong amount; double-counts on success
- **Was:** Two-line block at the end of `_payout` that ABI-encoded `feeNative` (which was actually 18-decimal normalized, not native) into an `IERC20.transfer` from the Safe. Always reverted in practice (treated 18-dec quantity as native USDC). If it had ever succeeded, would have double-counted by adding `feeNative` to `accruedExitFees` on top of the previous mutation.
- **Fix:** deleted the whole block. Exit fee revenue already lives at the Safe (gross stays at Safe, net goes to user). `payoutAccruedFees` correctly pulls it back via the same module path when the admin actually wants to pay out fees.
- **Test:** covered by B-CRIT-1 tests (exit fee ledger matches gross × bps with no extra).

### B-HIGH-5 — auto-process zero-shares strand
- **Was:** `processSingleDeposit` returned `ok=true` with `shares==0` after committing state mutations. The caller (`_tryAutoProcessDeposit`) had a special-case that bailed without minting or refunding — user's tokens stranded in vault, queue item burned.
- **Fix:** `shares == 0` now returns `false` (treated as slippage failure) without committing state. Item stays in queue; user can cancel and recover. Caller's special-case removed.
- **Test:** `test_BHIGH5_autoProcessZeroShares_userCanRecover` — inflate NAV so shares would round to 0, deposit with auto-process, verify user can cancel and recover full deposit.

---

## 6. Open findings (out of scope for this PR)

None of these are exploitable for fund loss. They're correctness/ergonomics/dead-code items; bundle into a follow-up PR.

### ~~B-MED-1~~ — Fixed in cleanup PR
~~Performance fee charged against `tempNav` (pre-fee), HWM bumped to `newNavPerShare` (post-fee).~~
**Fix:** `_accrueFees` now returns the gross NAV to the caller, which passes it to `_updateHighWaterMark` instead of the post-fee `newNavPerShare`. HWM tracks the value the perf fee was just charged against, so a no-op update at the same AUM doesn't re-charge fees on the spread.
**Test:** `test_BMED1_noPerfFeeOnNoOpUpdate`.

### B-MED-2 — `getTotalAum` ≠ `feeStorage.aum` (naming, not math)
**File:** `SafeHedgeFundVault.sol:675-680`
`getTotalAum()` returns on-chain liquidity minus fees; `feeStorage.aum` is the last reported total. Both are valid concepts but the names don't communicate the difference. Rename to `getOnChainLiquidity()` and `getReportedAum()`.

### ~~B-MED-3~~ — Fixed in cleanup PR
~~Stale `pauseTimestamp` lingers after unpause.~~
**Fix:** `unpause()` now `delete`s `emergencyStorage.pauseTimestamp`.
**Test:** `test_BMED3_pauseTimestampClearedOnUnpause`.

### B-MED-4 — `_getDecimals` silent fallback to 18
**File:** `SafeHedgeFundVault.sol:694-697`
If the base token reverts on `decimals()`, the constructor silently assumes 18. Better to revert.

### B-LOW-1 — Dead overflow check in queue tail increments
`QueueManager.sol:66-70` and the redemption queue equivalent. `==` fires only at exactly max; 0.8 catches the actual overflow on `++`. Either delete or use `>=`.

### B-LOW-2 — `rescueETH` uses `.transfer` (2300 gas)
`SafeHedgeFundVault.sol:444-451`. Use `call{value:}` with success check.

### B-LOW-3 — Doc rot
`README.md` and `ARCHITECTURE.md` reference an `AUMManager.sol` library that no longer exists.

### B-LOW-4 — Dead helpers
`_emitDeposited`, `_emitTokensRescued`, `_emitETHRescued`, `_revertCannotRescueBase` (`SafeHedgeFundVault.sol:572-586`) are unused since the inlining refactor.

### ~~B-LOW-5~~ — Fixed in cleanup PR
~~Depositing exactly `minDeposit` on a 6/8-dec token round-tripped to `minDeposit − 1 wei`, tripping the `minRedemption` check inside `redeem()`.~~
**Fix:** `redeem()` now skips the `minRedemption` check when `shares == balanceOf(msg.sender)` (full-exit override). The check exists as a dust-spam guard for partial redemptions; it shouldn't block users from fully closing their position when round-trip rounding eats a wei or two. The `minAmountOut` slippage guard still applies on every redeem.
**Tests:** `test_BLOW5_fullExitBypassesMinRedemption` (full exit succeeds), `test_partialRedemption_stillHonorsMinRedemption` (dust-spam guard still works for partials), `test_edge_minDepositRoundTripFullExit` in `PropertyFuzz.t.sol` (parameterized over decimals).

---

## 7. Test coverage

```
test/SafeHedgeFundVault.t.sol           — 9 regression tests
├─ test_B1_batchProcessing_mintsAllItems
├─ test_depositAndRedeemFlow                       (full deposit→AUM→redeem round trip)
├─ test_BCRIT1_exitFeeAccruedExactlyOnce_queuedPath
├─ test_BCRIT1_exitFeeAccruedExactlyOnce_autoPayoutPath
├─ test_BCRIT2_failedSlippageDoesNotLeakEntranceFee
├─ test_BHIGH1_BCRIT3_emergencySplitsAvailableProportionally  (also exercises B-CRIT-3 + B-HIGH-3)
├─ test_BHIGH2_cancellationFindsOnlyUserItems
├─ test_BHIGH3_emergencyWithdrawWorksWithSafeDisabled
└─ test_BHIGH5_autoProcessZeroShares_userCanRecover

test/fuzz/PropertyFuzz.t.sol            — 7 fuzzed properties × 3 decimals (6/8/18) = 21 + edge case
test/fuzz/InvariantFuzz.t.sol           — 7 stateful invariants over 256 runs × 128 seq depth (~128K calls each)
test/fuzz/Reentrancy.t.sol              — 3 adversarial reentrancy tests with hooked ERC-20
```

All passing. See `docs/FUZZING.md` for the full property/invariant catalogue,
what was found by fuzzing (B-LOW-5), and what's NOT covered by this suite.

What's still missing:

- **Decimals fuzz** — currently only 6-dec USDC. Parameterize over 6/8/18.
- **Property tests** — pro-rata invariant under random share distributions and liquidity levels.
- **Performance fee + HWM** — no scenario coverage of B-MED-1 timing.
- **Multi-AUM-update sequences** — covering management fee accrual, HWM drawdown/recovery, the 3-day mgmt-fee gap.
- **Config proposal lifecycle** — propose → cancel, propose → expire, cooldown enforcement.
- **Fee payout** — `payoutAccruedFees` with vault-only liquidity vs needing the Safe.
- **Reentrancy adversarial** — base token with a malicious hook (ERC777-style), prove `nonReentrant` blocks all the relevant entry points.

These are good next-PR work; none of them are blockers for the fixes in this branch.

---

## 8. Verdict (vault scope)

The criticals and user-facing highs are closed. The remaining medium/low items are correctness polish, not security. The contract still has an explicitly trusted role (AUM_UPDATER) — that's a design choice with operational mitigations, not a bug.

For mainnet readiness I'd want, in addition to the open findings being closed:
- A formal third-party audit (this is one Claude reading the source for an afternoon, not a substitute)
- Property tests covering the pro-rata invariant under fuzz
- Operational runbook for the keeper (AUM cadence, processor scheduling, what triggers the guardian)
- A drill: actually disable the Safe module on a testnet deployment and verify users can emergency-withdraw end to end

---

# Part II — `SharedPool` (lending) review

The `claude/shared-pool` branch adds `contracts/lending/SharedPool.sol`, plus four new pool-only callbacks on the vault (`mintForPool`, `burnFromUser`, `addToAum`, `subFromAum`) and three timelocked config keys (`swapFeeBps`, `lltvBps`, `borrowRateBps`). This part reviews those changes.

Full design walkthrough is in `docs/LENDING.md`. This section only covers security findings.

## P2.0 — Threat model recap

Same Safe-as-source-of-funds threat model as the vault. The pool can:
- Mint and burn HFS via `vault.mintForPool` / `vault.burnFromUser`
- Adjust `feeStorage.aum` via `vault.addToAum` / `vault.subFromAum`

A buggy pool could corrupt `fs.aum` (NAV math goes wrong) or mint arbitrary HFS (dilute existing holders). Both are restricted to the pool address (set once via `setSharedPool`), so the trust assumption reduces to: **the pool contract code is correct**, and the keeper hasn't accidentally pointed `setSharedPool` at a malicious address.

The pool itself doesn't have Safe module access. It interacts with the fund's USDC only through transfers in/out of its own balance. The Safe's USDC isn't directly touchable by pool operations — fees and reserves still flow through the vault and its module path.

## P2.1 — Walkthrough of state transitions

| Operation | usdcReserve | totalSupply | fs.aum | Notes |
|---|---|---|---|---|
| `supply(amount)` | +amount | 0 | 0 | Fund-internal move (Safe→pool) doesn't change total fund value; keeper reconciles at next updateAum |
| `swapUsdcForHfs(in)` | +in | +hfsOut | +in | Slippage value retained in pool; NAV ↑ correctly via the `addToAum` callback |
| `swapHfsForUsdc(in)` | -out | -in | -out | Symmetric; NAV ↑ from slippage |
| `depositCollateral(amt)` | 0 | 0 | 0 | HFS moves from user to pool; locked, not in AMM |
| `withdrawCollateral(amt)` | 0 | 0 | 0 | Reverse; health check enforced |
| `borrow(amt)` | -amt | 0 | 0 | USDC out, loan claim in (offsetting); net fund value unchanged |
| `repay(amt)` | +amt | 0 | 0 | Symmetric |
| `_liquidate(b)` | 0 | -col (burn) | -debt | Loan claim written off; collateral burned |
| `sweepLiquidations` | sum of above | sum of above | sum of above | Iterates active borrowers, applies `_liquidate` for unhealthy ones |

Every operation that changes `totalSupply` is paired with a matching `fs.aum` adjustment, either via the pool callback or via a corresponding offset (loan claim) that the keeper reconciles. **No supply changes can leave NAV stale**, which closes the front-run-the-keeper exploit window.

## P2.2 — Verified properties (from tests)

`test/SharedPool.t.sol` — 24 tests, all passing.

| Property | Test |
|---|---|
| `hfsReserve` is derived from `usdcReserve` and NAV (no stored state) | `test_hfsReserve_isDerivedFromUsdcAndNav` |
| `hfsReserve` auto-updates after operations (no rebalance call needed) | `test_hfsReserve_autoTracksAfterSwap` |
| xy=k slippage applies in both directions | `test_swap_*ForHfs_appliesSlippage`, `test_swap_hfsForUsdc_appliesSlippage` |
| **NAV captures slippage immediately via callback** | `test_swap_navIncreasesAfterSwap_viaCallback`, `test_swapHfsForUsdc_navIncreases` |
| **No stale-NAV exploit window** (Bob's deposit gets fair shares right after Alice's swap) | `test_noStaleNavExploitBetweenSwapAndUpdate` |
| Borrow / repay are NAV-neutral (loan claim offsets USDC movement) | `test_borrow_doesNotMoveNav`, `test_repay_doesNotMoveNav` |
| Liquidation correctly subtracts debt from `fs.aum` | `test_liquidation_writesOffDebtFromAum` |
| Sweep liquidates only unhealthy positions, leaves healthy ones | `test_sweepLiquidations_onlyUnhealthyBorrowers` |
| Sweep auto-runs on `updateAum` | `test_sweepLiquidations_onAumUpdate` |
| LLTV enforcement on borrow | `test_borrow_revertsAboveLltv`, `test_borrow_atExactLltvSucceeds` |
| Withdraw-collateral revert on health violation | `test_withdrawCollateral_revertsIfWouldBecomeUnhealthy` |
| Block-level swap freeze in same block as `updateAum` | `test_swapFrozen_inSameBlockAsUpdateAum` |
| Repay caps at outstanding debt (no over-pull from user) | `test_repay_capsAtDebt` |
| Zero-amount ops revert | `test_swap_zeroAmount_reverts`, `test_zeroAmountOps_revert` |
| Same-block round-trip (deposit + swap-out) loses money for user | `test_sameBlockRoundTrip_noExploit` |
| Direct USDC transfer to pool isn't tracked but doesn't break ops | `test_directUsdcTransfer_notReflectedInReserve` |
| Pool-only callbacks reject external callers | `test_onlyPool_canCallVaultCallbacks` |
| Vault-only `sweepLiquidations` rejects external callers | `test_onlyVault_canCallSweepLiquidations` |

## P2.3 — Findings

### Critical / High / Medium

None.

### Low

**P2-L1 — `usdcReserve` can desync from actual `usdc.balanceOf(this)`**

If anyone transfers USDC directly to the pool address (bypassing `supply`), the actual balance grows but `usdcReserve` doesn't. The "extra" USDC sits stuck — no withdrawal path tracks it.

**Impact:** USDC sent directly is permanently locked in the pool, contributing nothing to swap depth or lending capacity. Not exploitable; just inefficient.

**Mitigation (not implemented in v1):** add an admin-only `sweepStuckUsdc()` that reads `usdc.balanceOf(this) - usdcReserve` and accounts for it (either bumps `usdcReserve` or rescues to the Safe). For F&F scale, just document "don't do that."

**Test:** `test_directUsdcTransfer_notReflectedInReserve` confirms the desync behavior is benign.

---

**P2-L2 — Pool operations continue while vault is paused**

`vault.pause()` halts vault-level deposits and redemptions. It does NOT halt pool operations (swaps, borrows, supply). If admin pauses because of an emergency, users can still drain pool USDC via `swapHfsForUsdc`.

**Impact:** the protective intent of pause is partial. Existing borrowers can continue to borrow more; new positions can be opened. Liquidation sweep still runs at next `updateAum`.

**Mitigation (not implemented in v1):** add a `notPausedOnVault` modifier to mutating pool functions reading `vault.paused()`. Probably skip `repay` (always allow repayment to clear positions) and `withdrawCollateral` for the same reason. For F&F scale, the vault's emergency-mode flow handles full-fund crises; the pool-side gap is small.

---

**P2-L3 — Deployment ordering matters**

If admin calls `pool.supply()` BEFORE any HFS exists (totalSupply == 0), the supplied USDC inflates AUM but has no shares to dilute against. After the first `vault.deposit` mints shares at the default initial NAV, the entire pool's USDC effectively gets attributed to the first depositor.

**Impact:** Operational error during deployment. The first depositor (probably the fund admin) over-extracts value at others' expense — but since the same admin is supplying both, it's value-neutral.

**Mitigation (documented):** Deploy in this order:
1. Deploy vault, set initial 1-USDC AUM seed.
2. Deploy pool, wire via `setSharedPool`.
3. Admin deposits USDC into vault → mints HFS shares.
4. Process the deposit, refresh AUM.
5. Admin supplies USDC to pool, refresh AUM again.

`test/SharedPool.t.sol::setUp()` follows this order; replicate in production deployment script.

---

**P2-L4 — Liquidation sweep gas grows linearly with `_activeBorrowers.length()`**

At F&F scale (5–50 borrowers) this is fine. At higher scale, a sweep with many liquidations could exceed the block gas limit, leaving some unhealthy positions un-liquidated.

**Mitigation (not implemented in v1):** add a `maxToProcess` parameter to `sweepLiquidations`, similar to the deposit/redemption queue's `maxToProcess`. Vault would call `sweep(N)` per `updateAum`, with the keeper choosing N based on gas budget. Skip for F&F.

### Informational

**P2-I1 — xy=k integer rounding favors the user by ≤1 wei**

`hfsOut = hfsRes - (k / newUsdc)` — `k / newUsdc` rounds down, so subtraction gives a slightly larger `hfsOut` than the precise math would. Standard rounding direction issue in xy=k AMMs; mitigated in Uniswap V2 by `(k * 1000 + 999) / (1000 * newUsdc)`. At HFS's 18-dec resolution, the extra wei is economically zero.

**P2-I2 — `_liquidate` doesn't accrue interest before snapshotting `debt`**

`sweepLiquidations` calls `_accrueBorrowerInterest(b)` before checking `_isUnhealthy(b)`, so debt is fresh at the health check. Then `_liquidate` reads `borrowOf[borrower]` directly without re-accruing — but no time has passed (same tx), so the freshly-accrued debt is still current. Correct, just worth noting for code readers.

**P2-I3 — `notFrozen` modifier checks `block.number == vault.lastAumBlock()`**

Specifically equality, not "≥". Once `block.number` advances past `lastAumBlock`, swaps work. Always exactly one block of freeze. Behaves as intended.

## P2.4 — Simplifications applied during this review

- **Removed unused `NotUnhealthy` error** (declared but never thrown).
- **Cached `baseDecimals` and pre-computed `DECIMAL_FACTOR` as immutables in pool.** Saves a `vault.baseDecimals()` external call on every `swap` and health check. ~250 gas per call × N call sites.
- (Earlier: dropped `USDC_DECIMALS_FACTOR` and `lastInterestAccrualTimestamp` — both set but never read.)

## P2.5 — Known limitations (for v2)

Documented in `docs/LENDING.md §6`. Summary:

1. **Vault deposit/redeem still has the daily-staleness window** — pool callbacks fix the swap path; vault-side flows haven't been updated to use the same pattern. Pre-existing concern, not regressed.
2. **Fund-only USDC supply in practice** — `supply()` is open but no LP shares yet; external suppliers would just be donating.
3. **Fixed-rate borrow** — no utilization curve.
4. **No flash-loan resistance** — block-level swap freeze covers the obvious vector around `updateAum`; broader analysis is a v2 concern.
5. **Liquidation has no third-party incentive** — auto-sweep only. Keeper SLA matters.
6. **Pool always holds zero HFS for AMM purposes** — the only HFS the pool holds is borrower collateral. Worth knowing for invariant checks.

## P2.6 — Verdict (lending scope)

The lending design is small and tightly scoped. ~280 lines of pool code + ~30 lines of vault changes. The core property (NAV stays correct between keeper updates via `addToAum`/`subFromAum` callbacks) is verified by an explicit test that simulates the would-be exploit.

No critical or high findings. Four low findings, all either deployment guidance or v2-scope features.

For mainnet readiness on this part:
- Same as Part I: a real third-party audit.
- Specific to lending: model the bad-debt scenario under various NAV trajectories.
- Test the swap-and-borrow flow on a testnet with realistic gas costs (Anvil tests are gas-accurate but block-time / mempool dynamics differ).
- Define and document the keeper SLA explicitly. The whole liquidation mechanism depends on `updateAum` running.
