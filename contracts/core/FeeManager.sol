// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title FeeManager
 * @author Gnosis Safe Hedge Fund Team
 * @notice Library managing all fee calculations, accruals, and high water mark (HWM) logic
 * @dev This is the economic engine of the hedge fund. It handles:
 *      - Management fees (annual % of AUM)
 *      - Performance fees (% of profits above HWM)
 *      - Entrance/Exit fees (one-time fees on deposits/withdrawals)
 *      - High Water Mark tracking (ensures performance fees only on new profits)
 *      - Fee payouts with liquidity requirements
 *
 * ARCHITECTURE ROLE:
 * - Protects fund manager's compensation model
 * - Ensures fair fee calculation (18-decimal normalization for all tokens)
 * - Prevents fee extraction during low liquidity periods
 * - Tracks performance relative to all-time high (HWM)
 * - Manages configurable HWM reset after drawdowns
 *
 * KEY CONCEPTS:
 * - All fees are accrued in 18-decimal normalized format internally
 * - Fees are deducted from AUM before NAV calculation
 * - Performance fees only charged on gains above previous high
 * - HWM can reset after significant drawdown + recovery period
 * - Target liquidity must be met before fee payouts
 */
library FeeManager {
    using SafeERC20 for IERC20;

    uint256 private constant FEE_DENOMINATOR = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365.25 days;
    uint256 private constant MAX_TIME_DELTA = 365 days;

    /**
     * @notice Central storage for all fee-related state
     * @dev Uses 18-decimal normalization for cross-token compatibility
     *
     * @param managementFeeBps Annual management fee in basis points (100 = 1% per year)
     * @param performanceFeeBps Performance fee in basis points (2000 = 20% of profits)
     * @param entranceFeeBps One-time fee on deposits (100 = 1%)
     * @param exitFeeBps One-time fee on redemptions (100 = 1%)
     * @param accruedManagementFees Accumulated mgmt fees (18 decimals, not yet paid out)
     * @param accruedPerformanceFees Accumulated perf fees (18 decimals)
     * @param accruedEntranceFees Accumulated entrance fees (18 decimals)
     * @param accruedExitFees Accumulated exit fees (18 decimals)
     * @param highWaterMark Highest NAV ever reached (18 decimals) - performance fees only above this
     * @param lowestNavInDrawdown Lowest NAV during current drawdown period
     * @param recoveryStartTime When recovery from drawdown began (0 if not in recovery)
     * @param hwmDrawdownPct Drawdown % threshold to trigger reset tracking (e.g., 6000 = 60%)
     * @param hwmRecoveryPct Recovery % above lowest NAV to start reset timer (e.g., 500 = 5%)
     * @param hwmRecoveryPeriod Time NAV must stay recovered before HWM resets (e.g., 90 days)
     * @param aum Current assets under management after fees (native decimals)
     * @param aumTimestamp Last time AUM was updated
     * @param navPerShare Current NAV per share (18 decimals)
     * @param targetLiquidityBps Minimum liquidity % required for fee payouts (500 = 5% of AUM)
     * @param decimalFactor Conversion factor (10^(18-baseDecimals)) for normalization
     */
    struct FeeStorage {
        uint256 managementFeeBps;
        uint256 performanceFeeBps;
        uint256 entranceFeeBps;
        uint256 exitFeeBps;

        uint256 accruedManagementFees;
        uint256 accruedPerformanceFees;
        uint256 accruedEntranceFees;
        uint256 accruedExitFees;

        uint256 highWaterMark;
        uint256 lowestNavInDrawdown;
        uint256 recoveryStartTime;

        uint256 hwmDrawdownPct;
        uint256 hwmRecoveryPct;
        uint256 hwmRecoveryPeriod;

        uint256 aum;
        uint256 aumTimestamp;
        uint256 navPerShare;

        uint256 targetLiquidityBps;

        uint256 decimalFactor;
    }

    event FeesAccrued(uint256 mgmt, uint256 perf, uint256 entrance, uint256 exit);
    event FeesPaid(uint256 amount);
    event FeePaymentPartial(uint256 vaultPaid, uint256 safeFailed);
    event HWMReset(uint256 oldHWM, uint256 newHWM);

    error NoFees();
    error InsufficientLiquidity();
    error AUMStale();
    error AUMZero();
    error AUMBelowOnChain();

    /**
     * @notice Updates AUM and accrues time-based fees (management + performance)
     * @dev CRITICAL FUNCTION: Called whenever off-chain AUM is reported. This is where
     *      the fund's economic model comes together.
     *
     * WHY IT'S IMPORTANT:
     * - Ensures fees are continuously accrued as AUM grows
     * - Updates NAV which affects all deposits/redemptions
     * - Tracks high water mark for fair performance fee calculation
     * - Validates new AUM is >= on-chain liquidity (prevents fraud)
     * - Prevents stale AUM from being used (max 3 days gap)
     *
     * FLOW:
     * 1. Validate new AUM (non-zero, >= on-chain balance)
     * 2. Accrue management fees (time-based)
     * 3. Accrue performance fees (if above HWM)
     * 4. Deduct ALL accrued fees from AUM
     * 5. Calculate new NAV per share
     * 6. Update high water mark logic
     *
     * @param fs Fee storage reference
     * @param newAum Total AUM reported by off-chain keeper (includes vault + Safe balances + off-chain positions)
     * @param totalSupply Current total share supply
     * @param onChainLiquidity Sum of vault + Safe base token balances
     * @param normalize Function to convert native decimals to 18 decimals
     * @param denormalize Function to convert 18 decimals to native decimals
     * @return adjustedAum AUM after deducting all accrued fees
     * @return newNavPerShare Updated NAV per share (18 decimals)
     */
    function accrueFeesOnAumUpdate(
        FeeStorage storage fs,
        uint256 newAum,
        uint256 totalSupply,
        uint256 onChainLiquidity,
        function(uint256) view returns (uint256) normalize,
        function(uint256) view returns (uint256) denormalize
    ) internal returns (uint256 adjustedAum, uint256 newNavPerShare) {
        if (newAum == 0) revert AUMZero();
        if (newAum < onChainLiquidity) revert AUMBelowOnChain();

        (uint256 mgmtFee, uint256 perfFee, uint256 grossNav) =
            _accrueFees(fs, newAum, totalSupply, normalize);

        adjustedAum = newAum - denormalize(
            fs.accruedManagementFees + fs.accruedPerformanceFees +
            fs.accruedEntranceFees + fs.accruedExitFees
        );
        if (adjustedAum > newAum) adjustedAum = 0;

        fs.aum = adjustedAum;
        fs.aumTimestamp = block.timestamp;
        newNavPerShare = totalSupply > 0
            ? (normalize(adjustedAum) * 1e18) / totalSupply
            : 1e18;

        fs.navPerShare = newNavPerShare;
        // B-MED-1: HWM tracks the gross (pre-fee) NAV that we just charged
        // perf fee against, NOT the post-fee NAV. Pre-fix: HWM was bumped
        // to newNavPerShare (which is gross minus fees just charged), so
        // next update would re-charge perf fee on the spread between
        // newNavPerShare and the next gross NAV — even when no real
        // performance had occurred. The supply==0 case still seeds HWM at
        // par (1e18) so the first depositor doesn't get hit with a perf
        // fee on the entire opening NAV.
        _updateHighWaterMark(fs, totalSupply > 0 ? grossNav : newNavPerShare);

        if (mgmtFee > 0 || perfFee > 0) {
            emit FeesAccrued(mgmtFee, perfFee, 0, 0);
        }
    }

    /**
     * @notice Internal function to calculate and accrue time-based fees
     * @dev Management fees accrue continuously based on time elapsed.
     *      Performance fees only accrue when NAV exceeds high water mark.
     *
     * WHY IT'S IMPORTANT:
     * - Management fee compensates fund manager regardless of performance
     * - Performance fee aligns manager incentives with fund growth
     * - Prevents charging performance fees on same gains twice (via HWM)
     * - Caps time delta to prevent huge fee spikes after long periods
     *
     * CALCULATION DETAILS:
     * - Management fee = (NAV * fee_bps / 10000) * (time_elapsed / year) * totalSupply
     * - Performance fee = (NAV - HWM) * fee_bps / 10000 * totalSupply
     * - Both are stored in 18-decimal format
     *
     * @param fs Fee storage reference
     * @param newAum New total AUM being reported
     * @param totalSupply Current share supply
     * @param normalize Function to convert to 18 decimals
     * @return mgmtFee Management fee accrued (18 decimals)
     * @return perfFee Performance fee accrued (18 decimals)
     */
    function _accrueFees(
        FeeStorage storage fs,
        uint256 newAum,
        uint256 totalSupply,
        function(uint256) view returns (uint256) normalize
    ) private returns (uint256 mgmtFee, uint256 perfFee, uint256 grossNav) {
        if (totalSupply == 0) return (0, 0, 0);

        uint256 timeDelta = block.timestamp - fs.aumTimestamp;
        if (timeDelta > MAX_TIME_DELTA) timeDelta = MAX_TIME_DELTA;
        // grossNav is computed regardless of timeDelta — the caller uses
        // it to update HWM, which must reflect the current gross NAV
        // even on rapid back-to-back AUM updates.
        grossNav = (normalize(newAum) * 1e18) / totalSupply;

        if (timeDelta > 3 days) return (0, 0, grossNav);

        if (fs.managementFeeBps > 0) {
            mgmtFee = ((fs.navPerShare * fs.managementFeeBps / FEE_DENOMINATOR) * timeDelta * totalSupply)
                / SECONDS_PER_YEAR / 1e18;
            fs.accruedManagementFees += mgmtFee;
        }

        if (grossNav > fs.highWaterMark && fs.performanceFeeBps > 0) {
            perfFee = ((grossNav - fs.highWaterMark) * fs.performanceFeeBps * totalSupply)
                / FEE_DENOMINATOR / 1e18;
            fs.accruedPerformanceFees += perfFee;
        }
    }

    // ── Fee preview/record split ────────────────────────────────────────
    //
    // Why two functions instead of one mutating "accrue":
    //
    // The previous design had a single mutating accrueEntranceFee/accrueExitFee
    // that the caller invoked BEFORE the slippage / zero-shares / Safe-call
    // success checks. If those checks failed, the function returned without
    // marking the queue item processed — but the fee was already on the
    // ledger. On retry, the same item would accrue the fee again. For the
    // exit fee path it was even worse: redeem() called accrueExitFee at the
    // top, and _payout called it AGAIN when the actual transfer happened, so
    // every redemption was billed at minimum 2× and up to (1+N)× under
    // retries (B-CRIT-1, B-CRIT-2 in docs/AUDIT_REPORT.md).
    //
    // Splitting into a pure preview + a post-success record lets callers
    // size the slippage check and the share calculation off the same numbers
    // the user sees, then commit the fee to the ledger exactly once, only
    // after the operation is irreversibly successful.

    /**
     * @notice Pure preview of an entrance fee. Does NOT mutate state.
     * @param fs Fee storage reference
     * @param depositAmount Deposit amount in native decimals
     * @return netAmount Native decimals after fee
     * @return feeNative Fee in native decimals (caller passes this to recordEntranceFee on success)
     */
    function previewEntranceFee(
        FeeStorage storage fs,
        uint256 depositAmount
    ) external view returns (uint256 netAmount, uint256 feeNative) {
        feeNative = (depositAmount * fs.entranceFeeBps) / FEE_DENOMINATOR;
        netAmount = depositAmount - feeNative;
    }

    /**
     * @notice Commits a previously-previewed entrance fee to the ledger.
     * @dev Caller MUST have validated the operation will succeed before
     *      calling this. Idempotency is the caller's responsibility.
     * @param fs Fee storage reference
     * @param feeNative Fee amount in native decimals (from previewEntranceFee)
     */
    function recordEntranceFee(
        FeeStorage storage fs,
        uint256 feeNative
    ) external {
        if (feeNative > 0) {
            uint256 feeNormalized = feeNative * fs.decimalFactor;
            fs.accruedEntranceFees += feeNormalized;
            emit FeesAccrued(0, 0, feeNormalized, 0);
        }
    }

    /**
     * @notice Pure preview of an exit fee. Does NOT mutate state.
     * @param fs Fee storage reference
     * @param grossAmount Gross redemption value in 18-decimal normalized form
     * @return netAmount Net normalized amount after fee
     * @return feeNormalized Fee in 18-dec normalized form (pass to recordExitFee on success)
     */
    function previewExitFee(
        FeeStorage storage fs,
        uint256 grossAmount
    ) external view returns (uint256 netAmount, uint256 feeNormalized) {
        feeNormalized = (grossAmount * fs.exitFeeBps) / FEE_DENOMINATOR;
        netAmount = grossAmount - feeNormalized;
    }

    /**
     * @notice Commits a previously-previewed exit fee to the ledger.
     * @param fs Fee storage reference
     * @param feeNormalized Fee in 18-dec normalized form (from previewExitFee)
     */
    function recordExitFee(
        FeeStorage storage fs,
        uint256 feeNormalized
    ) external {
        if (feeNormalized > 0) {
            fs.accruedExitFees += feeNormalized;
            emit FeesAccrued(0, 0, 0, feeNormalized);
        }
    }

    /**
     * @notice Pays out all accrued fees to fee recipient
     * @dev CRITICAL: This is how fund manager gets paid. Includes safety checks.
     *
     * WHY IT'S IMPORTANT:
     * - Final step in fee collection process
     * - Requires minimum liquidity to prevent fund becoming illiquid
     * - Tries vault first, then Safe wallet for additional liquidity
     * - Handles partial payments if not enough liquidity available
     * - Resets accrued fees proportionally based on amount paid
     *
     * SAFETY FEATURES:
     * - Checks target liquidity threshold before allowing payout
     * - Attempts Safe transaction gracefully (doesn't revert if Safe call fails)
     * - Emits events for partial payments for monitoring
     * - Only pays what's actually available (caps at total on-chain balance)
     *
     * @param fs Fee storage reference
     * @param baseToken Base token contract
     * @param feeRecipient Address to receive fee payment
     * @param safeWallet Safe wallet address for additional liquidity
     * @param isModuleEnabled Function to check if vault is enabled module on Safe
     * @param denormalize Function to convert 18 decimals to native
     */
    function payoutFees(
        FeeStorage storage fs,
        IERC20 baseToken,
        address feeRecipient,
        address safeWallet,
        function() view returns (bool) isModuleEnabled,
        function(uint256) view returns (uint256) denormalize
    ) internal {
        uint256 totalAccrued = fs.accruedManagementFees + fs.accruedPerformanceFees +
            fs.accruedEntranceFees + fs.accruedExitFees;

        if (totalAccrued == 0) revert NoFees();
        if (!_isTargetLiquidityMet(fs, baseToken, safeWallet)) revert InsufficientLiquidity();

        uint256 totalNative = denormalize(totalAccrued);
        uint256 totalAvailable = baseToken.balanceOf(address(this)) + baseToken.balanceOf(safeWallet);
        uint256 toPay = totalNative > totalAvailable ? totalAvailable : totalNative;

        if (toPay == 0) revert NoFees();

        _resetFeesProportionally(fs, toPay, totalAccrued);

        _executeFeePayout(baseToken, feeRecipient, safeWallet, toPay, isModuleEnabled);

        emit FeesPaid(toPay);
    }

    /**
     * @notice Resets accrued fees proportionally based on amount being paid out
     * @dev If paying 50% of fees, reduces all accrued amounts by 50%
     *
     * WHY IT'S IMPORTANT:
     * - Maintains correct accounting when only partial fees can be paid
     * - Ensures each fee type is reduced proportionally
     * - Allows tracking of unpaid fees for future payout
     *
     * @param fs Fee storage reference
     * @param toPay Amount being paid in native decimals
     * @param totalAccrued Total fees accrued in 18 decimals
     */
    function _resetFeesProportionally(
        FeeStorage storage fs,
        uint256 toPay,
        uint256 totalAccrued
    ) private {
        uint256 paidIn18 = toPay * fs.decimalFactor;

        if (paidIn18 >= totalAccrued) {
            fs.accruedManagementFees = 0;
            fs.accruedPerformanceFees = 0;
            fs.accruedEntranceFees = 0;
            fs.accruedExitFees = 0;
        } else {
            uint256 remaining = 1e18 - (paidIn18 * 1e18) / totalAccrued;
            fs.accruedManagementFees = (fs.accruedManagementFees * remaining) / 1e18;
            fs.accruedPerformanceFees = (fs.accruedPerformanceFees * remaining) / 1e18;
            fs.accruedEntranceFees = (fs.accruedEntranceFees * remaining) / 1e18;
            fs.accruedExitFees = (fs.accruedExitFees * remaining) / 1e18;
        }
    }

    /**
     * @notice Executes the actual fee payment transfer
     * @dev Tries vault balance first, then Safe wallet if needed
     *
     * WHY IT'S IMPORTANT:
     * - Maximizes chance of successful fee payout
     * - Uses vault funds first (gas efficient)
     * - Falls back to Safe only if needed
     * - Emits event if Safe portion fails (for monitoring)
     *
     * @param baseToken Base token contract
     * @param feeRecipient Address receiving fees
     * @param safeWallet Safe wallet address
     * @param toPay Total amount to pay
     * @param isModuleEnabled Function to check module status
     */
    function _executeFeePayout(
        IERC20 baseToken,
        address feeRecipient,
        address safeWallet,
        uint256 toPay,
        function() view returns (bool) isModuleEnabled
    ) private {
        uint256 vaultBal = baseToken.balanceOf(address(this));

        if (vaultBal >= toPay) {
            baseToken.safeTransfer(feeRecipient, toPay);
            return;
        }

        if (vaultBal > 0) baseToken.safeTransfer(feeRecipient, vaultBal);

        uint256 remaining = toPay - vaultBal;
        if (remaining > 0 && isModuleEnabled()) {
            (bool ok,) = safeWallet.call(
                abi.encodeWithSignature(
                    "execTransactionFromModule(address,uint256,bytes,uint8)",
                    address(baseToken), 0,
                    abi.encodeWithSelector(IERC20.transfer.selector, feeRecipient, remaining),
                    0
                )
            );
            if (!ok) {
                emit FeePaymentPartial(vaultBal, remaining);
            }
        }
    }

    /**
     * @notice Returns total of all accrued fees
     * @dev View function for external queries and UI display
     *
     * WHY IT'S IMPORTANT:
     * - Shows total unpaid fees owed to fund manager
     * - Used in NAV calculation (fees reduce AUM)
     * - Helps monitor fee accrual rate
     *
     * @param fs Fee storage reference
     * @return Sum of all fee types in 18 decimals
     */
    function totalAccruedFees(FeeStorage storage fs) external view returns (uint256) {
        return fs.accruedManagementFees +
            fs.accruedPerformanceFees +
            fs.accruedEntranceFees +
            fs.accruedExitFees;
    }

    /**
     * @notice Returns detailed breakdown of accrued fees by type
     * @dev Useful for UI display and transparency
     *
     * WHY IT'S IMPORTANT:
     * - Provides transparency on fee composition
     * - Helps users understand what they're paying for
     * - Enables monitoring of each fee stream
     *
     * @param fs Fee storage reference
     * @return mgmt Management fees accrued
     * @return perf Performance fees accrued
     * @return entrance Entrance fees accrued
     * @return exit Exit fees accrued
     * @return total Sum of all fees (18 decimals)
     * @return totalNative Placeholder (calculated by caller using denormalize)
     */
    function accruedFeesBreakdown(FeeStorage storage fs)
        external
        view
        returns (
            uint256 mgmt,
            uint256 perf,
            uint256 entrance,
            uint256 exit,
            uint256 total,
            uint256 totalNative
        )
    {
        mgmt = fs.accruedManagementFees;
        perf = fs.accruedPerformanceFees;
        entrance = fs.accruedEntranceFees;
        exit = fs.accruedExitFees;
        total = mgmt + perf + entrance + exit;
        totalNative = 0;
    }

    /**
     * @notice Checks if target liquidity requirement is met
     * @dev External wrapper for internal check function
     *
     * WHY IT'S IMPORTANT:
     * - Prevents fee extraction when fund is illiquid
     * - Protects users from being unable to redeem
     * - Ensures enough liquidity for normal operations
     *
     * @param fs Fee storage reference
     * @param baseToken Base token contract
     * @param safeWallet Safe wallet address
     * @return true if liquidity >= target threshold
     */
    function isTargetLiquidityMet(
        FeeStorage storage fs,
        IERC20 baseToken,
        address safeWallet
    ) external view returns (bool) {
        return _isTargetLiquidityMet(fs, baseToken, safeWallet);
    }

    /**
     * @notice Updates high water mark based on current NAV
     * @dev COMPLEX LOGIC: Manages HWM with configurable drawdown recovery
     *
     * WHY IT'S IMPORTANT:
     * - Prevents charging performance fees on recovered losses
     * - Fair to investors: only pay fees on true new profits
     * - Configurable reset allows recovery from market crashes
     * - Tracks drawdown and recovery periods transparently
     *
     * LOGIC FLOW:
     * 1. If NAV > HWM: Set new HWM, reset drawdown tracking
     * 2. If NAV drops below drawdown threshold: Start tracking lowest NAV
     * 3. If NAV recovers above recovery threshold: Start recovery timer
     * 4. If NAV stays recovered for full period: Reset HWM to current NAV
     * 5. If NAV drops again during recovery: Reset timer
     *
     * EXAMPLE (with 60% drawdown, 5% recovery, 90 days):
     * - HWM at $100, drops to $35 (65% drawdown) -> Start tracking
     * - NAV recovers to $36.75 (5% above $35) -> Start 90-day timer
     * - If stays above $36.75 for 90 days -> Reset HWM to current NAV
     * - If drops below $36.75 -> Reset timer, must recover again
     *
     * @param fs Fee storage reference
     * @param currentNav Current NAV per share (18 decimals)
     */
    function _updateHighWaterMark(FeeStorage storage fs, uint256 currentNav) internal {
        if (currentNav > fs.highWaterMark) {
            emit HWMReset(fs.highWaterMark, currentNav);
            fs.highWaterMark = currentNav;
            fs.lowestNavInDrawdown = 0;
            fs.recoveryStartTime = 0;
            return;
        }

        uint256 drawdownThreshold = fs.highWaterMark * (FEE_DENOMINATOR - fs.hwmDrawdownPct) / FEE_DENOMINATOR;
        if (currentNav < drawdownThreshold && fs.lowestNavInDrawdown == 0) {
            fs.lowestNavInDrawdown = currentNav;
        }

        if (fs.lowestNavInDrawdown > 0) {
            if (currentNav < fs.lowestNavInDrawdown) {
                fs.lowestNavInDrawdown = currentNav;
                fs.recoveryStartTime = 0;
            }

            uint256 recoveryThreshold = fs.lowestNavInDrawdown * (FEE_DENOMINATOR + fs.hwmRecoveryPct) / FEE_DENOMINATOR;
            if (currentNav >= recoveryThreshold) {
                if (fs.recoveryStartTime == 0) {
                    fs.recoveryStartTime = block.timestamp;
                } else if (block.timestamp >= fs.recoveryStartTime + fs.hwmRecoveryPeriod) {
                    emit HWMReset(fs.highWaterMark, currentNav);
                    fs.highWaterMark = currentNav;
                    fs.lowestNavInDrawdown = 0;
                    fs.recoveryStartTime = 0;
                }
            } else if (fs.recoveryStartTime > 0) {
                fs.recoveryStartTime = 0;
            }
        }
    }

    /**
     * @notice Internal check for liquidity requirement
     * @dev Compares on-chain liquidity to target percentage of AUM
     *
     * WHY IT'S IMPORTANT:
     * - Prevents draining liquidity through fee payments
     * - Ensures users can always redeem
     * - Protects fund operational viability
     *
     * @param fs Fee storage reference
     * @param baseToken Base token contract
     * @param safeWallet Safe wallet address
     * @return true if (vault + Safe balance) >= (AUM * targetLiquidityBps / 10000)
     */
    function _isTargetLiquidityMet(
        FeeStorage storage fs,
        IERC20 baseToken,
        address safeWallet
    ) internal view returns (bool) {
        if (fs.targetLiquidityBps == 0) return true;
        uint256 totalLiq = baseToken.balanceOf(address(this)) + baseToken.balanceOf(safeWallet);
        uint256 required = (fs.aum * fs.targetLiquidityBps) / FEE_DENOMINATOR;
        return totalLiq >= required;
    }

}
