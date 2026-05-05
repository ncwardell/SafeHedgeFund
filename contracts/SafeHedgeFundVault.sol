// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./core/ConfigManager.sol";
import "./core/FeeManager.sol";
import "./core/QueueManager.sol";
import "./core/EmergencyManager.sol";

contract SafeHedgeFundVault is
    ERC20,
    ERC20Burnable,
    ReentrancyGuard,
    Pausable,
    AccessControl
{
    using SafeERC20 for IERC20;
    using ConfigManager for ConfigManager.ConfigStorage;
    using FeeManager for FeeManager.FeeStorage;
    using QueueManager for QueueManager.QueueStorage;
    using EmergencyManager for EmergencyManager.EmergencyStorage;

    // Inlined from ViewHelper
    struct FundConfig {
        uint256 managementFeeBps;
        uint256 performanceFeeBps;
        uint256 entranceFeeBps;
        uint256 exitFeeBps;
        uint256 targetLiquidityBps;
        uint256 minDeposit;
        uint256 minRedemption;
        uint256 maxAumAge;
        uint256 maxBatchSize;
        uint256 hwmDrawdownPct;
        uint256 hwmRecoveryPct;
        uint256 hwmRecoveryPeriod;
        bool autoProcessDeposits;
        bool autoPayoutRedemptions;
        address feeRecipient;
        address rescueTreasury;
        uint256 lastAumUpdate;
    }

    error ZeroAddress();
    error BelowMinimum();
    error InvalidShares();
    error SlippageTooHigh();
    error AUMStale();
    error AUMZero();
    error AUMBelowOnChain();
    error ModuleNotEnabled();
    error CannotRescueBase();
    error NotPaused();
    error ThresholdNotMet();
    error InEmergencyMode();
    error UnsupportedTokenDecimals();
    error ProposalFailed(string reason);
    error ZeroSharesCalculated();
    error ZeroAmountCalculated();

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUM_UPDATER_ROLE = keccak256("AUM_UPDATER_ROLE");
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    ConfigManager.ConfigStorage private configStorage;
    FeeManager.FeeStorage private feeStorage;
    QueueManager.QueueStorage private queueStorage;
    EmergencyManager.EmergencyStorage private emergencyStorage;

    uint256 public minDeposit;
    uint256 public minRedemption;
    address public feeRecipient;
    address public rescueTreasury;
    bool public autoProcessDeposits;
    bool public autoPayoutRedemptions;

    uint256 public maxAumAge;
    uint256 public maxBatchSize;

    IERC20 public immutable baseToken;
    address public immutable safeWallet;
    uint8 public immutable baseDecimals;
    uint256 private immutable DECIMAL_FACTOR;

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Redeemed(address indexed user, uint256 shares, uint256 amount);
    event AumUpdated(uint256 aum, uint256 nav);
    event FeesPaid(uint256 amount);
    event FeePaymentPartial(uint256 vaultPaid, uint256 safeFailed);
    event TokensRescued(address indexed token, uint256 amount);
    event ETHRescued(uint256 amount);
    event DepositAutoProcessFailed(address indexed user, uint256 amount, string reason);
    event RedemptionAutoPayoutFailed(address indexed user, uint256 shares, string reason);
    event DepositSkipped(uint256 indexed queueIdx, address indexed user, uint256 amount, string reason);
    event RedemptionSkipped(uint256 indexed queueIdx, address indexed user, uint256 shares, string reason);
    event PayoutFailed(address indexed user, uint256 amount, string reason);
    event ProposalExecutionFailed(bytes32 indexed id, string reason);
    event Initialized(uint256 timestamp);

    constructor(
        address _baseToken,
        address _safeWallet,
        address _feeRecipient,
        address _rescueTreasury,
        uint256 _minDeposit,
        uint256 _minRedemption
    ) ERC20("HedgeFund Shares", "HFS") {
        if (_baseToken == address(0)) revert ZeroAddress();
        if (_safeWallet == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_rescueTreasury == address(0)) revert ZeroAddress();

        baseToken = IERC20(_baseToken);
        safeWallet = _safeWallet;
        feeRecipient = _feeRecipient;
        rescueTreasury = _rescueTreasury;
        minDeposit = _minDeposit;
        minRedemption = _minRedemption;

        uint8 decimals = _getDecimals(_baseToken);
        if (decimals > 18) revert UnsupportedTokenDecimals();
        baseDecimals = decimals;
        DECIMAL_FACTOR = 10 ** (18 - decimals);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        maxAumAge = 3 days;
        maxBatchSize = 50;
        feeStorage.targetLiquidityBps = 500;
        feeStorage.hwmDrawdownPct = 6000;
        feeStorage.hwmRecoveryPct = 500;
        feeStorage.hwmRecoveryPeriod = 90 days;

        feeStorage.decimalFactor = DECIMAL_FACTOR;

        emit Initialized(block.timestamp);
    }

    modifier aumNotStale() {
        if (block.timestamp > feeStorage.aumTimestamp + maxAumAge) revert AUMStale();
        _;
    }

    modifier aumInitialized() {
        if (feeStorage.aumTimestamp == 0) revert AUMZero();
        _;
    }

    modifier whenNotEmergency() {
        if (emergencyStorage.emergencyMode) revert InEmergencyMode();
        _;
    }

    modifier moduleEnabled() {
        if (!isModuleEnabled()) revert ModuleNotEnabled();
        _;
    }

    function deposit(uint256 amount, uint256 minShares)
        external
        nonReentrant
        whenNotPaused
        whenNotEmergency
        aumInitialized
        aumNotStale
    {
        if (amount < minDeposit) revert BelowMinimum();

        baseToken.safeTransferFrom(msg.sender, address(this), amount);
        queueStorage.queueDeposit(msg.sender, amount, navPerShare(), minShares);

        if (autoProcessDeposits) {
            _tryAutoProcessDeposit(queueStorage.depositQueueTail - 1);
        }
    }

    function redeem(uint256 shares, uint256 minAmountOut)
        external
        whenNotPaused
        whenNotEmergency
        aumNotStale
        nonReentrant
    {
        if (shares == 0 || balanceOf(msg.sender) < shares) revert InvalidShares();

        uint256 nav = navPerShare();
        uint256 gross = (shares * nav) / 1e18;
        (uint256 net, ) = feeStorage.accrueExitFee(gross);

        if (net == 0) revert ZeroAmountCalculated();

        uint256 payout = _denormalize(net);
        if (payout < minRedemption) revert BelowMinimum();
        if (payout < minAmountOut) revert SlippageTooHigh();

        _burn(msg.sender, shares);

        if (autoPayoutRedemptions) {
            (bool ok, uint256 paid) = _payout(msg.sender, shares, nav);
            if (ok) {
                emit Redeemed(msg.sender, shares, paid);
                return;
            } else {
                emit RedemptionAutoPayoutFailed(msg.sender, shares, "Safe payout failed");
            }
        }

        queueStorage.queueRedemption(msg.sender, shares, nav, minAmountOut);
    }

    function updateAum(uint256 newAum) external onlyRole(AUM_UPDATER_ROLE) {
        uint256 onChain = _getTotalOnChainLiquidity();
        (uint256 adjustedAum, uint256 newNav) = feeStorage.accrueFeesOnAumUpdate(
            newAum,
            totalSupply(),
            onChain,
            _normalize,
            _denormalize
        );

        emit AumUpdated(adjustedAum, newNav);
    }

    function processDepositQueue(uint256 maxToProcess)
        external
        onlyRole(PROCESSOR_ROLE)
        whenNotPaused
        whenNotEmergency
        aumNotStale
        nonReentrant
    {
        uint256 nav = navPerShare();

        queueStorage.processDepositBatch(
            maxToProcess,
            nav,
            _normalize,
            _accrueEntranceFee,
            _mintAndDeploy,
            _emitDepositSkipped,
            _getMaxBatchSize
        );
    }

    function processRedemptionQueue(uint256 maxToProcess)
        external
        onlyRole(PROCESSOR_ROLE)
        whenNotPaused
        whenNotEmergency
        aumNotStale
        nonReentrant
    {
        queueStorage.processRedemptionBatch(
            maxToProcess,
            _payout,
            _emitRedemptionSkipped,
            _getMaxBatchSize
        );
    }

    function cancelMyDeposits(uint256 maxCancellations) external nonReentrant {
        queueStorage.cancelDeposits(msg.sender, maxCancellations, _transferBack);
    }

    function cancelMyRedemptions(uint256 maxCancellations) external nonReentrant {
        queueStorage.cancelRedemptions(msg.sender, maxCancellations, _mintBack);
    }

    function cancelDepositByIndex(uint256 queueIdx)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        queueStorage.cancelDepositByIndex(queueIdx, _transferBack);
    }

    function cancelRedemptionByIndex(uint256 queueIdx)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        queueStorage.cancelRedemptionByIndex(queueIdx, _mintBack);
    }

    function batchCancelDeposits(uint256[] calldata indices)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        queueStorage.batchCancelDeposits(indices, _transferBack);
    }

    function batchCancelRedemptions(uint256[] calldata indices)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        queueStorage.batchCancelRedemptions(indices, _mintBack);
    }

    function payoutAccruedFees() external onlyRole(ADMIN_ROLE) nonReentrant {
        feeStorage.payoutFees(
            baseToken,
            feeRecipient,
            safeWallet,
            isModuleEnabled,
            _denormalize
        );
    }

    function proposeConfigChange(string memory key, uint256 value)
        external
        onlyRole(ADMIN_ROLE)
    {
        configStorage.proposeChange(key, value);
    }

    function executeConfigProposal(string memory key, uint256 value)
        external
        onlyRole(ADMIN_ROLE)
    {
        (bytes32 keyHash, uint256 newValue) = configStorage.executeProposal(key, value);
        _applyConfigChange(keyHash, newValue);
    }

    function cancelConfigProposal(string memory key, uint256 value)
        external
        onlyRole(ADMIN_ROLE)
    {
        configStorage.cancelProposal(key, value);
    }

    function _applyConfigChange(bytes32 keyHash, uint256 value) internal {
        // Inlined from AdminHelper
        if (keyHash == keccak256("mgmt")) {
            feeStorage.managementFeeBps = value;
        } else if (keyHash == keccak256("perf")) {
            feeStorage.performanceFeeBps = value;
        } else if (keyHash == keccak256("entrance")) {
            feeStorage.entranceFeeBps = value;
        } else if (keyHash == keccak256("exit")) {
            feeStorage.exitFeeBps = value;
        } else if (keyHash == keccak256("targetLiquidity")) {
            feeStorage.targetLiquidityBps = value;
        } else if (keyHash == keccak256("minDeposit")) {
            minDeposit = value;
        } else if (keyHash == keccak256("minRedemption")) {
            minRedemption = value;
        } else if (keyHash == keccak256("maxAumAge")) {
            maxAumAge = value;
        } else if (keyHash == keccak256("maxBatchSize")) {
            maxBatchSize = value;
        } else if (keyHash == keccak256("hwmDrawdownPct")) {
            feeStorage.hwmDrawdownPct = value;
        } else if (keyHash == keccak256("hwmRecoveryPct")) {
            feeStorage.hwmRecoveryPct = value;
        } else if (keyHash == keccak256("hwmRecoveryPeriod")) {
            feeStorage.hwmRecoveryPeriod = value;
        }
    }

    function triggerEmergency()
        external
        onlyRole(GUARDIAN_ROLE)
        whenPaused
    {
        uint256 currentAum = getTotalAum();
        emergencyStorage.triggerEmergency(currentAum);
    }

    function checkEmergencyThreshold() external {
        uint256 currentAum = getTotalAum();
        emergencyStorage.checkEmergencyThreshold(
            paused(),
            currentAum,
            feeStorage.aumTimestamp
        );
    }

    function exitEmergency() external onlyRole(ADMIN_ROLE) {
        emergencyStorage.exitEmergency();
    }

    function emergencyWithdraw(uint256 shares) external nonReentrant {
        uint256 currentAum = getTotalAum();
        emergencyStorage.emergencyWithdraw(
            shares,
            totalSupply(),
            currentAum,
            _burnShares,
            _emergencyPayout
        );
    }

    function isEmergencyActive() external view returns (bool) {
        return emergencyStorage.emergencyMode;
    }

    function emergencyInfo()
        external
        view
        returns (bool active, uint256 snapshot, uint256 withdrawn, uint256 pauseTime)
    {
        active = emergencyStorage.emergencyMode;
        snapshot = emergencyStorage.emergencySnapshot;
        withdrawn = emergencyStorage.emergencyTotalWithdrawn;
        pauseTime = emergencyStorage.pauseTimestamp;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emergencyStorage.pauseTimestamp = block.timestamp;
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setAutoProcess(bool deposits, bool redemptions) external onlyRole(ADMIN_ROLE) {
        autoProcessDeposits = deposits;
        autoPayoutRedemptions = redemptions;
    }

    function setAutoProcessGuardian(bool deposits, bool redemptions) external onlyRole(GUARDIAN_ROLE) {
        autoProcessDeposits = deposits;
        autoPayoutRedemptions = redemptions;
    }

    function rescueERC20(address token, uint256 amount) external onlyRole(ADMIN_ROLE) {
        // Inlined from AdminHelper
        if (token == address(baseToken)) revert CannotRescueBase();
        IERC20(token).safeTransfer(rescueTreasury, amount);
        emit TokensRescued(token, amount);
    }

    function rescueETH() external onlyRole(ADMIN_ROLE) {
        // Inlined from AdminHelper
        uint256 bal = address(this).balance;
        if (bal > 0) {
            payable(rescueTreasury).transfer(bal);
            emit ETHRescued(bal);
        }
    }

    function _tryAutoProcessDeposit(uint256 queueIdx) internal {
        (bool ok, uint256 shares, uint256 netNative) = queueStorage.processSingleDeposit(
            queueIdx,
            navPerShare(),
            _normalize,
            _denormalize,
            _accrueEntranceFee
        );

        if (ok) {
            if (shares == 0) {
                emit DepositAutoProcessFailed(
                    queueStorage.depositQueue[queueIdx].user,
                    queueStorage.depositQueue[queueIdx].amount,
                    "zero shares calculated"
                );
                return;
            }

            address user = queueStorage.depositQueue[queueIdx].user;
            uint256 amount = queueStorage.depositQueue[queueIdx].amount;

            _mint(user, shares);

            baseToken.safeTransfer(safeWallet, netNative);

            emit Deposited(user, amount, shares);
        } else {
            emit DepositAutoProcessFailed(
                queueStorage.depositQueue[queueIdx].user,
                queueStorage.depositQueue[queueIdx].amount,
                "slippage"
            );
        }
    }

    /// @dev Callback invoked from QueueManager.processDepositBatch once a
    /// queue item has cleared its slippage check and had its entrance fee
    /// accrued. Single source of truth for share minting + Safe deployment.
    function _mintAndDeploy(
        address user,
        uint256 originalAmount,
        uint256 shares,
        uint256 netAmountNative
    ) internal {
        _mint(user, shares);
        baseToken.safeTransfer(safeWallet, netAmountNative);
        emit Deposited(user, originalAmount, shares);
    }

    function _payout(address user, uint256 shares, uint256 nav)
        internal
        returns (bool success, uint256 netAmount)
    {
        uint256 gross = (shares * nav) / 1e18;
        (uint256 net, uint256 feeNative) = feeStorage.accrueExitFee(gross);
        netAmount = _denormalize(net);

        uint256 userBalBefore = baseToken.balanceOf(user);

        bytes memory userData = abi.encodeWithSelector(IERC20.transfer.selector, user, netAmount);
        (success, ) = safeWallet.call(
            abi.encodeWithSignature(
                "execTransactionFromModule(address,uint256,bytes,uint8)",
                address(baseToken), 0, userData, 0
            )
        );

        if (success) {
            uint256 userBalAfter = baseToken.balanceOf(user);
            success = (userBalAfter >= userBalBefore + netAmount);
        }

        if (success && feeNative > 0) {
            bytes memory feeData = abi.encodeWithSelector(IERC20.transfer.selector, address(this), feeNative);
            (bool feeOk, ) = safeWallet.call(
                abi.encodeWithSignature(
                    "execTransactionFromModule(address,uint256,bytes,uint8)",
                    address(baseToken), 0, feeData, 0
                )
            );
            if (feeOk) {
                feeStorage.accruedExitFees += feeNative;
            }
        }
    }

    function _emergencyPayout(address user, uint256 amount) internal {
        EmergencyManager.executePayout(baseToken, user, amount, safeWallet, isModuleEnabled);
    }

    function _transferBack(address user, uint256 amount) internal {
        baseToken.safeTransfer(user, amount);
    }

    function _mintBack(address user, uint256 shares) internal {
        _mint(user, shares);
    }

    function _burnShares(address user, uint256 shares) internal {
        _burn(user, shares);
    }

    function _emitDepositSkipped(uint256 idx, address user, uint256 amount, string memory reason) internal {
        emit DepositSkipped(idx, user, amount, reason);
    }

    function _emitRedemptionSkipped(uint256 idx, address user, uint256 shares, string memory reason) internal {
        emit RedemptionSkipped(idx, user, shares, reason);
    }

    function _getMaxBatchSize() internal view returns (uint256) {
        return maxBatchSize;
    }

    function _accrueEntranceFee(uint256 amount) internal returns (uint256, uint256) {
        return feeStorage.accrueEntranceFee(amount);
    }

    function _emitDeposited(address user, uint256 amount, uint256 shares) internal {
        emit Deposited(user, amount, shares);
    }

    function _emitTokensRescued(address token, uint256 amount) internal {
        emit TokensRescued(token, amount);
    }

    function _emitETHRescued(uint256 amount) internal {
        emit ETHRescued(amount);
    }

    function _revertCannotRescueBase() internal pure {
        revert CannotRescueBase();
    }

    function navPerShare() public view aumNotStale returns (uint256) {
        if (totalSupply() == 0) {
            return DECIMAL_FACTOR * 1e18;
        }
        // feeStorage.aum is in native decimals; totalAccruedFees() is in 18-dec
        // normalized form. Bring AUM into normalized space before subtracting,
        // otherwise we subtract mixed units and the resulting NAV is off by
        // DECIMAL_FACTOR — breaks redemptions for any non-18-dec base token.
        uint256 normalizedAum = feeStorage.aum * DECIMAL_FACTOR;
        uint256 fees = feeStorage.totalAccruedFees();
        uint256 netAum = normalizedAum > fees ? normalizedAum - fees : 0;
        return (netAum * 1e18) / totalSupply();
    }

    function estimateShares(uint256 amount) external view aumNotStale returns (uint256) {
        // Inlined from ViewHelper
        uint256 netAmount = amount - (amount * feeStorage.entranceFeeBps) / 10000;
        uint256 normalized = netAmount * DECIMAL_FACTOR;
        uint256 nav = navPerShare();
        return nav > 0 ? (normalized * 1e18) / nav : normalized;
    }

    function estimatePayout(uint256 shares) external view aumNotStale returns (uint256) {
        // Inlined from ViewHelper
        uint256 nav = navPerShare();
        uint256 gross = (shares * nav) / 1e18;
        uint256 net = gross - (gross * feeStorage.exitFeeBps) / 10000;
        return net / DECIMAL_FACTOR;
    }

    function getHWMStatus() external view returns (uint256 hwm, uint256 lowestNav, uint256 recoveryStart, uint256 daysToReset) {
        // Inlined from ViewHelper
        hwm = feeStorage.highWaterMark;
        lowestNav = feeStorage.lowestNavInDrawdown;
        recoveryStart = feeStorage.recoveryStartTime;

        if (recoveryStart > 0 && block.timestamp < recoveryStart + feeStorage.hwmRecoveryPeriod) {
            uint256 elapsed = block.timestamp - recoveryStart;
            uint256 remaining = feeStorage.hwmRecoveryPeriod - elapsed;
            daysToReset = remaining / 1 days;
        } else {
            daysToReset = 0;
        }
    }

    function queueLengths() external view returns (uint256 deposits, uint256 redemptions) {
        return queueStorage.queueLengths();
    }

    function getUserDepositIndices(address user) external view returns (uint256[] memory) {
        return queueStorage.getUserDepositIndices(user);
    }

    function getUserRedemptionIndices(address user) external view returns (uint256[] memory) {
        return queueStorage.getUserRedemptionIndices(user);
    }

    function getDepositsByIndices(uint256[] calldata indices)
        external view returns (QueueManager.QueueItem[] memory)
    {
        return queueStorage.getDepositsByIndices(indices);
    }

    function getRedemptionsByIndices(uint256[] calldata indices)
        external view returns (QueueManager.QueueItem[] memory)
    {
        return queueStorage.getRedemptionsByIndices(indices);
    }

    function accruedFees() external view returns (
        uint256 mgmt, uint256 perf, uint256 entrance, uint256 exit,
        uint256 total, uint256 totalNative
    ) {
        (mgmt, perf, entrance, exit, total, totalNative) = feeStorage.accruedFeesBreakdown();
        totalNative = _denormalize(total);
    }

    function getPosition(address user) external view returns (
        uint256 shares, uint256 value, uint256 pendingDep, uint256 pendingRed
    ) {
        // Inlined from ViewHelper
        shares = balanceOf(user);
        value = ((shares * navPerShare()) / 1e18) / DECIMAL_FACTOR;
        pendingDep = queueStorage.pendingDeposits[user];
        pendingRed = queueStorage.pendingRedemptions[user];
    }

    function getTotalAum() public view returns (uint256) {
        // Inlined from ViewHelper
        uint256 onChain = baseToken.balanceOf(address(this)) + baseToken.balanceOf(safeWallet);
        uint256 fees = feeStorage.totalAccruedFees() / DECIMAL_FACTOR;
        return onChain >= fees ? onChain - fees : 0;
    }

    function _getTotalOnChainLiquidity() internal view returns (uint256) {
        return baseToken.balanceOf(address(this)) + baseToken.balanceOf(safeWallet);
    }

    function _normalize(uint256 amount) internal view returns (uint256) {
        return amount * DECIMAL_FACTOR;
    }

    function _denormalize(uint256 amount) internal view returns (uint256) {
        return amount / DECIMAL_FACTOR;
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        return success && data.length > 0 ? abi.decode(data, (uint8)) : 18;
    }

    function isModuleEnabled() public view returns (bool) {
        (bool success, bytes memory data) = safeWallet.staticcall(
            abi.encodeWithSignature("isModuleEnabled(address)", address(this))
        );
        return success && abi.decode(data, (bool));
    }

    function getFundConfig() external view returns (FundConfig memory config) {
        return FundConfig({
            managementFeeBps: feeStorage.managementFeeBps,
            performanceFeeBps: feeStorage.performanceFeeBps,
            entranceFeeBps: feeStorage.entranceFeeBps,
            exitFeeBps: feeStorage.exitFeeBps,
            targetLiquidityBps: feeStorage.targetLiquidityBps,
            minDeposit: minDeposit,
            minRedemption: minRedemption,
            maxAumAge: maxAumAge,
            maxBatchSize: maxBatchSize,
            hwmDrawdownPct: feeStorage.hwmDrawdownPct,
            hwmRecoveryPct: feeStorage.hwmRecoveryPct,
            hwmRecoveryPeriod: feeStorage.hwmRecoveryPeriod,
            autoProcessDeposits: autoProcessDeposits,
            autoPayoutRedemptions: autoPayoutRedemptions,
            feeRecipient: feeRecipient,
            rescueTreasury: rescueTreasury,
            lastAumUpdate: feeStorage.aumTimestamp
        });
    }
}
