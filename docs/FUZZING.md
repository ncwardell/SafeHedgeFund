# Fuzz Testing — Coverage and Findings

This document describes the fuzz / property / invariant tests in `test/fuzz/`,
what they prove, and — most importantly for an external auditor — what they
**do not** prove. Treat this as a *starting point*: it gives you a baseline
of automated checks the contract has survived, plus a worked-out example of
the kind of properties to add when you go deeper.

The tests live alongside the regression tests in `test/SafeHedgeFundVault.t.sol`.
Run everything with `forge test`. Run the fuzz subset with
`forge test --match-path 'test/fuzz/**'`.

---

## 1. What's here

| File | Type | Coverage |
|---|---|---|
| `test/fuzz/PropertyFuzz.t.sol` | Stateless fuzz | Round-trip, fee bounds, estimate consistency, cancel refund, slippage rejection, NAV stability. Parameterized over **6/8/18-dec** base tokens via three concrete subclasses. |
| `test/fuzz/InvariantFuzz.t.sol` | Stateful invariant | Random sequences of {deposit, redeem, process, updateAum, cancel, advanceTime} via a handler. After each step, 7 invariants are checked. |
| `test/fuzz/Reentrancy.t.sol` | Adversarial | Hooked ERC-20 that reenters the vault during transfer. Verifies `nonReentrant` blocks deposit-side and redemption-side reentry. |
| `test/fuzz/handlers/VaultHandler.sol` | Handler | The "actor" the invariant runner calls into. Bounds inputs, tracks ghost variables, swallows expected reverts. |
| `test/fuzz/Base.sol` | Shared setup | `MockToken` with parameterizable decimals, vault deployment, role wiring, helper functions. |

Default Foundry config gives **256 runs × 128 sequence depth = 32,768 invariant
checks per invariant**. Stateless fuzz is 256 cases per test. Increase via
`FOUNDRY_FUZZ_RUNS=N` in the environment (we tested up to 2000 without issues
finding new failures).

```
$ forge test --match-path 'test/fuzz/**'
```

---

## 2. Stateless property fuzz (`PropertyFuzz.t.sol`)

Each property holds across the parameter space. Parametrized over 6/8/18-dec
tokens means each property is exercised three times, once per decimal class.

| Property | Statement |
|---|---|
| `testFuzz_roundTrip_noFees` | With fees=0 and a clean updateAum cycle, deposit X then redeem all shares yields ≥ X − tolerance (0.01% + 10 wei). |
| `testFuzz_exitFeeBounded` | Total accrued exit fees ≤ exitFeeBps × gross. Catches the kind of multi-accrual that B-CRIT-1 was. |
| `testFuzz_estimateSharesMatchesMint` | The `estimateShares(X)` view matches the actual minted shares within rounding. |
| `testFuzz_estimatePayoutMatchesRedeem` | The `estimatePayout(S)` view matches the actual native received within rounding. |
| `testFuzz_cancelRefundsFullDeposit` | Cancelling an unprocessed deposit refunds exactly the deposited amount; no fee accrual. |
| `testFuzz_slippageRejectsHigherMinShares` | Setting minShares > theoretical shares causes processing to skip, no fee accrued, user can cancel and recover. |
| `testFuzz_navStableUnderNoOp` | Repeated `navPerShare()` calls without state change return the same value. |

**Edge case found by fuzzing** (documented as `test_edge_minDepositRoundTripRoundingLoss` and audit finding B-LOW-5):
Depositing *exactly* `minDeposit` on a 6/8-dec token round-trips to
`minDeposit − 1 wei` of payout, which then trips `payout < minRedemption`
inside `redeem()`. The user is stuck with shares they can't redeem via the
normal path until they deposit more or use emergency-withdraw. 18-dec tokens
don't exhibit this because `DECIMAL_FACTOR = 1` rounds the seed contribution
out of the NAV.

---

## 3. Stateful invariant fuzz (`InvariantFuzz.t.sol`)

The handler exposes 8 actions; the invariant runner picks random sequences.
Each invariant is checked after every handler call.

