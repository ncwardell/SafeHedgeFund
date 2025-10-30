# Smart Contract Audit Report - SafeHedgeFund
**Date:** 2025-10-30
**Auditor:** Claude Code
**Contracts Audited:** SafeHedgeFundVault.sol, QueueManager.sol, FeeManager.sol, EmergencyManager.sol, ConfigManager.sol, AUMManager.sol

---

## Executive Summary

This audit identified **6 CRITICAL**, **3 HIGH**, and **5 MEDIUM** severity issues in the SafeHedgeFund smart contract system. Immediate attention is required for the critical issues, particularly the infinite recursion bug and decimal handling problems.

---

## CRITICAL SEVERITY ISSUES

### CRITICAL-1: Infinite Recursion in `_burn()` Wrapper Function
**Location:** `SafeHedgeFundVault.sol:635-637`
**Severity:** CRITICAL

**Description:**
```solidity
function _burn(address user, uint256 shares) internal {
    _burn(user, shares);  // ❌ Calls itself infinitely
}
```

The internal `_burn` wrapper function calls itself recursively instead of calling the parent ERC20's `_burn` function. This will cause a stack overflow and transaction failure whenever burning is attempted.

**Impact:**
- **All redemptions will fail** (line 256 calls `_burn`)
- **All emergency withdrawals will fail** (line 122 in EmergencyManager calls burn callback)
- **All cancellations will fail** (QueueManager cancellations rely on this)
- **Contract is completely broken for any withdraw functionality**

**Recommended Fix:**
```solidity
function _burn(address user, uint256 shares) internal {
    super._burn(user, shares);  // Call parent ERC20._burn
}
```

**OR** remove this wrapper entirely and call `super._burn` directly where needed.

---

### CRITICAL-2: Hardcoded Decimal Offset Breaks Multi-Token Support
**Location:** `FeeManager.sol:346-352, 153, 207`
**Severity:** CRITICAL

**Description:**
```solidity
function _getDecimalOffset() internal pure returns (uint8) {
    // For now, assume standard 6 decimal tokens (USDC/USDT) - offset of 12
    return 12;  // ❌ Hardcoded assumption
}
```

The FeeManager library hardcodes a decimal offset of 12, assuming all base tokens have 6 decimals. However, the vault constructor accepts tokens with up to 18 decimals.

**Impact:**
- **Fee calculations will be catastrophically wrong** for non-6-decimal tokens
- For 18-decimal tokens (DAI, WETH): fees will be 1 trillion times too large
- For 8-decimal tokens (WBTC): fees will be 10,000 times too large
- **Complete loss of funds or contract bricking**

**Locations Affected:**
1. Line 153: `accrueEntranceFee` - entrance fees calculated incorrectly
2. Line 207: `payoutFees` - fee payouts calculated incorrectly

**Recommended Fix:**
Pass the `DECIMAL_FACTOR` or `baseDecimals` from the vault to the FeeManager functions, or refactor to use the function pointers for normalization instead of manual calculation.

---

### CRITICAL-3: Shares Burned Before Redemption Queuing
**Location:** `SafeHedgeFundVault.sol:256-268`
**Severity:** CRITICAL

**Description:**
```solidity
// Burn shares first (state change before external calls)
_burn(msg.sender, shares);  // Line 256

if (autoPayoutRedemptions) {
    (bool ok, uint256 paid) = _payout(msg.sender, shares, nav);
    if (ok) {
        emit Redeemed(msg.sender, shares, paid);
        return;  // ✓ Success, shares burned correctly
    } else {
        emit RedemptionAutoPayoutFailed(msg.sender, shares, "Safe payout failed");
    }
}

queueStorage.queueRedemption(msg.sender, shares, nav, minAmountOut);  // Line 268
```

**Issue:** Shares are burned at line 256, but if `queueRedemption` at line 268 fails (e.g., queue full, user limit exceeded), the transaction reverts BUT if there's any issue with how the queue handles the already-burned shares, users lose their shares without getting queued for redemption.

**Impact:**
- If `queueRedemption` reverts, shares are already burned in the current transaction (which will revert)
- However, if there's a non-reverting failure path in queue logic, shares could be lost
- Currently mitigated by revert behavior, but risky pattern

