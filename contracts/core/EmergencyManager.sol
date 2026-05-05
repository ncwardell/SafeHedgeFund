// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EmergencyManager
 * @author Gnosis Safe Hedge Fund Team
 * @notice Library managing emergency withdrawal functionality for disaster scenarios
 * @dev This is the "circuit breaker" and last resort protection for investors.
 *      Allows users to withdraw their pro-rata share of available on-chain liquidity
 *      when normal fund operations fail or become impossible.
 *
 * ARCHITECTURE ROLE:
 * - Last line of defense if fund manager disappears or Safe keys are lost
 * - Protects users from indefinite lock-up of funds
 * - Fair distribution of available liquidity during crisis
 * - Automatic trigger after prolonged pause or stale AUM
 *
 * TRIGGER CONDITIONS:
 * 1. Manual: Guardian role triggers after pausing contract
 * 2. Automatic: Contract paused for 30+ days
 * 3. Automatic: AUM not updated for 30+ days
 *
 * EMERGENCY WITHDRAWAL MECHANICS:
 * - Snapshot AUM at emergency trigger time
 * - Users burn shares for pro-rata portion of snapshot
 * - Actual payout proportional to available on-chain liquidity
 * - Tracks total withdrawn to prevent over-distribution
 *
 * EXAMPLE:
 * - Fund: $1M AUM, $100K on-chain, 1000 shares total
 * - User: 10 shares (1% of fund)
 * - Entitlement: $10K (1% of $1M)
 * - Available: Only $100K on-chain for all users
 * - Payout: $1K (1% of available $100K)
 *
 * See ARCHITECTURE.md for complete emergency workflow documentation.
 */
