// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../../contracts/SafeHedgeFundVault.sol";
import "../../mocks/MockSafe.sol";
import "../Base.sol";

/// @notice Handler exposed to Foundry's invariant runner. Each public function
/// is callable by the fuzzer with random uint256 inputs; the handler clamps
/// them to sensible ranges so most calls succeed (giving the fuzzer many
/// state transitions per run instead of mostly-revert noise).
///
/// Ghost variables track expected aggregates so invariants can compare them
/// against on-chain state. Invariants live in the parent test contract.
contract VaultHandler is Test {
    SafeHedgeFundVault public vault;
    MockToken public token;
    MockSafe public safe;
    address public processor;
    address public aumUpdater;

    address[] public users;

    // ── Ghost variables ─────────────────────────────────────────────────
    uint256 public ghost_totalDepositedNative;
    uint256 public ghost_totalCancelledNative;
    uint256 public ghost_totalPaidOutNative;
    uint256 public ghost_aumUpdates;
    uint256 public ghost_actionCount;

    // ── Per-handler-action call counters (helpful for debugging coverage) ──
    mapping(bytes32 => uint256) public callCount;

    modifier countCall(bytes32 name) {
        callCount[name]++;
        ghost_actionCount++;
        _;
    }

    constructor(
        SafeHedgeFundVault _vault,
        MockToken _token,
        MockSafe _safe,
        address _processor,
        address _aumUpdater,
        address[] memory _users
    ) {
        vault = _vault;
        token = _token;
        safe = _safe;
        processor = _processor;
        aumUpdater = _aumUpdater;
        users = _users;
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    // ── Actions ─────────────────────────────────────────────────────────

    function deposit(uint256 userSeed, uint256 amount, uint256 minShares) public countCall("deposit") {
        address u = _user(userSeed);
        amount = bound(amount, vault.minDeposit(), 100_000 * (10 ** token.decimals()));
        // Allow minShares to occasionally fail slippage on purpose.
        minShares = bound(minShares, 0, type(uint128).max);

        // Skip if user has hit the per-user pending cap (5).
        if (_userPendingCount(u) >= 5) return;

        token.mint(u, amount);
        vm.startPrank(u);
        token.approve(address(vault), amount);
        try vault.deposit(amount, minShares) {
            ghost_totalDepositedNative += amount;
        } catch {
            // E.g. AUMStale, Paused, EmergencyMode — fine, just skip.
        }
        vm.stopPrank();
    }

    function redeem(uint256 userSeed, uint256 sharesBps) public countCall("redeem") {
        address u = _user(userSeed);
        uint256 bal = vault.balanceOf(u);
        if (bal == 0) return;
        if (_userRedemptionPendingCount(u) >= 5) return;

        sharesBps = bound(sharesBps, 1, 10_000);
        uint256 shares = (bal * sharesBps) / 10_000;
        if (shares == 0) return;

        vm.prank(u);
        try vault.redeem(shares, 0) {
            // Auto-payout off; goes to queue.
        } catch {
            // BelowMinimum / SlippageTooHigh / EmergencyMode etc. — ignore.
        }
    }

    function processDeposits(uint256 count) public countCall("processDeposits") {
        count = bound(count, 1, vault.maxBatchSize());
        vm.prank(processor);
        try vault.processDepositQueue(count) {} catch {}
    }

    function processRedemptions(uint256 count) public countCall("processRedemptions") {
        count = bound(count, 1, vault.maxBatchSize());
        vm.prank(processor);
        try vault.processRedemptionQueue(count) {
            // Track payouts via balance deltas — we approximate by reading
            // the safe / vault balance change here, but for simplicity we
            // skip and rely on token-level invariants instead.
        } catch {}
    }

    function updateAum(uint256 deltaBps, bool up) public countCall("updateAum") {
        // Move AUM by 0–10% up or down from current on-chain liquidity.
        deltaBps = bound(deltaBps, 0, 1_000);
        uint256 onChain = token.balanceOf(address(safe)) + token.balanceOf(address(vault));
        if (onChain == 0) return;
        uint256 delta = (onChain * deltaBps) / 10_000;
        uint256 newAum = up ? onChain + delta : (onChain > delta ? onChain : onChain);
        // Always need newAum >= onChain to pass the AUMBelowOnChain check.
        if (newAum < onChain) newAum = onChain;
        if (newAum == 0) return;

        vm.prank(aumUpdater);
        try vault.updateAum(newAum) {
            ghost_aumUpdates++;
        } catch {}
    }

    function cancelDeposits(uint256 userSeed) public countCall("cancelDeposits") {
        address u = _user(userSeed);
        uint256 balBefore = token.balanceOf(u);
        vm.prank(u);
        try vault.cancelMyDeposits(5) {
            uint256 refunded = token.balanceOf(u) - balBefore;
            ghost_totalCancelledNative += refunded;
        } catch {}
    }

    function cancelRedemptions(uint256 userSeed) public countCall("cancelRedemptions") {
        address u = _user(userSeed);
        vm.prank(u);
        try vault.cancelMyRedemptions(5) {} catch {}
    }

    function advanceTime(uint256 secondsForward) public countCall("advanceTime") {
        // Stay within maxAumAge most of the time so the fuzzer doesn't
        // permanently brick all aumNotStale-gated functions.
        secondsForward = bound(secondsForward, 1, 1 days);
        vm.warp(block.timestamp + secondsForward);
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    function _userPendingCount(address u) internal view returns (uint256 count) {
        uint256[] memory idxs = vault.getUserDepositIndices(u);
        for (uint256 i = 0; i < idxs.length; i++) {
            QueueManager.QueueItem[] memory items = vault.getDepositsByIndices(_singleton(idxs[i]));
            if (items.length > 0 && !items[0].processed && items[0].amount > 0) count++;
        }
    }

    function _userRedemptionPendingCount(address u) internal view returns (uint256 count) {
        uint256[] memory idxs = vault.getUserRedemptionIndices(u);
        for (uint256 i = 0; i < idxs.length; i++) {
            QueueManager.QueueItem[] memory items = vault.getRedemptionsByIndices(_singleton(idxs[i]));
            if (items.length > 0 && !items[0].processed) count++;
        }
    }

    function _singleton(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    function user(uint256 i) external view returns (address) {
        return users[i];
    }
}
