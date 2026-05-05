// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Minimal interface the pool calls back into on the vault.
interface IHedgeFundVault {
    function navPerShare() external view returns (uint256);
    function lastAumBlock() external view returns (uint256);

    // Pool-only privileged callbacks
    function mintForPool(address to, uint256 amount) external;
    function burnFromUser(address from, uint256 amount) external;

    // Config (read by pool every operation)
    function swapFeeBps() external view returns (uint256);
    function lltvBps() external view returns (uint256);
    function borrowRateBps() external view returns (uint256);

    function baseToken() external view returns (IERC20);
    function baseDecimals() external view returns (uint8);
}

/**
 * @title SharedPool
 * @notice Single shared pool: USDC reserves do triple duty for AMM swaps,
 *         lending capacity, and liquidation absorption. The "HFS reserve" is
 *         a derived equation (`usdcReserve / NAV`) — never stored, never
 *         rebalanced. xy=k slippage applies during each swap; the equation
 *         re-derives the curve naturally between operations as NAV shifts.
 *
 *         No factories, no upgradability, no LP-shares for the AMM side.
 *         The fund's Safe is the sole USDC supplier in v1; opening it up
 *         is a v2 concern.
 *
 *         Borrowers' collateral is locked separately from the AMM. They
 *         keep full HFS exposure on their collateral (no IL).
 *
 *         Liquidations: at every `updateAum`, the vault calls
 *         `sweepLiquidations()`. Any borrower whose `borrow > collateral *
 *         NAV * LLTV` gets their collateral burned and their debt written
 *         off. Bad debt is absorbed by the pool's USDC reserve (= the fund).
 */