library EmergencyManager {
    using SafeERC20 for IERC20;

    uint256 private constant EMERGENCY_THRESHOLD = 30 days;

    /**
     * @notice Storage for emergency mode state
     * @param emergencyMode Whether emergency withdrawals are active
     * @param emergencySnapshot AUM snapshot when emergency triggered (native decimals)
     * @param emergencySnapshotSupply Share supply snapshot at trigger time
     * @param emergencyTotalWithdrawn Sum of ENTITLEMENTS already claimed (native decimals).
     *        Tracking entitlement (not actual payout) is what keeps the
     *        proportional-cut formula self-consistent: available decreases
     *        by `entitlement*scale` each step and remainingClaims decreases
     *        by `entitlement`, so `scale = available/remainingClaims` stays
     *        constant and every withdrawer gets the same fraction.
     * @param pauseTimestamp When contract was paused (for automatic emergency trigger)
     */
    struct EmergencyStorage {
        bool emergencyMode;
        uint256 emergencySnapshot;
        uint256 emergencySnapshotSupply;
        uint256 emergencyTotalWithdrawn;
        uint256 pauseTimestamp;
    }

    event EmergencyToggled(bool enabled);
    event EmergencyRedeemed(address indexed user, uint256 shares, uint256 amount);
    event PayoutFailed(address indexed user, uint256 amount, string reason);

    error NotInEmergency();
    error NoSupply();
    error PayoutExecutionFailed();
    error ModuleNotEnabled();
    error NotPaused();
    error ThresholdNotMet();

    /**
     * @notice Manually triggers emergency mode (Guardian/Admin only)
     * @dev Takes snapshot of current AUM for pro-rata calculations.
     *      Idempotent - safe to call multiple times.
     *
     * WHY IT'S IMPORTANT:
     * - Allows immediate emergency activation if fraud/hack detected
     * - Guardian can act quickly without waiting for automatic trigger
     * - Captures AUM before further deterioration
     *
     * @param es Emergency storage reference
     * @param currentAum Current total AUM to snapshot
     */
    function triggerEmergency(
        EmergencyStorage storage es,
        uint256 currentAum,
        uint256 currentSupply
    ) external {
        if (es.emergencyMode) return;
        es.emergencyMode = true;
        es.emergencySnapshot = currentAum;
        es.emergencySnapshotSupply = currentSupply;
        es.emergencyTotalWithdrawn = 0;
        emit EmergencyToggled(true);
    }

    /**
     * @notice Checks if automatic emergency trigger conditions are met, triggers if so
     * @dev Called by anyone to activate emergency mode after threshold period.
     *      Two trigger conditions (OR logic):
     *      1. Contract paused for 30+ days (fund manager abandoned)
     *      2. AUM not updated for 30+ days (keeper/oracle failure)
     *
     * WHY IT'S IMPORTANT:
     * - Automatic protection doesn't require admin action
     * - Prevents indefinite lock-up if admin disappears
     * - Permissionless - any user can trigger after threshold
     * - Protects against keeper failure or malicious withholding of updates
     *
     * THRESHOLD RATIONALE:
     * - 30 days is long enough to avoid false triggers during holidays
     * - Short enough to provide timely protection
     * - Gives admin time to resolve temporary issues
     *
     * @param es Emergency storage reference
     * @param isPaused Whether contract is currently paused
     * @param currentAum Current AUM for snapshot
     * @param aumTimestamp Timestamp of last AUM update
     */
    function checkEmergencyThreshold(
        EmergencyStorage storage es,
        bool isPaused,
        uint256 currentAum,
        uint256 currentSupply,
        uint256 aumTimestamp
    ) external {
        bool pausedLongEnough = isPaused &&
            block.timestamp >= es.pauseTimestamp + EMERGENCY_THRESHOLD;

        bool aumStaleLongEnough =
            block.timestamp >= aumTimestamp + EMERGENCY_THRESHOLD;

        if (!pausedLongEnough && !aumStaleLongEnough) {
            revert ThresholdNotMet();
        }

        if (es.emergencyMode) return;

        es.emergencyMode = true;
        es.emergencySnapshot = currentAum;
        es.emergencySnapshotSupply = currentSupply;
        es.emergencyTotalWithdrawn = 0;
        emit EmergencyToggled(true);
    }

    /**
     * @notice Exits emergency mode (Admin only)
     * @dev Resets emergency state. Use when crisis is resolved.
     *      Idempotent - safe to call multiple times.
     *
     * WHY IT'S IMPORTANT:
     * - Allows return to normal operations after crisis
     * - Clears emergency snapshot and withdrawal tracking
     * - Enables deposits and normal redemptions again
     *
     * @param es Emergency storage reference
     */
    function exitEmergency(EmergencyStorage storage es) external {
        if (!es.emergencyMode) return;
        es.emergencyMode = false;
        es.emergencySnapshot = 0;
        es.emergencyTotalWithdrawn = 0;
        emit EmergencyToggled(false);
    }

    /**
     * @notice Allows user to emergency withdraw by burning shares
     * @dev CRITICAL FUNCTION: This is how users recover funds in crisis.
     *      Uses function pointers for clean separation of concerns.
     *
     * WHY IT'S IMPORTANT:
     * - User's last resort to recover funds
     * - Fair distribution based on snapshot AUM
     * - Proportional payouts based on available liquidity
     * - Prevents any single user from draining available funds
     *
     * CALCULATION LOGIC:
     * 1. Calculate user's entitlement = (shares / totalSupply) * snapshotAUM
     * 2. Calculate remaining claims = snapshot - total already withdrawn
     * 3. If available >= remaining claims: Pay full entitlement
     * 4. Else: Pay proportionally = entitlement * (available / remaining claims)
     *
     * EXAMPLE:
     * - Snapshot: $1M, Total withdrawn so far: $200K
     * - Remaining claims: $800K
     * - Available now: $100K
     * - User entitled to: $80K (10% of remaining $800K)
     * - User receives: $80K * ($100K / $800K) = $10K
     *
     * @param es Emergency storage reference
     * @param shares Number of shares user is burning
     * @param totalSupply Current total share supply
     * @param currentAum Current available AUM (on-chain balance)
     * @param burn Function pointer to burn shares from user
     * @param payout Function pointer to send tokens to user
     */
    /// @dev Pro-rata withdrawal from the emergency snapshot.
    ///
    /// Entitlement uses the SUPPLY SNAPSHOT (es.emergencySnapshotSupply), not
    /// the live totalSupply. Each successful emergencyWithdraw burns shares,
    /// so the live total drops; if we used the live value, every later
    /// withdrawer would over-claim against a smaller denominator. This was
    /// B-CRIT-3 — the architecture doc said the supply was meant to be
    /// snapshotted; the original code missed it.
    ///
    /// `available` is passed in by the caller and SHOULD be the vault's own
    /// balance (not vault+Safe). In emergency mode we never touch the Safe
    /// (B-HIGH-3), so the available pool is whatever sits in the vault.
    ///
    /// Tracking += entitlement (not payout) is intentional: it keeps
    /// `available/remainingClaims` constant across sequential calls, so
    /// every user ends up with the same proportional cut of the pool.
    function emergencyWithdraw(
        EmergencyStorage storage es,
        uint256 shares,
        uint256 /* unused: kept for callsite compatibility */,
        uint256 available,
        function(address, uint256) internal burn,
        function(address, uint256) internal payout
    ) internal {
        if (!es.emergencyMode) revert NotInEmergency();
        if (shares == 0 || es.emergencySnapshotSupply == 0) revert NoSupply();

        uint256 entitlement = (shares * es.emergencySnapshot) / es.emergencySnapshotSupply;
        uint256 remainingClaims = es.emergencySnapshot > es.emergencyTotalWithdrawn
            ? es.emergencySnapshot - es.emergencyTotalWithdrawn
            : 0;

        uint256 payoutAmount = (available >= remainingClaims || remainingClaims == 0)
            ? entitlement
            : (entitlement * available) / remainingClaims;

        burn(msg.sender, shares);
        es.emergencyTotalWithdrawn += entitlement;

        payout(msg.sender, payoutAmount);

        emit EmergencyRedeemed(msg.sender, shares, payoutAmount);
    }

    /**
     * @notice Executes an emergency payout from the vault's own balance only.
     * @dev B-HIGH-3: Emergency mode exists precisely for the case where the
     *      Safe module is gone (compromised manager disables module, or Safe
     *      keys lost). Calling into the Safe here would brick the very
     *      crisis path the function is supposed to provide. Pay only what
     *      the vault holds; the pro-rata math in emergencyWithdraw already
     *      handles partial liquidity by shrinking later withdrawers' shares
     *      of the remaining pool.
     *
     *      For non-emergency redemptions, see _payout in the main vault —
     *      that path correctly goes through the Safe module.
     *
     * @param baseToken Token contract to transfer
     * @param user Recipient address
     * @param amount Requested amount (native decimals); we may pay less
     */
    function executePayout(
        IERC20 baseToken,
        address user,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        uint256 vaultBal = baseToken.balanceOf(address(this));
        uint256 toPay = amount > vaultBal ? vaultBal : amount;
        if (toPay == 0) {
            emit PayoutFailed(user, amount, "vault empty");
            return;
        }
        baseToken.safeTransfer(user, toPay);
    }

    /**
     * @notice Checks if emergency mode is currently active
     * @dev View function for external queries
     *
     * WHY IT'S IMPORTANT:
     * - UI can show emergency status to users
     * - Other contracts can check before operations
     * - Simple boolean check for emergency state
     *
     * @param es Emergency storage reference
     * @return true if emergency mode active
     */
    function isEmergencyActive(EmergencyStorage storage es) external view returns (bool) {
        return es.emergencyMode;
    }

    /**
     * @notice Returns complete emergency state information
     * @dev View function for detailed emergency info
     *
     * WHY IT'S IMPORTANT:
     * - Shows AUM snapshot for entitlement calculations
     * - Tracks total already withdrawn
     * - Displays pause timestamp for automatic trigger countdown
     * - Useful for UI to display emergency details
     *
     * @param es Emergency storage reference
     * @return active Whether emergency mode is on
     * @return snapshot AUM snapshot at emergency trigger
     * @return snapshotSupply Share supply snapshot at emergency trigger
     * @return withdrawn Total entitlement claimed so far
     * @return pauseTime Timestamp when contract was paused
     */
    function emergencyInfo(EmergencyStorage storage es)
        external
        view
        returns (
            bool active,
            uint256 snapshot,
            uint256 snapshotSupply,
            uint256 withdrawn,
            uint256 pauseTime
        )
    {
        active = es.emergencyMode;
        snapshot = es.emergencySnapshot;
        snapshotSupply = es.emergencySnapshotSupply;
        withdrawn = es.emergencyTotalWithdrawn;
        pauseTime = es.pauseTimestamp;
    }
}
