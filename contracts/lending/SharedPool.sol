// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Minimal interface the pool calls back into on the vault.
/// All `*ForPool` / `*FromUser` / `*ToAum` functions are pool-only on the
/// vault side — the vault enforces that via an onlyPool modifier checking
/// sharedPool address.
interface IHedgeFundVault {
    function navPerShare() external view returns (uint256);
    function lastAumBlock() external view returns (uint256);

    // Privileged supply / burn callbacks
    function mintForPool(address to, uint256 amount) external;
    function burnFromUser(address from, uint256 amount) external;

    // AUM accounting callbacks. Called by the pool when an event changes
    // total fund USDC value in a way that doesn't auto-balance against
    // supply changes. Keeps fs.aum in sync between keeper updates.
    //
    // Used by:
    //   - swapUsdcForHfs:   addToAum(usdcIn)   (USDC enters fund)
    //   - swapHfsForUsdc:   subFromAum(usdcOut) (USDC leaves fund)
    //   - sweepLiquidations: subFromAum(debt)  (loan claim written off)
    //
    // NOT called by borrow/repay (those are net-zero: USDC out matched
    // by an equivalent loan-claim asset; total fund value unchanged).
    function addToAum(uint256 amount) external;
    function subFromAum(uint256 amount) external;

    // Config (read on each operation; ConfigManager-controlled with timelock)
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

    // ── State ────────────────────────────────────────────────────────────
    /// @notice Pool's actual USDC balance (= USDC the pool holds and can
    /// pay out). This tracks `usdc.balanceOf(address(this))` minus any
    /// stuck dust. Borrowed USDC is OUT of the pool but still part of
    /// fund AUM as a loan claim (see `totalBorrowed`).
    uint256 public usdcReserve;

    /// @notice Sum of all outstanding borrowOf[user]. Tracks the principal
    /// + accrued interest the pool is owed by all borrowers.
    uint256 public totalBorrowed;

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
    ///
    /// Math:
    ///   hfsRes_pre = usdcReserve_pre / NAV   (derived equation)
    ///   k = usdcReserve_pre * hfsRes_pre
    ///   newUsdc = usdcReserve_pre + usdcIn
    ///   hfsOut_pure = hfsRes_pre - k / newUsdc      (xy=k slippage)
    ///   hfsOut = hfsOut_pure * (1 - swapFeeBps/10000)  (fee retained)
    ///
    /// AUM accounting:
    ///   The user paid `usdcIn` USDC into the pool (fund-controlled).
    ///   The pool minted `hfsOut` HFS, increasing supply.
    ///   For NAV = AUM/supply to stay correct between keeper updates, AUM
    ///   must increase by `usdcIn` at the same time supply increases by
    ///   `hfsOut`. We do both in this function.
    ///
    ///   Net NAV effect: NAV ↑ by exactly the slippage value (because the
    ///   user paid more USDC per HFS than NAV-fair-price). That value
    ///   accrues to existing HFS holders.
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

        // Track AUM and supply changes atomically. Order matters: addToAum
        // first so by the time mintForPool reads NAV (it doesn't here, but
        // any external observer between them would see consistent state).
        vault.addToAum(usdcIn);
        vault.mintForPool(msg.sender, hfsOut);

        emit SwappedUsdcForHfs(msg.sender, usdcIn, hfsOut);
    }

    /// @notice Swap HFS for USDC. Burn user's HFS, send them USDC. Capped
    /// by the pool's actual USDC reserves — beyond that, swap reverts and
    /// the user falls back to the redemption queue for vault.redeem().
    ///
    /// AUM accounting:
    ///   The pool burned `hfsIn` HFS, decreasing supply.
    ///   The pool sent `usdcOut` USDC out (fund USDC down).
    ///   For NAV preservation, AUM decreases by `usdcOut` while supply
    ///   decreases by `hfsIn`. The slippage means usdcOut/hfsIn < NAV,
    ///   which makes NAV ↑ for remaining holders (same direction as the
    ///   USDC→HFS case — slippage always favors holders).
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

        // Burn first so supply drops before AUM does (consistent ordering
        // with the swap-in case).
        vault.burnFromUser(msg.sender, hfsIn);
        vault.subFromAum(usdcOut);
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

    /// @dev Liquidate one position.
    ///
    /// Mechanics:
    ///   - Burn the borrower's `col` HFS collateral (supply ↓).
    ///   - Write off `debt` USDC of loan claim (AUM ↓ by debt).
    ///   - No actual USDC movement here: the USDC was already loaned out
    ///     to the borrower; we just stop expecting it back.
    ///
    /// At the LLTV threshold (default 50%), col × NAV = 2 × debt, so the
    /// fund effectively gains `debt` of value: it loses `debt` of loan
    /// claim but reduces supply by col HFS worth `col × NAV = 2 × debt`.
    /// Existing holders capture the gain via NAV ↑.
    ///
    /// In a bad-debt event (collateral has crashed below debt value), the
    /// fund absorbs the gap. fs.aum drops by debt; supply drops by col ×
    /// NAV which is now less than debt. NAV ↓ for existing holders.
    function _liquidate(address borrower) internal {
        uint256 col = collateralOf[borrower];
        uint256 debt = borrowOf[borrower];

        collateralOf[borrower] = 0;
        borrowOf[borrower] = 0;
        totalBorrowed -= debt;
        _activeBorrowers.remove(borrower);

        // Burn the seized HFS (collateral was held in pool's HFS balance).
        if (col > 0) {
            vault.burnFromUser(address(this), col);
        }

        // Write off the loan from AUM. The USDC was lent out and not
        // recovered — it's gone from the fund's balance sheet. fs.aum
        // drops by debt to reflect.
        if (debt > 0) {
            vault.subFromAum(debt);
        }

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