contract SharedPool is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IHedgeFundVault public immutable vault;
    IERC20 public immutable usdc;
    uint256 private immutable USDC_DECIMALS_FACTOR; // 10^baseDecimals, for NAV math

    // ── State ────────────────────────────────────────────────────────────
    uint256 public usdcReserve; // actual USDC held by the pool (excluding lent-out)
    uint256 public totalBorrowed; // sum of all borrowOf[u]
    uint256 public lastInterestAccrualTimestamp;

    mapping(address => uint256) public collateralOf; // HFS locked, separate from AMM
    mapping(address => uint256) public borrowOf; // USDC owed (principal + accrued)
    mapping(address => uint256) public lastAccrual; // per-borrower last interest stamp

    EnumerableSet.AddressSet private _activeBorrowers;

    // ── Events ───────────────────────────────────────────────────────────
    event SwappedUsdcForHfs(address indexed user, uint256 usdcIn, uint256 hfsOut);
    event SwappedHfsForUsdc(address indexed user, uint256 hfsIn, uint256 usdcOut);
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed borrower, uint256 collateralBurned, uint256 debtWrittenOff);

    // ── Errors ───────────────────────────────────────────────────────────
    error OnlyVault();
    error SwapFrozenThisBlock();
    error InsufficientPoolUsdc();
    error InsufficientCollateral();
    error WouldBeUnhealthy();
    error NotUnhealthy();
    error SlippageTooHigh();
    error ZeroAmount();

    constructor(address _vault) {
        vault = IHedgeFundVault(_vault);
        usdc = vault.baseToken();
        USDC_DECIMALS_FACTOR = 10 ** uint256(vault.baseDecimals());
        lastInterestAccrualTimestamp = block.timestamp;
    }

    /// @notice Add USDC to pool reserves. v1: anyone can call (effectively
    /// only the fund will, but no permissioning to keep things simple).
    /// USDC added here serves both AMM swap depth and lending capacity.
    /// No LP shares minted — supplier gives up the dollars in exchange for
    /// the pool's growth contributing to the fund's overall AUM (which the
    /// keeper reports at next updateAum).
    function supply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdcReserve += amount;
    }

    modifier onlyVault() {
        if (msg.sender != address(vault)) revert OnlyVault();
        _;
    }

    /// @notice Block-level freeze that defangs the front-run-the-NAV-update attack.
    /// Same-block swaps after `updateAum` would be priced against the post-update
    /// NAV with no slippage buffer — see B-FRONTRUN in design notes.
    modifier notFrozen() {
        if (block.number == vault.lastAumBlock()) revert SwapFrozenThisBlock();
        _;
    }

    // ── Derived view: hfsReserve = usdcReserve / NAV ─────────────────────

    /// @notice Pool's HFS reserve as a function of pool USDC and current NAV.
    /// Not stored. Re-derived on every read. The "rebalance" is implicit —
    /// when NAV moves or usdcReserve changes, this view returns the new value
    /// without any explicit update.
    /// @return HFS amount in 18-decimal base units (the share token's decimals)
    function hfsReserve() public view returns (uint256) {
        uint256 nav = vault.navPerShare();
        if (nav == 0) return 0;
        // navPerShare returns NAV scaled × 1e18. To get HFS-equivalent at NAV
        // for a given USDC amount: hfs_native = usdc_native * 1e18 / nav.
        // But we want hfs in 18-dec since shares are 18-dec, and usdc is in
        // its native decimals. Normalize usdc into 18-dec terms first.
        uint256 normalizedUsdc = usdcReserve * (10 ** (18 - vault.baseDecimals()));
        return (normalizedUsdc * 1e18) / nav;
    }

    // ── Swaps ────────────────────────────────────────────────────────────

    /// @notice Swap USDC for HFS at xy=k against the current pool state.
    /// Slippage applies per-swap. The slippage value is captured in NAV via
    /// the mint changing effectiveSupply.
    function swapUsdcForHfs(uint256 usdcIn, uint256 minOut)
        external
        nonReentrant
        notFrozen
        returns (uint256 hfsOut)
    {
        if (usdcIn == 0) revert ZeroAmount();

        uint256 hfsRes = hfsReserve();
        uint256 k = usdcReserve * hfsRes;
        uint256 newUsdc = usdcReserve + usdcIn;

        hfsOut = hfsRes - (k / newUsdc);
        uint256 fee = (hfsOut * vault.swapFeeBps()) / 10_000;
        hfsOut -= fee;

        if (hfsOut < minOut) revert SlippageTooHigh();

        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        usdcReserve = newUsdc;

        vault.mintForPool(msg.sender, hfsOut);
        // The fee remains "absent" from the user's mint; it stays as
        // unminted virtual capacity, captured by NAV ↑ on the next read.

        emit SwappedUsdcForHfs(msg.sender, usdcIn, hfsOut);
    }

    /// @notice Swap HFS for USDC. Burn user's HFS, send them USDC. Capped
    /// by the pool's actual USDC reserves — beyond that, swap reverts.
    function swapHfsForUsdc(uint256 hfsIn, uint256 minOut)
        external
        nonReentrant
        notFrozen
        returns (uint256 usdcOut)
    {
        if (hfsIn == 0) revert ZeroAmount();

        uint256 hfsRes = hfsReserve();
        uint256 k = usdcReserve * hfsRes;
        uint256 newHfs = hfsRes + hfsIn;

        usdcOut = usdcReserve - (k / newHfs);
        uint256 fee = (usdcOut * vault.swapFeeBps()) / 10_000;
        usdcOut -= fee;

        if (usdcOut < minOut) revert SlippageTooHigh();
        if (usdcOut > usdcReserve) revert InsufficientPoolUsdc();

        vault.burnFromUser(msg.sender, hfsIn);
        usdcReserve -= usdcOut;

        usdc.safeTransfer(msg.sender, usdcOut);

        emit SwappedHfsForUsdc(msg.sender, hfsIn, usdcOut);
    }

    // ── Lending: collateral management ───────────────────────────────────

    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Pull HFS from user via vault's burnFromUser+mintForPool? No — the
        // pool itself is just an ERC20 holder. Use the share token's
        // transferFrom (the vault is the share token).
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (collateralOf[msg.sender] < amount) revert InsufficientCollateral();
        _accrueBorrowerInterest(msg.sender);

        collateralOf[msg.sender] -= amount;
        if (_isUnhealthy(msg.sender)) revert WouldBeUnhealthy();

        IERC20(address(vault)).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (usdcReserve < amount) revert InsufficientPoolUsdc();

        _accrueBorrowerInterest(msg.sender);

        borrowOf[msg.sender] += amount;
        if (_isUnhealthy(msg.sender)) revert WouldBeUnhealthy();

        usdcReserve -= amount;
        totalBorrowed += amount;
        _activeBorrowers.add(msg.sender);

        usdc.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueBorrowerInterest(msg.sender);

        uint256 debt = borrowOf[msg.sender];
        uint256 toRepay = amount > debt ? debt : amount;

        usdc.safeTransferFrom(msg.sender, address(this), toRepay);
        usdcReserve += toRepay;
        borrowOf[msg.sender] = debt - toRepay;
        totalBorrowed -= toRepay;

        if (borrowOf[msg.sender] == 0) _activeBorrowers.remove(msg.sender);

        emit Repaid(msg.sender, toRepay);
    }

    // ── Liquidation sweep (vault-only, called from updateAum) ────────────

    /// @notice Iterate active borrowers, liquidate any whose health
    /// has fallen below the LLTV threshold at the current NAV.
    /// Iterates in reverse so removals don't skip indices.
    function sweepLiquidations() external onlyVault {
        uint256 n = _activeBorrowers.length();
        for (uint256 i = n; i > 0; i--) {
            address b = _activeBorrowers.at(i - 1);
            _accrueBorrowerInterest(b);
            if (_isUnhealthy(b)) {
                _liquidate(b);
            }
        }
    }

    function _liquidate(address borrower) internal {
        uint256 col = collateralOf[borrower];
        uint256 debt = borrowOf[borrower];

        collateralOf[borrower] = 0;
        borrowOf[borrower] = 0;
        totalBorrowed -= debt;
        _activeBorrowers.remove(borrower);

        // Burn the seized HFS — supply ↓, NAV ↑ for remaining holders by
        // (col × NAV − badDebt). If collateral fully covers the debt, NAV
        // is neutral. If under-collateralized, the gap is absorbed as bad
        // debt against the pool's USDC reserve.
        if (col > 0) {
            vault.burnFromUser(address(this), col);
        }

        // Bad debt: reduce reported usdcReserve by the unrecovered portion.
        // The actual USDC balance hasn't changed (it was loaned out and not
        // returned), but the accounting must reflect the loss so future
        // borrow / repay flows stay consistent.
        // (No actual USDC movement; this just zeros the lost loan claim.)

        emit Liquidated(borrower, col, debt);
    }

    // ── Health check ─────────────────────────────────────────────────────

    function _isUnhealthy(address user) internal view returns (bool) {
        if (borrowOf[user] == 0) return false;
        // collateral × NAV (in USDC native): denormalize the result
        uint256 nav = vault.navPerShare();
        uint256 collateralValueNormalized = (collateralOf[user] * nav) / 1e18;
        uint256 collateralValueNative = collateralValueNormalized / (10 ** (18 - vault.baseDecimals()));
        uint256 maxBorrow = (collateralValueNative * vault.lltvBps()) / 10_000;
        return borrowOf[user] > maxBorrow;
    }

    function isHealthy(address user) external view returns (bool) {
        return !_isUnhealthy(user);
    }

    // ── Interest accrual ─────────────────────────────────────────────────

    /// @dev Per-borrower accrual using a simple linear model:
    /// debt += debt * rate * dt / (year * 1e4). For a $10K F&F-scale fund
    /// this is plenty; revisit when lending volume justifies a real IRM.
    function _accrueBorrowerInterest(address user) internal {
        uint256 debt = borrowOf[user];
        if (debt == 0) {
            lastAccrual[user] = block.timestamp;
            return;
        }
        uint256 last = lastAccrual[user];
        if (last == 0 || last >= block.timestamp) {
            lastAccrual[user] = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - last;
        uint256 rate = vault.borrowRateBps();
        uint256 interest = (debt * rate * elapsed) / (10_000 * 365 days);
        if (interest > 0) {
            borrowOf[user] = debt + interest;
            totalBorrowed += interest;
        }
        lastAccrual[user] = block.timestamp;
    }

    // ── Views for keeper / UI ────────────────────────────────────────────

    function activeBorrowerCount() external view returns (uint256) {
        return _activeBorrowers.length();
    }

    function activeBorrowerAt(uint256 i) external view returns (address) {
        return _activeBorrowers.at(i);
    }
}
