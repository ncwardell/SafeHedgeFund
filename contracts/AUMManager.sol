// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title AUMManager - Pure View Calculations Library
 * @notice Provides pure view functions for NAV calculations, share estimates, and HWM status
 * @dev Library contains no storage and no side-effects, all calculations are view functions
 */
library AUMManager {
    // ====================== CONSTANTS ======================
    uint256 private constant FEE_DENOMINATOR = 10_000;
    uint256 private constant HWM_DRAWDOWN_PCT = 6000; // 60%
    uint256 private constant HWM_RECOVERY_PCT = 500;  // 5%
    uint256 private constant HWM_RECOVERY_PERIOD = 90 days;

    // ====================== VIEW FUNCTIONS ======================

    /**
     * @notice Calculate current NAV (Net Asset Value) per share
     * @dev Adjusts AUM for accrued fees before calculating NAV
     * @param aum Total assets under management
     * @param totalSupply Total supply of shares
     * @param totalAccruedFees18 Total accrued fees in 18 decimals
     * @param normalize Function to normalize amounts to 18 decimals
     * @param denormalize Function to denormalize amounts from 18 decimals
     * @return navPerShare NAV per share in 18 decimals
     */
    function getNav(
        uint256 aum,
        uint256 totalSupply,
        uint256 totalAccruedFees18,
        function(uint256) view returns (uint256) normalize,
        function(uint256) view returns (uint256) denormalize
    ) external view returns (uint256 navPerShare) {
        if (totalSupply == 0) return 1e18;

        uint256 feesNative = denormalize(totalAccruedFees18);
        uint256 adjustedAum = aum >= feesNative ? aum - feesNative : 0;
        navPerShare = (normalize(adjustedAum) * 1e18) / totalSupply;
    }

    /**
     * @notice Estimate shares to be received for a deposit amount
     * @dev Calculates shares after deducting entrance fees
     * @param amount Deposit amount in base token decimals
     * @param entranceFeeBps Entrance fee in basis points
     * @param navPerShare Current NAV per share
     * @param normalize Function to normalize amounts to 18 decimals
     * @return shares Estimated shares to be minted
     */
    function estimateShares(
        uint256 amount,
        uint256 entranceFeeBps,
        uint256 navPerShare,
        function(uint256) view returns (uint256) normalize
    ) external view returns (uint256 shares) {
        if (navPerShare == 0) return 0;
        uint256 net = amount * (FEE_DENOMINATOR - entranceFeeBps) / FEE_DENOMINATOR;
        shares = (normalize(net) * 1e18) / navPerShare;
    }

    /**
     * @notice Estimate payout for redeeming shares
     * @dev Calculates payout after deducting exit fees
     * @param shares Number of shares to redeem
     * @param navPerShare Current NAV per share
     * @param exitFeeBps Exit fee in basis points
     * @param denormalize Function to denormalize amounts from 18 decimals
     * @return payout Estimated payout in base token decimals
     */
    function estimatePayout(
        uint256 shares,
        uint256 navPerShare,
        uint256 exitFeeBps,
        function(uint256) view returns (uint256) denormalize
    ) external view returns (uint256 payout) {
        uint256 gross = (shares * navPerShare) / 1e18;
        uint256 fee = gross * exitFeeBps / FEE_DENOMINATOR;
        payout = denormalize(gross - fee);
    }

    /**
     * @notice Get high water mark status and recovery progress
     * @dev Returns current HWM state including drawdown tracking and recovery timeline
     * @param highWaterMark Current high water mark value
     * @param lowestNavInDrawdown Lowest NAV recorded during drawdown period
     * @param recoveryStartTime Timestamp when recovery period started
     * @param currentNav Current NAV per share
     * @return hwm Current high water mark
     * @return lowestNav Lowest NAV during drawdown
     * @return recoveryStart Recovery start timestamp
     * @return daysToReset Days remaining until HWM reset (0 if ready)
     */
    function getHWMStatus(
        uint256 highWaterMark,
        uint256 lowestNavInDrawdown,
        uint256 recoveryStartTime,
        uint256 currentNav
    ) external view returns (
        uint256 hwm,
        uint256 lowestNav,
        uint256 recoveryStart,
        uint256 daysToReset
    ) {
        hwm = highWaterMark;
        lowestNav = lowestNavInDrawdown;
        recoveryStart = recoveryStartTime;

        if (recoveryStart > 0) {
            uint256 elapsed = block.timestamp - recoveryStart;
            daysToReset = elapsed >= HWM_RECOVERY_PERIOD
                ? 0
                : (HWM_RECOVERY_PERIOD - elapsed) / 1 days;
        }
    }

    /**
     * @notice Check if current NAV triggers drawdown tracking
     * @dev Returns true if NAV has fallen below the drawdown threshold (60% of HWM)
     * @param currentNav Current NAV per share
     * @param highWaterMark Current high water mark
     * @return Whether drawdown tracking should be activated
     */
    function shouldTrackDrawdown(
        uint256 currentNav,
        uint256 highWaterMark
    ) external pure returns (bool) {
        return currentNav < highWaterMark * (FEE_DENOMINATOR - HWM_DRAWDOWN_PCT) / FEE_DENOMINATOR;
    }

    /**
     * @notice Check if NAV recovery threshold is met
     * @dev Returns true if NAV has recovered 5% above the lowest point in drawdown
     * @param currentNav Current NAV per share
     * @param lowestNavInDrawdown Lowest NAV recorded during drawdown
     * @return Whether the recovery threshold has been met
     */
    function isRecoveryThresholdMet(
        uint256 currentNav,
        uint256 lowestNavInDrawdown
    ) external pure returns (bool) {
        return lowestNavInDrawdown > 0 &&
               currentNav >= lowestNavInDrawdown * (FEE_DENOMINATOR + HWM_RECOVERY_PCT) / FEE_DENOMINATOR;
    }

    /**
     * @notice Calculate time remaining until high water mark reset
     * @dev Returns 0 if recovery period is complete, max uint256 if not started
     * @param recoveryStartTime Timestamp when recovery period started
     * @return Time in seconds until HWM reset (0 if ready, max if not started)
     */
    function timeToHWMReset(
        uint256 recoveryStartTime
    ) external view returns (uint256) {
        if (recoveryStartTime == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - recoveryStartTime;
        return elapsed >= HWM_RECOVERY_PERIOD ? 0 : HWM_RECOVERY_PERIOD - elapsed;
    }
}