| Invariant | Claim | Why it matters |
|---|---|---|
| `invariant_depositEscrow` | `vault balance ≥ Σ unprocessed deposit amounts`. Vault holds escrowed deposits until they're processed or cancelled. | Catches accidental double-spend of pending deposits or a leaked escrow. |
| `invariant_totalSupplyMatchesHolders` | `totalSupply() == Σ balanceOf(holders)`. | Catches mint/burn drift, library-storage corruption. |
| `invariant_pendingMatchesQueue` | Per-user `pendingDeposits[u]` is consistent with the actual sum of unprocessed queue items for u. | Cancellation accounting depends on this. |
| `invariant_queueIndicesMonotone` | Queue head ≤ tail always. | Catches index corruption. |
| `invariant_feesNotInsane` | `totalAccruedFees (native) ≤ total ever-deposited`. | A generous catch-all for fee-ledger drift; tighter property tests are in PropertyFuzz. |
| `invariant_noUserExceedsTotalSupply` | No user holds more than totalSupply. | Catches arithmetic errors in mint paths. |
| `invariant_callSummary` | (No assertion — Foundry shows action distribution on failure.) | Visibility into which actions the fuzzer actually exercised. |

Test run produces ~16K calls per action (8 actions × 16K ≈ 128K total state
transitions per invariant). All 7 invariants hold with zero reverts.

### Things explicitly NOT asserted as invariants

These would fire false positives — the contract is correct in scenarios that
"violate" them.

- **Vault solvency for queued redemptions.** The whole architectural premise
  is that capital lives off-chain; on-chain liquidity is intentionally a
  fraction of AUM. Whether a queued redemption can be processed *now* is an
  operational concern (target-liquidity management by the keeper), not a
  contract-level invariant.
- **Reported AUM matches on-chain liquidity.** It's expected to exceed it
  (off-chain assets count). Lower-bound check happens inside `updateAum`.
- **Mgmt fees accrue continuously.** They explicitly stop when AUM update
  gap > 3 days (design choice §1 in `AUDIT_REPORT.md`).

---

## 4. Reentrancy adversarial (`Reentrancy.t.sol`)

A `HookedToken` lets us register arbitrary `(target, calldata)` to be
invoked once per transfer. We use this to:

| Test | Setup | What it proves |
|---|---|---|
| `test_reentrancy_depositCannotReenter` | Hook calls `vault.deposit(100e6, 0)` during the `transferFrom` inside the outer `deposit` | Inner deposit reverts (swallowed by the hook); only one item is in the queue afterwards. |
| `test_reentrancy_redemptionPayoutCannotReenter` | Hook calls `vault.redeem(1, 0)` during the Safe → token.transfer inside `processRedemptionQueue` | Inner redeem reverts; no extra queued redemption. |
| `test_reentrancy_lockReleasedAfterOuterCall` | No hook | Two sequential deposits in the same prank scope both succeed, confirming the lock is per-call, not per-session. |

**Threat model covered:** ERC-777-style hooked tokens, malicious base tokens,
arbitrary fallback tokens. **Not covered:** inter-contract reentrancy where
the user's *own* contract is the entry point — the user is the one calling
in, so the lock there is just the standard nonReentrant on entry points
which the existing code already has.

---

## 5. Findings surfaced by fuzzing

### B-LOW-5 (new) — Round-trip rounding loss at exact `minDeposit` for non-18-dec tokens

**Where:** `redeem()` in `SafeHedgeFundVault.sol`, the `if (payout < minRedemption) revert BelowMinimum()` check.

**Manifestation:**
- Deploy with USDC (6 decimals), `minDeposit = 1e6`, `minRedemption = 1e6`
- Founder deposits, vault has a 1-unit AUM seed
- User deposits exactly 1e6, processes
- updateAum reflects the new total
- User tries to redeem all shares
- Reverts with `BelowMinimum()` because payout = 999999, not 1000000

**Cause:** the AUM seed (1 native unit) gets normalized to `DECIMAL_FACTOR`
(1e12 for USDC) when computing NAV, contributing a tiny per-share fraction
that gets multiplied through and rounded. For 18-dec, `DECIMAL_FACTOR = 1`
and the contribution rounds to zero — no issue.

**Severity:** Low. ~1-wei value loss; only blocks the user's normal-path
redemption when they deposited *exactly* `minDeposit`. Workarounds:
- Deposit > minDeposit by even one extra wei
- Set `minRedemption < minDeposit` in the constructor
- Use emergency withdrawal (works regardless of minRedemption)

**Recommended fix:** either
- (a) Have `minRedemption` default to `minDeposit / 2` to absorb rounding;
- (b) Replace the seed-funded initial AUM with a "first-deposit-bootstrap"
  pattern (no seed needed); or
- (c) Document the constraint in the deployment guide.

