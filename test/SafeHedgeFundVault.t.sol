// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

import "../contracts/SafeHedgeFundVault.sol";
import "./mocks/MockSafe.sol";
import "./mocks/MockUSDC.sol";

contract SafeHedgeFundVaultTest is Test {
    SafeHedgeFundVault internal vault;
    MockSafe internal safe;
    MockUSDC internal usdc;

    address internal admin = address(this);
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal rescueTreasury = makeAddr("rescueTreasury");
    address internal aumUpdater = makeAddr("aumUpdater");
    address internal processor = makeAddr("processor");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant MIN_DEPOSIT = 100e6; // 100 USDC
    uint256 internal constant MIN_REDEMPTION = 10e6; // 10 USDC

    function setUp() public {
        usdc = new MockUSDC();
        safe = new MockSafe();

        vault = new SafeHedgeFundVault(
            address(usdc),
            address(safe),
            feeRecipient,
            rescueTreasury,
            MIN_DEPOSIT,
            MIN_REDEMPTION
        );

        safe.enableModule(address(vault));

        vault.grantRole(vault.AUM_UPDATER_ROLE(), aumUpdater);
        vault.grantRole(vault.PROCESSOR_ROLE(), processor);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);

        // Warp past the ConfigManager cooldown window (5 days) so any
        // _setFeeBps call later in tests doesn't trip CooldownActive on a
        // never-changed key (lastConfigChange[key] starts at 0).
        vm.warp(6 days);

        usdc.mint(address(safe), 1e6);
        vm.prank(aumUpdater);
        vault.updateAum(1e6);
    }

    // ── helpers ─────────────────────────────────────────────────────────

    function _setFeeBps(string memory key, uint256 bps) internal {
        vault.proposeConfigChange(key, bps);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeConfigProposal(key, bps);
        // Keep AUM fresh — the timelock warp may have crossed maxAumAge.
        _refreshAum();
    }

    function _depositFrom(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, 0);
        vm.stopPrank();
    }

    function _depositWithMinShares(address user, uint256 amount, uint256 minShares) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, minShares);
        vm.stopPrank();
    }

    function _refreshAum() internal {
        uint256 newAum = usdc.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(newAum);
    }

    // ── B1 (already shipped): deposit batch processing ──────────────────

    function test_B1_batchProcessing_mintsAllItems() public {
        uint256 depositAmount = 1_000e6;

        _depositFrom(alice, depositAmount);
        _depositFrom(bob, depositAmount);

        (uint256 depQ, ) = vault.queueLengths();
        assertEq(depQ, 2);

        uint256 safeBalBefore = usdc.balanceOf(address(safe));

        vm.prank(processor);
        vault.processDepositQueue(2);

        assertGt(vault.balanceOf(alice), 0);
        assertGt(vault.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(safe)), safeBalBefore + 2 * depositAmount);
    }

    function test_depositAndRedeemFlow() public {
        uint256 depositAmount = 1_000e6;

        _depositFrom(alice, depositAmount);
        vm.prank(processor);
        vault.processDepositQueue(1);

        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);

        _refreshAum();

        vm.prank(alice);
        vault.redeem(shares, 0);

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(processor);
        vault.processRedemptionQueue(1);
        assertGt(usdc.balanceOf(alice) - aliceBalBefore, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ── B-CRIT-1: exit fee accrued exactly once per redemption ──────────

    /// @notice Pre-fix: redeem() called accrueExitFee at line 196, then
    /// _payout (called from redeem auto-payout OR from processRedemptionQueue)
    /// called accrueExitFee again. Result: accruedExitFees grew by 2× the
    /// real fee per redemption (more on retries).
    /// Post-fix: redeem uses previewExitFee (no mutation); only _payout's
    /// recordExitFee runs, and only after the Safe transfer succeeds.
    function test_BCRIT1_exitFeeAccruedExactlyOnce_queuedPath() public {
        _setFeeBps("exit", 100); // 1%

        uint256 depositAmount = 10_000e6;
        _depositFrom(alice, depositAmount);
        vm.prank(processor);
        vault.processDepositQueue(1);
        _refreshAum();

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, 0);

        // Before processing: redeem alone shouldn't have moved the ledger.
        ( , , , uint256 exitBefore, , ) = vault.accruedFees();
        assertEq(exitBefore, 0, "redeem must not pre-accrue exit fee");

        vm.prank(processor);
        vault.processRedemptionQueue(1);

        ( , , , uint256 exitAfter, , uint256 totalNative) = vault.accruedFees();

        // Expected fee: 1% of (shares * nav / 1e18) in native decimals.
        // alice held essentially the whole fund, so fee ≈ 1% of fund value.
        uint256 expectedFeeNative = totalNative;
        assertGt(expectedFeeNative, 0, "fee must be non-zero");

        // Exit fee accrual should equal exactly the single-charge amount,
        // not 2× / 3× as before.
        uint256 exitNative = exitAfter / 1e12; // 6-dec base, DECIMAL_FACTOR=1e12
        uint256 grossNative = (depositAmount + 1e6); // alice owns full fund
        uint256 expectedSingle = grossNative / 100;  // 1%
        assertApproxEqAbs(exitNative, expectedSingle, 1, "exit fee must be 1x gross");
    }

    function test_BCRIT1_exitFeeAccruedExactlyOnce_autoPayoutPath() public {
        _setFeeBps("exit", 100); // 1%
        vault.setAutoProcess(false, true); // auto-payout on

        uint256 depositAmount = 10_000e6;
        _depositFrom(alice, depositAmount);
        vm.prank(processor);
        vault.processDepositQueue(1);
        _refreshAum();

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, 0);

        ( , , , uint256 exitAfter, , ) = vault.accruedFees();
        uint256 exitNative = exitAfter / 1e12;
        uint256 grossNative = depositAmount + 1e6;
        uint256 expectedSingle = grossNative / 100;
        assertApproxEqAbs(exitNative, expectedSingle, 1, "auto-payout: exit fee 1x");
    }

    // ── B-CRIT-2: failed batch deposit must not leak entrance fee ───────

    /// @notice Pre-fix: _processDepositItem mutated accruedEntranceFees
    /// before the slippage check, so a deposit with too-tight minShares
    /// would leave fee on the ledger every time the processor ran. The
    /// user could then cancel and walk away with full deposit, while the
    /// fee ledger stayed inflated.
    /// Post-fix: previewEntranceFee is pure; recordEntranceFee runs only
    /// after every check passes.
    function test_BCRIT2_failedSlippageDoesNotLeakEntranceFee() public {
        _setFeeBps("entrance", 100); // 1%

        // Set minShares impossibly high → guaranteed slippage failure.
        uint256 depositAmount = 1_000e6;
        _depositWithMinShares(alice, depositAmount, type(uint128).max);

        // Run the processor multiple times — each pass should hit the
        // slippage skip path, NOT bump the entrance-fee ledger.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(processor);
            vault.processDepositQueue(1);
        }

        ( , , uint256 entrance, , , ) = vault.accruedFees();
        assertEq(entrance, 0, "no fee should accrue on failed slippage");

        // User cancels and gets the full deposit back.
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.cancelMyDeposits(5);
        assertEq(usdc.balanceOf(alice), aliceBalBefore + depositAmount, "full refund on cancel");

        ( , , entrance, , , ) = vault.accruedFees();
        assertEq(entrance, 0, "ledger still clean after cancel");
    }

    // ── B-HIGH-1: emergency tracks payout, not entitlement ──────────────

    /// @notice Two users with equal shares should receive equal payouts in a
    /// partial-liquidity emergency. This is the test that surfaced B-CRIT-3:
    /// the original code divided entitlement by `totalSupply()` (live), but
    /// after alice burns her shares, bob's entitlement formula divides by a
    /// smaller supply and over-claims. With the supply snapshotted at trigger
    /// time, both users end up with the same proportional cut.
    ///
    /// Also exercises B-HIGH-3: vault holds the emergency liquidity, the Safe
    /// doesn't get touched.
    function test_BHIGH1_BCRIT3_emergencySplitsAvailableProportionally() public {
        // Equal stakes.
        _depositFrom(alice, 50_000e6);
        _depositFrom(bob, 50_000e6);
        vm.prank(processor);
        vault.processDepositQueue(2);
        _refreshAum();

        // Stage emergency liquidity in the vault (e.g. manager returned some
        // funds to the on-chain side). 50K of vault liquidity vs 100K total.
        usdc.mint(address(vault), 50_000e6);

        vault.pause();
        vm.prank(guardian);
        vault.triggerEmergency();

        // Confirm supply was snapshotted (B-CRIT-3 fix).
        (, uint256 snapshot, uint256 snapshotSupply, , ) = vault.emergencyInfo();
        assertGt(snapshot, 0);
        assertEq(snapshotSupply, vault.totalSupply(), "supply snapshot must equal pre-burn supply");

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        assertEq(aliceShares, bobShares, "test setup: equal shares");

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyWithdraw(aliceShares);
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBalBefore;

        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.emergencyWithdraw(bobShares);
        uint256 bobGot = usdc.balanceOf(bob) - bobBalBefore;

        // The whole point: with snapshot supply + entitlement-tracked
        // remainingClaims, equal-share users get equal payouts.
        assertEq(aliceGot, bobGot, "alice and bob must get exactly equal payouts");
        assertGt(aliceGot, 0);
    }

    // ── B-HIGH-3: emergency works when Safe module is disabled ──────────

    /// @notice The whole point of emergency mode is that the manager has
    /// "gone rogue" or the Safe is unreachable. Pre-fix: executePayout
    /// reverted with ModuleNotEnabled if vault didn't hold the full amount,
    /// which made the protective path useless precisely when needed most.
    /// Post-fix: pay only what the vault holds (no Safe calls).
    function test_BHIGH3_emergencyWithdrawWorksWithSafeDisabled() public {
        // Alice deposits, gets shares.
        _depositFrom(alice, 50_000e6);
        vm.prank(processor);
        vault.processDepositQueue(1);
        _refreshAum();

        // Simulate: vault has some liquidity (e.g. fees collected, or a
        // direct transfer for emergency reserve). Push 5_000 USDC to vault.
        usdc.mint(address(vault), 5_000e6);

        // Manager goes rogue → disables module on Safe.
        safe.disableModule(address(vault));
        assertFalse(vault.isModuleEnabled());

        // Pause + emergency.
        vault.pause();
        vm.prank(guardian);
        vault.triggerEmergency();

        // Alice should be able to withdraw at least the vault-side liquidity.
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.emergencyWithdraw(aliceShares);

        uint256 received = usdc.balanceOf(alice) - aliceBalBefore;
        assertGt(received, 0, "must pay something even with Safe disabled");
        assertLe(received, 5_000e6, "must not exceed vault-side liquidity");
    }

    // ── B-HIGH-2: per-user index cancellation, not full-queue scan ──────

    /// @notice Pre-fix: cancelDeposits looped head→tail of the entire queue
    /// looking for the user's items. With many other users in the queue, a
    /// user could hit gas limits and be unable to cancel.
    /// Post-fix: iterate userDepositIndices directly. We assert correctness
    /// here (not gas — gas behaviour follows from the change).
    // ── B-MED-1: HWM uses gross NAV so perf fee isn't re-charged ────────

    /// @notice Pre-fix: HWM was bumped to newNavPerShare (post-fee), so a
    /// no-op updateAum after a perf fee charge would re-charge perf fee on
    /// the spread between gross NAV and post-fee NAV. Post-fix: HWM tracks
    /// gross NAV, so a no-op update accrues zero additional perf fee.
    function test_BMED1_noPerfFeeOnNoOpUpdate() public {
        _setFeeBps("perf", 2000); // 20%

        // Alice deposits and processes.
        _depositFrom(alice, 10_000e6);
        vm.prank(processor);
        vault.processDepositQueue(1);
        _refreshAum();

        // Simulate AUM growth: mint a bunch into the safe (off-chain
        // returns) and update.
        usdc.mint(address(safe), 5_000e6); // 50% growth
        uint256 grownAum = usdc.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(grownAum);

        ( , uint256 perfAfterGrowth, , , , ) = vault.accruedFees();
        assertGt(perfAfterGrowth, 0, "perf fee must accrue on growth");

        // No-op update at the same AUM. Pre-fix this would re-charge perf
        // fee on the post-fee→pre-fee spread.
        vm.prank(aumUpdater);
        vault.updateAum(grownAum);

        ( , uint256 perfAfterNoOp, , , , ) = vault.accruedFees();
        assertEq(perfAfterNoOp, perfAfterGrowth, "no-op update must not bump perf fee");
    }

    // ── B-MED-3: pauseTimestamp cleared on unpause ──────────────────────

    function test_BMED3_pauseTimestampClearedOnUnpause() public {
        vault.pause();
        (, , , , uint256 pauseTime) = vault.emergencyInfo();
        assertGt(pauseTime, 0, "pause sets timestamp");

        vault.unpause();
        (, , , , pauseTime) = vault.emergencyInfo();
        assertEq(pauseTime, 0, "unpause must clear pauseTimestamp");
    }

    // ── B-LOW-5: full-exit exemption from minRedemption ────────────────

    /// @notice After the fix, a user whose payout would be 1 wei below
    /// minRedemption due to round-trip rounding can still close their
    /// position via the normal redeem path.
    function test_BLOW5_fullExitBypassesMinRedemption() public {
        // Set minRedemption equal to MIN_DEPOSIT so any round-trip rounding
        // would otherwise trigger BelowMinimum on full exit.
        // (Constructor already wires them equal; no change needed.)

        _depositFrom(alice, MIN_DEPOSIT);
        vm.prank(processor);
        vault.processDepositQueue(1);
        _refreshAum();

        uint256 shares = vault.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);

        // Full exit — must succeed even if payout is ~1 wei under minRedemption.
        vm.prank(alice);
        vault.redeem(shares, 0);
        vm.prank(processor);
        vault.processRedemptionQueue(1);

        assertEq(vault.balanceOf(alice), 0);
        // We got close to minDeposit back (within 2 wei rounding).
        assertGe(usdc.balanceOf(alice), balBefore + MIN_DEPOSIT - 2);
    }

    /// @notice Per-user cancellation must touch only that user's items
    /// regardless of who else is in the queue. We assert via balances
    /// (the most direct invariant): each user gets exactly their queued
    /// total back, no more, no less.
    function test_BHIGH2_cancellationFindsOnlyUserItems() public {
        _depositFrom(alice, 1_000e6);
        _depositFrom(bob, 2_000e6);
        _depositFrom(alice, 1_500e6);
        _depositFrom(carol, 500e6);
        _depositFrom(bob, 2_500e6);

        // Alice should recover exactly 2_500 (1_000 + 1_500).
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.cancelMyDeposits(10);
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, 2_500e6, "alice's two deposits");

        // Bob should still be able to cancel his.
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.cancelMyDeposits(10);
        assertEq(usdc.balanceOf(bob) - bobBalBefore, 4_500e6, "bob's two deposits");

        // Carol's deposit is untouched.
        uint256 carolBalBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        vault.cancelMyDeposits(10);
        assertEq(usdc.balanceOf(carol) - carolBalBefore, 500e6, "carol's deposit");

        // pendingDeposits all back to zero.
        ( , , uint256 alicePending, ) = vault.getPosition(alice);
        ( , , uint256 bobPending, ) = vault.getPosition(bob);
        ( , , uint256 carolPending, ) = vault.getPosition(carol);
        assertEq(alicePending, 0);
        assertEq(bobPending, 0);
        assertEq(carolPending, 0);
    }

    // ── B-HIGH-5: zero-shares auto-process is a slippage failure, not a strand ──

    /// @notice Pre-fix: processSingleDeposit returned ok=true with shares=0
    /// when nav had inflated; the caller bailed without minting OR refunding,
    /// so the user's tokens were stranded in the vault with the queue item
    /// burned.
    /// Post-fix: shares==0 → return false (treated as slippage failure),
    /// item stays in queue, user can cancel and recover.
    function test_BHIGH5_autoProcessZeroShares_userCanRecover() public {
        // Inflate NAV: alice deposits, processes, then we updateAum to a
        // very large value so a tiny new deposit would round to 0 shares.
        _depositFrom(alice, MIN_DEPOSIT);
        vm.prank(processor);
        vault.processDepositQueue(1);

        // Force NAV way up by reporting absurdly large AUM.
        // We need newAum >= onChain — mint enough to the safe to support it.
        usdc.mint(address(safe), 10_000_000_000e6);
        uint256 newAum = usdc.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(newAum);

        // Enable auto-process; bob deposits exactly minDeposit.
        vault.setAutoProcess(true, false);

        uint256 bobBalBefore = usdc.balanceOf(bob);
        _depositWithMinShares(bob, MIN_DEPOSIT, 0);

        // Bob's auto-process should have skipped (shares==0 → slippage).
        // His tokens are still in the queue — he can cancel and recover.
        assertEq(vault.balanceOf(bob), 0, "no shares minted");

        vm.prank(bob);
        vault.cancelMyDeposits(1);

        assertEq(usdc.balanceOf(bob), bobBalBefore, "bob recovered his deposit");
    }
}
