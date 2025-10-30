// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title AUMManager – Pure View Calculations
 * @notice NAV, share estimates, HWM status – no storage, no side-effects
 */
library AUMManager {
    // ====================== CONSTANTS ======================
    uint256 private constant FEE_DENOMINATOR = 10_000;
    uint256 private constant HWM_DRAWDOWN_PCT = 6000; // 60%
    uint256 private constant HWM_RECOVERY_PCT = 500;  // 5%
    uint256 private constant HWM_RECOVERY_PERIOD = 90 days;

    // ====================== VIEW FUNCTIONS ======================

    /**
     * @notice Current NAV per share
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
     * @notice Estimate shares for deposit
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
     * @notice Estimate payout for redemption
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
     * @notice HWM status
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
     */
    function shouldTrackDrawdown(
        uint256 currentNav,
        uint256 highWaterMark
    ) external pure returns (bool) {
        return currentNav < highWaterMark * (FEE_DENOMINATOR - HWM_DRAWDOWN_PCT) / FEE_DENOMINATOR;
    }

    /**
     * @notice Check if recovery threshold is met
     */
    function isRecoveryThresholdMet(
        uint256 currentNav,
        uint256 lowestNavInDrawdown
    ) external pure returns (bool) {
        return lowestNavInDrawdown > 0 &&
               currentNav >= lowestNavInDrawdown * (FEE_DENOMINATOR + HWM_RECOVERY_PCT) / FEE_DENOMINATOR;
    }

    /**
     * @notice Time until HWM reset
     */
    function timeToHWMReset(
        uint256 recoveryStartTime
    ) external view returns (uint256) {
        if (recoveryStartTime == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - recoveryStartTime;
        return elapsed >= HWM_RECOVERY_PERIOD ? 0 : HWM_RECOVERY_PERIOD - elapsed;
    }
}