**Recommended Fix:**
Only burn shares after successful queueing:
```solidity
if (autoPayoutRedemptions) {
    (bool ok, uint256 paid) = _payout(msg.sender, shares, nav);
    if (ok) {
        _burn(msg.sender, shares);
        emit Redeemed(msg.sender, shares, paid);
        return;
    }
}

_burn(msg.sender, shares);
queueStorage.queueRedemption(msg.sender, shares, nav, minAmountOut);
```

---

### CRITICAL-4: Integer Overflow Check Placed After Increment
**Location:** `QueueManager.sol:86-87, 117-118`
**Severity:** CRITICAL

**Description:**
```solidity
// Fixed MEDIUM #8: Added overflow protection
// While unlikely to overflow, adding check for safety
if (qs.depositQueueTail == type(uint256).max) revert QueueOverflow();
qs.depositQueueTail++;  // ❌ Check is AFTER the increment would overflow
```

The overflow check happens at line 86, but the increment happens at line 87. If `depositQueueTail` is `type(uint256).max - 1`, it will increment to `max`, pass the check, then the NEXT call will increment from `max` to `0` (overflow), bypassing the check entirely.

**Even worse:** If `depositQueueTail` equals `type(uint256).max`, the check at line 86 will revert, but this is BEFORE the increment. On the NEXT call, `depositQueueTail` would overflow.

**Impact:**
- Queue tail wraps to 0, corrupting queue indices
- Queue head and tail comparison becomes invalid
- Deposit/redemption queue completely breaks
- Funds can be lost or double-spent

**Recommended Fix:**
```solidity
if (qs.depositQueueTail >= type(uint256).max) revert QueueOverflow();
qs.depositQueueTail++;
```

**Better Fix:** Since this is Solidity 0.8.24, overflow is impossible (will revert automatically). Remove the manual check entirely or add a practical limit:
```solidity
if (qs.depositQueueTail >= type(uint256).max - 1000) revert QueueOverflow();
qs.depositQueueTail++;
```

---

### CRITICAL-5: AUM Tracking Divergence
**Location:** `SafeHedgeFundVault.sol:701-705`
**Severity:** CRITICAL

**Description:**
The contract has two different AUM calculation methods:
1. **Official AUM**: `feeStorage.aum` - updated by `updateAum()` (line 275-286)
2. **Calculated AUM**: `getTotalAum()` - calculated from token balances (line 702-704)

```solidity
function getTotalAum() public view returns (uint256) {
    uint256 onChain = baseToken.balanceOf(safeWallet) + baseToken.balanceOf(address(this));
    uint256 fees = _denormalize(feeStorage.totalAccruedFees());
    return onChain >= fees ? onChain - fees : 0;
}
```

**Issue:** Emergency mode uses `getTotalAum()` (line 450, 455, 468) which can diverge significantly from `feeStorage.aum`. The Safe wallet could have sent funds elsewhere, making `getTotalAum()` lower than the official AUM.

**Impact:**
- Emergency withdrawals calculated on incorrect AUM
- Users might get less than entitled in emergency mode
- `checkEmergencyThreshold` might trigger incorrectly

**Recommended Fix:**
Use `feeStorage.aum` consistently, or clearly document that `getTotalAum()` is for "on-chain available" vs "official AUM".

---

### CRITICAL-6: No Input Validation on AUM Update
**Location:** `SafeHedgeFundVault.sol:275-286`
**Severity:** CRITICAL
**Note:** Acknowledged in code as "Issue #13 (Missing Input Validation) intentionally not fixed per user request"

**Description:**
```solidity
function updateAum(uint256 newAum) external onlyRole(AUM_UPDATER_ROLE) {
    uint256 onChain = _getTotalOnChainLiquidity();
    (uint256 adjustedAum, uint256 newNav) = feeStorage.accrueFeesOnAumUpdate(
        newAum,
        totalSupply(),
        onChain,
        _normalize,
        _denormalize
    );
    emit AumUpdated(adjustedAum, newNav);
}
```

**Issue:** While `accrueFeesOnAumUpdate` checks `newAum >= onChainLiquidity` (FeeManager.sol:86), there's no upper bound validation. A compromised AUM_UPDATER can set arbitrarily high AUM values.

