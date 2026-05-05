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
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

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

        // Wire Safe → vault as enabled module so payouts work.
        safe.enableModule(address(vault));

        vault.grantRole(vault.AUM_UPDATER_ROLE(), aumUpdater);
        vault.grantRole(vault.PROCESSOR_ROLE(), processor);

        // Seed users.
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);

        // Seed initial AUM (matches on-chain liquidity = 0 to start, must be > 0)
        // We can't call updateAum(0), so we mint a tiny seed to the Safe and call updateAum.
        usdc.mint(address(safe), 1e6);
        vm.prank(aumUpdater);
        vault.updateAum(1e6);
    }

    /// @notice Regression test for B1 (head-pointer drift in batch deposit processing).
    /// Two users deposit; both items end up in the queue. After processing, BOTH
    /// users must hold shares and tokens must have moved to the Safe. Pre-fix,
    /// the post-cleanup head pointer caused _processDepositMints to look past
    /// the items that were just processed → no shares minted, tokens stuck.
    function test_B1_batchProcessing_mintsAllItems() public {
        uint256 depositAmount = 1_000e6; // 1000 USDC

        // Two users queue deposits.
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, 0);
        vm.stopPrank();

        (uint256 depQ, ) = vault.queueLengths();
        assertEq(depQ, 2, "queue should have 2 items pre-process");

        uint256 safeBalBefore = usdc.balanceOf(address(safe));
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        assertEq(vaultBalBefore, 2 * depositAmount, "vault should hold both deposits");

        // Process both.
        vm.prank(processor);
        vault.processDepositQueue(2);

        // Both users must now hold shares.
        assertGt(vault.balanceOf(alice), 0, "alice should have shares");
        assertGt(vault.balanceOf(bob), 0, "bob should have shares");

        // Tokens should have moved from vault to Safe.
        assertEq(usdc.balanceOf(address(vault)), 0, "vault should be empty");
        assertEq(
            usdc.balanceOf(address(safe)),
            safeBalBefore + 2 * depositAmount,
            "safe should hold both deposits"
        );

        // Queue should be drained.
        (depQ, ) = vault.queueLengths();
        assertEq(depQ, 0, "queue should be empty post-process");
    }

    /// @notice Single-deposit golden path: deposit → process → redeem → process.
    function test_depositAndRedeemFlow() public {
        uint256 depositAmount = 1_000e6;

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, 0);
        vm.stopPrank();

        vm.prank(processor);
        vault.processDepositQueue(1);

        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0, "alice has shares");

        // Update AUM to reflect the new deposit (Safe now holds 1e6 + 1000e6).
        uint256 newAum = usdc.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(newAum);

        // Redeem all shares — autoPayout is off by default → goes to queue.
        vm.prank(alice);
        vault.redeem(shares, 0);

        ( , uint256 redQ) = vault.queueLengths();
        assertEq(redQ, 1, "redemption queued");

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(processor);
        vault.processRedemptionQueue(1);

        assertGt(usdc.balanceOf(alice) - aliceBalBefore, 0, "alice received payout from Safe");
        assertEq(vault.balanceOf(alice), 0, "alice's shares burned");
    }
}
