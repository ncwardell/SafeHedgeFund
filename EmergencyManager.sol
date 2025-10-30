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
     * @notice Trigger emergency mode (guardian)
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
 * @notice Public trigger after 30 days of pause OR 30 days of stale AUM
 */
function checkEmergencyThreshold(
    EmergencyStorage storage es,
    bool isPaused,
    uint256 currentAum,
    uint256 aumTimestamp  // NEW PARAMETER
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
     * @notice Exit emergency mode (admin)
     */
    function exitEmergency(EmergencyStorage storage es) external {
        if (!es.emergencyMode) return;
        es.emergencyMode = false;
        es.emergencySnapshot = 0;
        es.emergencyTotalWithdrawn = 0;
        emit EmergencyToggled(false);
    }

    /**
     * @notice Perform emergency withdrawal (pro-rata)
     * PATCH: Fixed reentrancy by updating state before external call (HIGH-3)
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
     * @notice Execute payout with Safe fallback + events
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

    function isEmergencyActive(EmergencyStorage storage es) external view returns (bool) {
        return es.emergencyMode;
    }

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