**Impact:**
- Inflated NAV allows attacker to mint excessive shares
- Deflated NAV (to just above onChain) steals value from existing holders
- Performance fees can be manipulated

**Recommended Fix:**
Add reasonableness checks:
```solidity
uint256 lastAum = feeStorage.aum;
if (newAum > lastAum * 2) revert AumChangeToLarge(); // Max 2x increase
if (newAum < lastAum / 2) revert AumChangeTooLarge(); // Max 50% decrease
```

---

## HIGH SEVERITY ISSUES

### HIGH-1: Emergency Withdrawal Accounting Mismatch
**Location:** `EmergencyManager.sol:112-123`
**Severity:** HIGH

**Description:**
```solidity
uint256 entitlement = (shares * es.emergencySnapshot) / totalSupply;
uint256 payoutAmount = available >= remainingClaims
    ? entitlement
    : (entitlement * available) / remainingClaims;

// Update state
burn(msg.sender, shares);
es.emergencyTotalWithdrawn += entitlement;  // ❌ Tracks entitlement, not actual payout

// Payout
payout(msg.sender, payoutAmount);  // Actual payout might be less
```

**Issue:** `emergencyTotalWithdrawn` tracks the full `entitlement`, but users might receive only `payoutAmount` (which could be less in underfunded scenarios). This means `remainingClaims` calculation is incorrect for subsequent withdrawals.

**Impact:**
- Late withdrawers get more than they should if early withdrawers got partial payouts
- Or late withdrawers get nothing when there are still funds
- Pro-rata distribution is broken

**Recommended Fix:**
```solidity
es.emergencyTotalWithdrawn += payoutAmount;  // Track actual payouts
```

---

### HIGH-2: Queue Cancellation Gas Bomb
**Location:** `QueueManager.sol:239-260, 262-283`
**Severity:** HIGH

**Description:**
```solidity
function cancelDeposits(
    QueueStorage storage qs,
    address user,
    uint256 maxCancellations,
    function(address, uint256) external transferBack
) external returns (uint256 cancelled) {
    if (qs.pendingDeposits[user] == 0) revert NoPending();

    uint256 count = 0;
    for (uint256 i = qs.depositQueueHead; i < qs.depositQueueTail && count < maxCancellations; i++) {
        // Loops through potentially ENTIRE queue
    }
}
```

**Issue:** If a user has deposits scattered throughout a large queue (e.g., positions at indices 0, 500, 1000), the loop must iterate through all 1000+ indices to find and cancel them.

**Impact:**
- Function can run out of gas with large queue
- User cannot cancel their deposits
- Funds stuck in queue
- DoS for cancellation functionality

**Recommended Fix:**
Maintain a per-user mapping of queue indices:
```solidity
mapping(address => uint256[]) userDepositIndices;
```

---

### HIGH-3: Decimal Normalization Inconsistency
**Location:** Throughout FeeManager.sol
**Severity:** HIGH

**Description:**
The FeeManager uses three different approaches to decimal handling:
1. Function pointers from vault (lines 82, 84) - ✓ Correct
2. Hardcoded offset (lines 153, 207) - ❌ Wrong
3. Assumes 18-decimal inputs (line 106) - ⚠️ Context-dependent

**Impact:**
- Entrance and exit fees calculated incorrectly for non-6-decimal tokens
- Inconsistent internal accounting
- Potential loss of funds or bricking

**Recommended Fix:**
Always use the function pointers passed from the vault. Remove `_getDecimalOffset()` entirely.

---

## MEDIUM SEVERITY ISSUES

### MEDIUM-1: NAV Staleness Not Checked in Emergency Mode
**Location:** `SafeHedgeFundVault.sol:445-476`
**Severity:** MEDIUM

**Description:**
Emergency functions like `triggerEmergency()`, `checkEmergencyThreshold()`, and `emergencyWithdraw()` use `getTotalAum()` which relies on current token balances, but they don't check if the official AUM is stale.

**Impact:**
- Emergency mode triggered based on stale data
- Withdrawals calculated on outdated AUM
- Users get incorrect amounts

**Recommended Fix:**
Add AUM freshness check before entering emergency mode.

---

