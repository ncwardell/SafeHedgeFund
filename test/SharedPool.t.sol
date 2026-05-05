// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

import "../contracts/SafeHedgeFundVault.sol";
import "../contracts/lending/SharedPool.sol";
import "./mocks/MockSafe.sol";
import "./mocks/MockUSDC.sol";

contract SharedPoolTest is Test {
    SafeHedgeFundVault internal vault;
    SharedPool internal pool;
    MockSafe internal safe;
    MockUSDC internal usdc;

    address internal admin = address(this);
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal rescueTreasury = makeAddr("rescueTreasury");
    address internal aumUpdater = makeAddr("aumUpdater");
    address internal processor = makeAddr("processor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant MIN_DEPOSIT = 100e6;
    uint256 internal constant MIN_REDEMPTION = 10e6;

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

        // Past cooldown for any config proposal
        vm.warp(6 days);

        // Bootstrap AUM
        usdc.mint(address(safe), 1e6);
        vm.prank(aumUpdater);
        vault.updateAum(1e6);

        // Deploy pool, wire it
        pool = new SharedPool(address(vault));
        vault.setSharedPool(address(pool));

        // Set lending config (timelock + execute)
        _setConfig("swapFeeBps", 30);   // 0.30%
        _setConfig("lltvBps", 5000);    // 50%
        _setConfig("borrowRateBps", 800); // 8% APR

        // Seed users with USDC
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);

        // Fund the pool with USDC liquidity (Safe is the LP for v1).
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(pool), 100_000e6);
        pool.supply(100_000e6);
    }

    function _setConfig(string memory key, uint256 value) internal {
        vault.proposeConfigChange(key, value);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeConfigProposal(key, value);
        // Refresh AUM so other tests don't trip aumNotStale
        uint256 aum = usdc.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(aum);
    }

    function _aliceDepositsForShares(uint256 amountUsdc) internal returns (uint256 sharesMinted) {
        vm.startPrank(alice);
        usdc.approve(address(vault), amountUsdc);
        vault.deposit(amountUsdc, 0);
        vm.stopPrank();
        vm.prank(processor);
        vault.processDepositQueue(1);
        sharesMinted = vault.balanceOf(alice);

        uint256 newAum = usdc.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(newAum);
    }

    // ── hfsReserve is a derived equation ────────────────────────────────

    function test_hfsReserve_isDerivedFromUsdcAndNav() public view {
        // Pool has 100_000e6 USDC. NAV is some value ~1.
        uint256 nav = vault.navPerShare();
        uint256 expected = (pool.usdcReserve() * 1e12 * 1e18) / nav; // 1e12 = 10^(18-6)
        assertEq(pool.hfsReserve(), expected, "hfsReserve = usdcReserve / NAV");
    }

    // ── Swap USDC → HFS ─────────────────────────────────────────────────

    function test_swap_usdcForHfs_appliesSlippage() public {
        // Skip past the same-block freeze from setUp's last updateAum
        vm.roll(block.number + 1);

        uint256 usdcIn = 1_000e6;
        uint256 hfsResBefore = pool.hfsReserve();
        uint256 usdcResBefore = pool.usdcReserve();
        uint256 k = usdcResBefore * hfsResBefore;

        vm.startPrank(alice);
        usdc.approve(address(pool), usdcIn);
        uint256 hfsOut = pool.swapUsdcForHfs(usdcIn, 0);
        vm.stopPrank();

        // xy=k expectation (no fee): hfsOut_pure = hfsRes - k/(usdc+in)
        uint256 hfsOutPure = hfsResBefore - (k / (usdcResBefore + usdcIn));
        // With 30 bps fee: hfsOut = hfsOutPure * 99.7%
        uint256 expected = (hfsOutPure * 9970) / 10_000;

        assertApproxEqAbs(hfsOut, expected, 10, "slippage + fee applied");
        assertEq(vault.balanceOf(alice), hfsOut, "user got minted HFS");
        assertEq(pool.usdcReserve(), usdcResBefore + usdcIn, "USDC reserve up by usdcIn");
    }

    function test_swap_slippageCapturedInPoolUsdc() public {
        vm.roll(block.number + 1);

        uint256 poolUsdcBefore = pool.usdcReserve();

        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        uint256 hfsOut = pool.swapUsdcForHfs(1_000e6, 0);
        vm.stopPrank();

        // The pool USDC went up by full usdcIn (= 1_000e6). The user got
        // hfsOut HFS, which is less than usdcIn / NAV (slippage). So the
        // slippage value sits in the pool's USDC reserve, waiting to be
        // reflected in AUM at next updateAum. NAV itself is a step function
        // that doesn't change until updateAum runs.
        assertEq(pool.usdcReserve() - poolUsdcBefore, 1_000e6, "full usdcIn captured in pool");

        // Sanity: hfsOut is less than the no-slippage no-fee equivalent.
        uint256 nav = vault.navPerShare();
        uint256 hfsOutFair = (1_000e6 * 1e12 * 1e18) / nav; // 1_000e6 native at NAV
        assertLt(hfsOut, hfsOutFair, "user took slippage haircut");
    }

    // ── hfsReserve auto-updates without rebalance ───────────────────────

    function test_hfsReserve_autoTracksAfterSwap() public {
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        pool.swapUsdcForHfs(1_000e6, 0);
        vm.stopPrank();

        // After swap, hfsReserve() should equal the NEW usdcReserve / NEW NAV
        // (no rebalance function was called)
        uint256 expected = (pool.usdcReserve() * 1e12 * 1e18) / vault.navPerShare();
        assertEq(pool.hfsReserve(), expected, "hfsReserve auto-derived");
    }

    // ── Borrow + repay flow ─────────────────────────────────────────────

    function test_borrow_repay() public {
        // Alice gets HFS shares first
        uint256 shares = _aliceDepositsForShares(10_000e6);
        vm.roll(block.number + 1);

        // Use half as collateral, borrow against it
        uint256 toCollateralize = shares / 2;

        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(pool), toCollateralize);
        pool.depositCollateral(toCollateralize);

        // At LLTV 50%, max borrow = 50% of collateralValue
        // collateralValue ≈ toCollateralize * NAV
        uint256 borrowAmount = 1_000e6;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        pool.borrow(borrowAmount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, borrowAmount, "got loan USDC");
        assertEq(pool.borrowOf(alice), borrowAmount, "debt tracked");
        assertEq(pool.activeBorrowerCount(), 1, "alice in active set");

        // Repay
        vm.startPrank(alice);
        usdc.approve(address(pool), borrowAmount);
        pool.repay(borrowAmount);
        vm.stopPrank();

        assertEq(pool.borrowOf(alice), 0, "debt cleared");
        assertEq(pool.activeBorrowerCount(), 0, "alice out of active set");
    }

    // ── Liquidation sweep on updateAum ──────────────────────────────────

    function test_sweepLiquidations_onAumUpdate() public {
        uint256 shares = _aliceDepositsForShares(10_000e6);
        vm.roll(block.number + 1);

        // Alice borrows close to LLTV
        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(pool), shares);
        pool.depositCollateral(shares);
        // shares ≈ 10_000 USDC value. LLTV 50% → max 5_000 USDC borrow.
        // Borrow 4_500 (90% of LLTV).
        pool.borrow(4_500e6);
        vm.stopPrank();

        assertEq(pool.activeBorrowerCount(), 1);

        // Crash NAV by reporting halved AUM
        uint256 currentSafe = usdc.balanceOf(address(safe));
        uint256 halvedAum = currentSafe / 2;
        // Burn off the difference so onChain check passes
        vm.prank(address(safe));
        usdc.transfer(address(0xdead), currentSafe - halvedAum);

        // updateAum triggers sweep
        vm.prank(aumUpdater);
        vault.updateAum(halvedAum);

        // Alice was 90% LTV at $1 NAV; after halving, she's at 180% LTV.
        // Far above the 50% LLTV threshold → liquidated.
        assertEq(pool.activeBorrowerCount(), 0, "alice liquidated");
        assertEq(pool.borrowOf(alice), 0, "debt cleared");
        assertEq(pool.collateralOf(alice), 0, "collateral seized");
    }

    // ── Block-level swap freeze ─────────────────────────────────────────

    function test_swapFrozen_inSameBlockAsUpdateAum() public {
        // Update AUM (sets lastAumBlock = current block)
        uint256 aum = usdc.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(aum);

        // Try to swap in the same block — should revert
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(SharedPool.SwapFrozenThisBlock.selector);
        pool.swapUsdcForHfs(1_000e6, 0);
        vm.stopPrank();

        // Move forward a block — swap works
        vm.roll(block.number + 1);
        vm.startPrank(alice);
        pool.swapUsdcForHfs(1_000e6, 0);
        vm.stopPrank();
    }

    // ── Borrow exceeding LLTV reverts ───────────────────────────────────

    function test_borrow_revertsAboveLltv() public {
        uint256 shares = _aliceDepositsForShares(1_000e6);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        IERC20(address(vault)).approve(address(pool), shares);
        pool.depositCollateral(shares);
        // Try to borrow more than LLTV allows
        vm.expectRevert(SharedPool.WouldBeUnhealthy.selector);
        pool.borrow(900e6); // 90% of $1000 worth of HFS, exceeds 50% LLTV
        vm.stopPrank();
    }
}
