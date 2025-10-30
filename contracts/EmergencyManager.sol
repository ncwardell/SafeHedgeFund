// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EmergencyManager - PATCHED VERSION
 * @notice Handles emergency withdrawals with pro-rata distribution
 * 
 * CHANGES FROM ORIGINAL:
 * - Fixed reentrancy risk by updating state before external calls (HIGH-3)
 * - Improved state update ordering
 */
library EmergencyManager {
    using SafeERC20 for IERC20;

    // ====================== CONSTANTS ======================
    uint256 private constant EMERGENCY_THRESHOLD = 30 days;

    // ====================== STRUCTS ======================
    struct EmergencyStorage {
        bool emergencyMode;
        uint256 emergencySnapshot;
        uint256 emergencyTotalWithdrawn;
        uint256 pauseTimestamp;
    }

    // ====================== EVENTS ======================
    event EmergencyToggled(bool enabled);
    event EmergencyRedeemed(address indexed user, uint256 shares, uint256 amount);
    event PayoutFailed(address indexed user, uint256 amount, string reason);

    // ====================== ERRORS ======================
    error NotInEmergency();
    error NoSupply();
    error PayoutFailed();
    error ModuleNotEnabled();
    error NotPaused();
    error ThresholdNotMet();

    // ====================== EXTERNAL FUNCTIONS ======================

    /**
     * @notice Trigger emergency mode manually (guardian only)
     * @dev Snapshots current AUM for pro-rata emergency withdrawals
     * @param es Emergency storage reference
     * @param currentAum Current total AUM at time of emergency trigger
     */
    function triggerEmergency(
        EmergencyStorage storage es,
        uint256 currentAum
    ) external {
        if (es.emergencyMode) return;
        es.emergencyMode = true;
        es.emergencySnapshot = currentAum;
        es.emergencyTotalWithdrawn = 0;
        emit EmergencyToggled(true);
    }

    /**
     * @notice Public trigger for emergency mode after 30 days of pause or stale AUM
     * @dev Can be called by anyone if threshold conditions are met
     * @param es Emergency storage reference
     * @param isPaused Whether the contract is currently paused
     * @param currentAum Current total AUM
     * @param aumTimestamp Timestamp of last AUM update
     */
    function checkEmergencyThreshold(
        EmergencyStorage storage es,
        bool isPaused,
        uint256 currentAum,
        uint256 aumTimestamp
    ) external {
    bool pausedLongEnough = isPaused && 
        block.timestamp >= es.pauseTimestamp + EMERGENCY_THRESHOLD;
    
    bool aumStaleLongEnough = 
        block.timestamp >= aumTimestamp + EMERGENCY_THRESHOLD;
    
    // Need at least ONE condition to be true
    if (!pausedLongEnough && !aumStaleLongEnough) {
        revert ThresholdNotMet();
    }
    
    if (es.emergencyMode) return;

    es.emergencyMode = true;
    es.emergencySnapshot = currentAum;
    es.emergencyTotalWithdrawn = 0;
    emit EmergencyToggled(true);
}

    /**
     * @notice Exit emergency mode and restore normal operations (admin only)
     * @dev Resets all emergency state variables
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
     * @notice Perform emergency withdrawal with pro-rata distribution
     * @dev PATCH: Fixed reentrancy by updating state before external call (HIGH-3)
     * @param es Emergency storage reference
     * @param shares Number of shares to withdraw
     * @param totalSupply Total share supply
     * @param currentAum Current total AUM
     * @param burn Function to burn shares
     * @param payout Function to execute payout
     */
    function emergencyWithdraw(
        EmergencyStorage storage es,
        uint256 shares,
        uint256 totalSupply,
        uint256 currentAum,
        function(address, uint256) external burn,
        function(address, uint256) external payout
    ) external {
        if (!es.emergencyMode) revert NotInEmergency();
        if (shares == 0 || totalSupply == 0) revert NoSupply();

        // Calculate amounts
        uint256 entitlement = (shares * es.emergencySnapshot) / totalSupply;
        uint256 available = currentAum;
        uint256 remainingClaims = es.emergencySnapshot - es.emergencyTotalWithdrawn;

        uint256 payoutAmount = available >= remainingClaims
            ? entitlement
            : (entitlement * available) / remainingClaims;

        // PATCH: Update all state BEFORE external calls (HIGH-3)
        // This prevents reentrancy issues
        burn(msg.sender, shares);
        es.emergencyTotalWithdrawn += entitlement;

        // Now safe to call external payout
        payout(msg.sender, payoutAmount);
        
        emit EmergencyRedeemed(msg.sender, shares, payoutAmount);
    }

    /**
     * @notice Execute payout with Safe wallet fallback and event emission
     * @dev Tries vault balance first, then Safe wallet if needed
     * @param baseToken Base token contract
     * @param user Address to receive payout
     * @param amount Amount to payout
     * @param safeWallet Safe wallet address for additional liquidity
     * @param isModuleEnabled Function to check if vault is enabled as Safe module
     */
    function executePayout(
        IERC20 baseToken,
        address user,
        uint256 amount,
        address safeWallet,
        function() view returns (bool) isModuleEnabled
    ) external {
        uint256 vaultBal = baseToken.balanceOf(address(this));

        if (vaultBal >= amount) {
            baseToken.safeTransfer(user, amount);
            return;
        }

        // Try vault first
        if (vaultBal > 0) {
            baseToken.safeTransfer(user, vaultBal);
        }

        uint256 remaining = amount - vaultBal;
        if (remaining == 0) return;

        // Safe required
        if (!isModuleEnabled()) {
            emit PayoutFailed(user, remaining, "module not enabled");
            revert ModuleNotEnabled();
        }

        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, user, remaining);
        (bool success, ) = safeWallet.call(
            abi.encodeWithSignature(
                "execTransactionFromModule(address,uint256,bytes,uint8)",
                address(baseToken), 0, data, 0
            )
        );

        if (!success) {
            emit PayoutFailed(user, remaining, "Safe exec failed");
            revert PayoutFailed();
        }
    }

    // ====================== VIEW FUNCTIONS ======================

    /**
     * @notice Check if emergency mode is currently active
     * @param es Emergency storage reference
     * @return Whether emergency mode is active
     */
    function isEmergencyActive(EmergencyStorage storage es) external view returns (bool) {
        return es.emergencyMode;
    }

    /**
     * @notice Get comprehensive emergency mode information
     * @param es Emergency storage reference
     * @return active Whether emergency mode is active
     * @return snapshot AUM snapshot at emergency trigger
     * @return withdrawn Total amount withdrawn during emergency
     * @return pauseTime Timestamp when contract was paused
     */
    function emergencyInfo(EmergencyStorage storage es)
        external
        view
        returns (
            bool active,
            uint256 snapshot,
            uint256 withdrawn,
            uint256 pauseTime
        )
    {
        active = es.emergencyMode;
        snapshot = es.emergencySnapshot;
        withdrawn = es.emergencyTotalWithdrawn;
        pauseTime = es.pauseTimestamp;
    }
}