Test: `test_edge_minDepositRoundTripRoundingLoss` in `PropertyFuzz.t.sol`
demonstrates and pins the behaviour.

---

## 6. What this suite does NOT cover

These belong in a follow-up audit — listed so you know what gaps exist.

### Coverage gaps
- **Configuration timelock lifecycle.** Propose → cancel → re-propose, cooldown
  edge cases, simultaneous proposals across keys.
- **Performance fee accrual through HWM cycles.** Bull → bear → recovery
  scenarios; the B-MED-1 finding (perf fee charged on pre-fee NAV but HWM
  updated post-fee) is not exercised by fuzz.
- **Fee payout liquidity logic.** `payoutAccruedFees` with vault-only,
  Safe-only, and split scenarios.
- **Pause + emergency interactions.** Pause → wait 30 days →
  `checkEmergencyThreshold` → withdraw → exit emergency → unpause cycle.
- **Module disable mid-flight.** What happens if the Safe disables the module
  between queue and processing of a redemption.
- **Decimals outside {6,8,18}.** Tokens with 0, 1, 12, 17 decimals.
  Constructor only rejects > 18; the rest *should* work but isn't fuzzed.
- **Adversarial AUM updater.** Property tests for "no choice of `newAum`
  values can let the updater extract more than X% of fund value" — this is
  the trusted-role design choice, but fuzzing the boundaries is still
  valuable.

### Methodological gaps
- **Symbolic execution / formal verification.** We're testing example values;
  Halmos / Certora / KEVM can prove properties hold for *all* inputs.
- **Integration with a real Safe.** Tests use a `MockSafe` that implements
  just `isModuleEnabled` + `execTransactionFromModule`. A real Safe has
  more behaviour (guards, fallback handlers, signature verification on
  some paths) that could interact non-trivially.
- **Multi-block / MEV scenarios.** The fuzzer treats time as advanceable
  but not adversarially-ordered relative to operations. Front-running
  `updateAum` with a deposit, etc., isn't modelled.
- **Cross-function reentrancy.** Hooked-token tests cover same-function
  reentrancy. Cross-function (e.g., reenter `redeem` while inside
  `processDepositQueue`) isn't tested but the same `nonReentrant` lock
  applies, so the same protection holds.
- **Gas / OOG behaviour.** Fuzz didn't push queue length toward the 1000
  cap or maxBatchSize=200. Cancellation and processing under high queue
  load is plausible to break in pathological cases.

---

## 7. Suggested next steps for an auditor

In rough priority order:

1. **Add fuzz coverage for the gaps in §6.** Especially the perf-fee + HWM
   cycle (B-MED-1) and decimals outside {6,8,18}.
2. **Halmos symbolic execution** on the fee accrual and emergency math —
   these are pure functions of state and benefit from full-domain proofs.
3. **Replace MockSafe with a forked-mainnet Safe.** Test that the module
   actually works against a real Safe deployment.
4. **Stress-test the queue.** Fill the deposit queue to MAX_QUEUE_LENGTH;
   verify cancellation, processing, and full-queue rejection all behave
   correctly under that pressure.
5. **Adversarial scenarios beyond reentrancy.** Tokens with fee-on-transfer,
   blocklist hooks, rebasing balances, transfer-amount-mismatch (returning
   true while transferring less). The current code uses `SafeERC20` but
   doesn't defend against fee-on-transfer at the deposit path (the Safe will
   receive less than `netAmountNative`), which is a subtle bug class worth
   pursuing.
6. **Long-running invariants on a forked chain** with a real keeper bot
   driving updateAum.

---

## 8. Appendix: how to extend the suite

The pattern in `InvariantFuzz.t.sol` is the standard Foundry handler/invariant
shape:

```solidity
contract MyHandler {
    function someAction(uint256 a, uint256 b) public {
        a = bound(a, MIN, MAX);
        // try { vault.someAction(a, b); } catch {}
    }
}

contract MyInvariants is Test {
    function setUp() public {
        // Deploy + wire handler
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: [...]}));
    }

    function invariant_thingMustHold() public view {
        assert(...);
    }
}
```

To add a new invariant, just write another `invariant_*` function in
`InvariantFuzz`. To explore a new action surface, add a method to
`VaultHandler.sol` and add its selector to `targetSelector`.

For property tests, follow the `testFuzz_*` pattern in `PropertyFuzz.t.sol`.
Always `bound()` your inputs — unbounded inputs lead to most of the budget
being spent on reverts rather than meaningful state transitions.
