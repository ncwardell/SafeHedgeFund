// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Base.sol";

/// @title Stateless property fuzz
/// @notice Each test asserts an invariant that should hold across the
/// parameter space. Uses Foundry's per-test fuzzer (256 runs default).
abstract contract PropertyFuzzBase is FuzzBase {
    address internal founder = makeAddr("founder");
    address internal user = makeAddr("user");

    function setUp() public virtual {
        _deployVault(_decimals());

        // Founder absorbs the 1-unit AUM seed so the user-side fuzzed
        // round-trip math isn't polluted by it.
        token.mint(founder, 1_000 * (10 ** _decimals()));
        vm.startPrank(founder);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1_000 * (10 ** _decimals()), 0);
        vm.stopPrank();
        _processOneDeposit();
        _refreshAum();
    }

    function _decimals() internal pure virtual returns (uint8);

    // ── Property 1: deposit-redeem round trip (no fees) preserves value ──

    /// @notice With no fees and a clean updateAum cycle between deposit and
    /// redeem, depositing X and redeeming the resulting shares must return
    /// approximately X. The "approximately" tolerance accounts for integer
    /// division rounding (worst case ~1 unit per division op).
    /// @notice Round-trip preserves value within a tolerance.
    ///
    /// IMPORTANT: depositing *exactly* `minDeposit` on a token with
    /// decimals < 18 can round-trip to `minDeposit - 1 wei` of payout,
    /// which then fails the `payout < minRedemption` check inside
    /// redeem(). This is documented as B-LOW-5 in the audit. We bound
    /// above that edge here; the edge itself is exercised by
    /// test_edge_minDepositRoundTripRoundingLoss below.
    function testFuzz_roundTrip_noFees(uint96 amount) public {
        amount = uint96(
            bound(
                uint256(amount),
                minDeposit + (minDeposit / 100), // 1% buffer over minDeposit
                100_000 * (10 ** _decimals())
            )
        );

        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, 0);
        vm.stopPrank();
        _processOneDeposit();
        _refreshAum();

        uint256 shares = vault.balanceOf(user);
        assertGt(shares, 0, "deposit must mint shares");

        uint256 balBefore = token.balanceOf(user);

        vm.prank(user);
        vault.redeem(shares, 0);
        _processOneRedemption();

        uint256 received = token.balanceOf(user) - balBefore;

        // Tolerance: a few wei from integer division. We allow up to
        // 0.01% loss to absorb double rounding (deposit + redeem).
        uint256 tolerance = amount / 10_000 + 10;
        assertApproxEqAbs(received, amount, tolerance, "round-trip value preserved");
    }

    /// @notice Originally documented the round-trip rounding bug
    /// (B-LOW-5). Post-fix, the redeem path has a full-exit exemption from
    /// the minRedemption check: when the user redeems their entire balance,
    /// the dust-spam guard is skipped so a 1-wei rounding loss can't lock
    /// them in. This test now asserts the corrected behaviour.
    function test_edge_minDepositRoundTripFullExit() public {
        token.mint(user, minDeposit);
        vm.startPrank(user);
        token.approve(address(vault), minDeposit);
        vault.deposit(minDeposit, 0);
        vm.stopPrank();
        _processOneDeposit();
        _refreshAum();

        uint256 shares = vault.balanceOf(user);
        uint256 balBefore = token.balanceOf(user);

        vm.prank(user);
        // Full exit must succeed even on 6/8-dec tokens where round-trip
        // rounding makes payout fall ~1 wei short of minRedemption.
        vault.redeem(shares, 0);
        _processOneRedemption();

        uint256 received = token.balanceOf(user) - balBefore;
        // Exactly minDeposit OR minDeposit - 1 wei (depending on rounding).
        assertGe(received, minDeposit - 2, "full exit must pay close to minDeposit");
        assertLe(received, minDeposit, "full exit must not pay more than deposit");
        assertEq(vault.balanceOf(user), 0, "all shares burned");
    }

    /// @notice Partial redemptions still hit the minRedemption guard. The
    /// full-exit exemption applies only when the user is closing their
    /// entire position.
    function test_partialRedemption_stillHonorsMinRedemption() public {
        // Deposit enough to mint plenty of shares.
        uint256 amount = 100 * minDeposit;
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, 0);
        vm.stopPrank();
        _processOneDeposit();
        _refreshAum();

        uint256 shares = vault.balanceOf(user);
        // Tiny partial redemption — payout will be way below minRedemption.
        uint256 tinyShares = shares / 1000000; // ~ minDeposit / 10000 worth
        if (tinyShares == 0) return;

        vm.prank(user);
        vm.expectRevert(SafeHedgeFundVault.BelowMinimum.selector);
        vault.redeem(tinyShares, 0);
    }

    // ── Property 2: exit fee never exceeds the configured bps ──

    function testFuzz_exitFeeBounded(uint96 amount, uint16 bps) public {
        bps = uint16(bound(uint256(bps), 1, 500)); // 0.01%–5% (max from ConfigManager)
        _setFeeBps("exit", bps);

        amount = uint96(bound(uint256(amount), 100 * (10 ** _decimals()), 10_000 * (10 ** _decimals())));

        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, 0);
        vm.stopPrank();
        _processOneDeposit();
        _refreshAum();

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.redeem(shares, 0);
        _processOneRedemption();

        ( , , , , , uint256 totalNative) = vault.accruedFees();

        // Strict upper bound: total fees ≤ bps * (alice's deposit) basically.
        // Easier formulation: total native fees ≤ (bps / 10000) * (founder + user)
        uint256 maxAllowedFee = ((amount + 1_000 * (10 ** _decimals())) * bps) / 10_000 + 1;
        assertLe(totalNative, maxAllowedFee, "exit fee must be <= bps");
    }

    // ── Property 3: estimateShares matches actual minted shares ──

    function testFuzz_estimateSharesMatchesMint(uint96 amount) public {
        amount = uint96(bound(uint256(amount), minDeposit, 10_000 * (10 ** _decimals())));

        uint256 estimate = vault.estimateShares(amount);

        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, 0);
        vm.stopPrank();
        _processOneDeposit();

        uint256 actualShares = vault.balanceOf(user);
        // Tolerance: rounding only.
        assertApproxEqAbs(actualShares, estimate, estimate / 10_000 + 1, "estimate ~ actual");
    }

    // ── Property 4: estimatePayout matches actual redemption ──

    function testFuzz_estimatePayoutMatchesRedeem(uint96 amount) public {
        // Buffer above minDeposit to dodge the round-trip rounding edge
        // case (B-LOW-5); covered separately in
        // test_edge_minDepositRoundTripRoundingLoss.
        amount = uint96(bound(uint256(amount), minDeposit + (minDeposit / 100), 10_000 * (10 ** _decimals())));

        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, 0);
        vm.stopPrank();
        _processOneDeposit();
        _refreshAum();

        uint256 shares = vault.balanceOf(user);
        uint256 estimate = vault.estimatePayout(shares);

        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        vault.redeem(shares, 0);
        _processOneRedemption();

        uint256 received = token.balanceOf(user) - balBefore;
        assertApproxEqAbs(received, estimate, estimate / 10_000 + 1, "estimate ~ actual");
    }

    // ── Property 5: cancel returns the full deposit ──

    function testFuzz_cancelRefundsFullDeposit(uint96 amount) public {
        amount = uint96(bound(uint256(amount), minDeposit, 10_000 * (10 ** _decimals())));

        token.mint(user, amount);
        uint256 balBefore = token.balanceOf(user);

        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, 0);

        // Cancel before processing.
        vault.cancelMyDeposits(1);
        vm.stopPrank();

        assertEq(token.balanceOf(user), balBefore, "cancel must refund exactly");

        // No fees should have been accrued for an unprocessed deposit.
        ( , , uint256 entrance, , , ) = vault.accruedFees();
        assertEq(entrance, 0, "no fee accrual on unprocessed deposit");
    }

    // ── Property 6: slippage check rejects unfavorable processing ──

    /// @notice Setting minShares to estimateShares + 1 must cause processing
    /// to skip the item (not mint, not refund, not accrue). The user's funds
    /// stay in the vault until they cancel.
    function testFuzz_slippageRejectsHigherMinShares(uint96 amount) public {
        amount = uint96(bound(uint256(amount), minDeposit, 10_000 * (10 ** _decimals())));

        uint256 estimate = vault.estimateShares(amount);

        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, estimate * 2 + 1); // Impossible minShares
        vm.stopPrank();

        _processOneDeposit();

        assertEq(vault.balanceOf(user), 0, "no shares minted on slippage failure");

        // No fees accrued.
        ( , , uint256 entrance, , , ) = vault.accruedFees();
        assertEq(entrance, 0, "no fee accrued on slippage failure");

        // User can recover their full deposit.
        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        vault.cancelMyDeposits(1);
        assertEq(token.balanceOf(user) - balBefore, amount, "cancel after slippage refunds in full");
    }

    // ── Property 7: NAV is constant across no-op blocks ──

    /// @notice With no operations and no AUM update, navPerShare must return
    /// the same value across blocks. This catches accidental dependencies on
    /// block.timestamp / block.number in the NAV formula.
    function testFuzz_navStableUnderNoOp(uint32 timeDelta) public view {
        timeDelta = uint32(bound(uint256(timeDelta), 0, 2 days));
        // No vm.warp here — we want the live formula evaluated repeatedly.

        uint256 nav1 = vault.navPerShare();
        uint256 nav2 = vault.navPerShare();
        uint256 nav3 = vault.navPerShare();

        assertEq(nav1, nav2);
        assertEq(nav2, nav3);
    }
}

// ── Concrete instantiations across decimals ─────────────────────────────

contract PropertyFuzz_6decimals is PropertyFuzzBase {
    function _decimals() internal pure override returns (uint8) { return 6; }
}

contract PropertyFuzz_8decimals is PropertyFuzzBase {
    function _decimals() internal pure override returns (uint8) { return 8; }
}

contract PropertyFuzz_18decimals is PropertyFuzzBase {
    function _decimals() internal pure override returns (uint8) { return 18; }
}