### MEDIUM-2: Auto-Process Failures Not Tracked
**Location:** `SafeHedgeFundVault.sol:520-558`
**Severity:** MEDIUM

**Description:**
When auto-processing fails (e.g., slippage, zero shares), the deposit remains in the queue but is not marked as "failed". The next batch processor might process it successfully, but there's no tracking of auto-process failures.

**Impact:**
- User deposits sit in queue longer than expected
- No way to query which deposits failed auto-process
- Hard to debug issues

**Recommended Fix:**
Add a `failedAutoProcess` flag to QueueItem struct.

---

### MEDIUM-3: Performance Fee Calculated on Snapshot NAV
**Location:** `FeeManager.sol:106-109`
**Severity:** MEDIUM

**Description:**
```solidity
uint256 tempNav = (normalize(newAum) * 1e18) / totalSupply;
if (tempNav > fs.highWaterMark && fs.performanceFeeBps > 0) {
    perfFee = ((tempNav - fs.highWaterMark) * fs.performanceFeeBps / FEE_DENOMINATOR) * totalSupply / 1e18;
    fs.accruedPerformanceFees += perfFee;
}
```

Performance fees are accrued based on NAV BEFORE the fees are deducted. This means the NAV calculated at line 126 will be lower than `tempNav`, but the HWM is updated based on the post-fee NAV.

**Impact:**
- Performance fees might be over-charged
- High water mark logic could be incorrect

**Recommended Fix:**
Calculate performance fees iteratively or adjust HWM update logic.

---

### MEDIUM-4: Config Proposal Can Be Front-Run
**Location:** `ConfigManager.sol:81-108`
**Severity:** MEDIUM

**Description:**
When an admin creates a proposal, anyone watching the mempool can see the parameters and create their own proposal with different parameters. While only admins can create proposals, if there are multiple admins, they could front-run each other.

**Impact:**
- Proposal conflicts
- Potential governance manipulation if multiple admins

**Recommended Fix:**
Use commit-reveal scheme or proposal queue.

---

### MEDIUM-5: No Emergency Exit for Proposal System
**Location:** `ConfigManager.sol`
**Severity:** MEDIUM

**Description:**
If a malicious proposal gets through the timelock, there's no way to stop it except creating a new proposal with the old values, which also requires a timelock wait.

**Impact:**
- Malicious config changes can't be emergency-stopped
- Time window of vulnerability

**Recommended Fix:**
Add emergency cancel function for GUARDIAN_ROLE.

---

## LOW SEVERITY ISSUES

### LOW-1: Event Parameter Order Inconsistency
Multiple events have inconsistent parameter ordering.

### LOW-2: Missing Zero-Address Checks
Several admin functions don't check for zero addresses in updates.

### LOW-3: Gas Inefficiency in Queue Cleanup
Queue cleanup could be optimized with batch operations.

### LOW-4: No Maximum Fee Caps
While ConfigManager has MAX constants, fees could still be set very high.

### LOW-5: Reentrancy Guards Not on All External Functions
Some view functions that make external calls lack reentrancy protection.

---

## RECOMMENDATIONS

### Immediate Actions Required:
1. Fix CRITICAL-1: Infinite recursion in `_burn()`
2. Fix CRITICAL-2: Remove hardcoded decimal offset
3. Fix CRITICAL-4: Fix overflow check order
4. Review and fix CRITICAL-3: Redemption burn ordering

### High Priority:
1. Fix emergency withdrawal accounting (HIGH-1)
2. Optimize queue cancellation (HIGH-2)
3. Standardize decimal handling (HIGH-3)

### Testing Recommendations:
1. Add fuzzing tests for decimal handling with various token decimals (6, 8, 18)
2. Test emergency withdrawal under underfunded scenarios
3. Test queue operations with maximum queue sizes
4. Test all functions with boundary values (max uint256, zero, etc.)

---

## CONCLUSION

This contract system has several critical bugs that must be fixed before deployment. The infinite recursion bug (CRITICAL-1) makes the contract completely non-functional for withdrawals. The decimal handling issues (CRITICAL-2, HIGH-3) would cause catastrophic fund loss for non-USDC/USDT tokens.

**Recommendation: DO NOT DEPLOY until all CRITICAL issues are resolved and HIGH issues are reviewed.**
