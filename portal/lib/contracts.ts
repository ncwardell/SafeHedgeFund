import { keccak256, toBytes } from 'viem'

export const VAULT_ADDRESS = (process.env.NEXT_PUBLIC_VAULT_ADDRESS as `0x${string}`) ||
  '0x0000000000000000000000000000000000000000'

// Human-readable ABI. Signatures match contracts/SafeHedgeFundVault.sol exactly —
// the previous version had wrong return arity on getPosition / getHWMStatus /
// accruedFees, the wrong tuple shape on queue items, and called a non-existent
// emergencyMode() function.
export const VAULT_ABI = [
  // ── Views ────────────────────────────────────────────────────────────────
  'function navPerShare() view returns (uint256)',
  'function getTotalAum() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',

  'function getPosition(address user) view returns (uint256 shares, uint256 value, uint256 pendingDep, uint256 pendingRed)',
  'function accruedFees() view returns (uint256 mgmt, uint256 perf, uint256 entrance, uint256 exit, uint256 total, uint256 totalNative)',
  'function getHWMStatus() view returns (uint256 hwm, uint256 lowestNav, uint256 recoveryStart, uint256 daysToReset)',
  'function queueLengths() view returns (uint256 deposits, uint256 redemptions)',

  'function paused() view returns (bool)',
  'function isEmergencyActive() view returns (bool)',
  'function emergencyInfo() view returns (bool active, uint256 snapshot, uint256 withdrawn, uint256 pauseTime)',

  'function getUserDepositIndices(address user) view returns (uint256[])',
  'function getUserRedemptionIndices(address user) view returns (uint256[])',
  'function getDepositsByIndices(uint256[] indices) view returns (tuple(address user, uint256 amount, uint256 nav, bool processed, uint256 minOutput)[])',
  'function getRedemptionsByIndices(uint256[] indices) view returns (tuple(address user, uint256 amount, uint256 nav, bool processed, uint256 minOutput)[])',

  // Fund-config struct
  'function getFundConfig() view returns (tuple(uint256 managementFeeBps, uint256 performanceFeeBps, uint256 entranceFeeBps, uint256 exitFeeBps, uint256 targetLiquidityBps, uint256 minDeposit, uint256 minRedemption, uint256 maxAumAge, uint256 maxBatchSize, uint256 hwmDrawdownPct, uint256 hwmRecoveryPct, uint256 hwmRecoveryPeriod, bool autoProcessDeposits, bool autoPayoutRedemptions, address feeRecipient, address rescueTreasury, uint256 lastAumUpdate))',

  // Role getters (auto-generated for `public constant` state vars)
  'function ADMIN_ROLE() view returns (bytes32)',
  'function AUM_UPDATER_ROLE() view returns (bytes32)',
  'function PROCESSOR_ROLE() view returns (bytes32)',
  'function GUARDIAN_ROLE() view returns (bytes32)',
  'function DEFAULT_ADMIN_ROLE() view returns (bytes32)',

  // ── User actions (no return values on contract) ──────────────────────────
  'function deposit(uint256 amount, uint256 minShares)',
  'function redeem(uint256 shares, uint256 minAmountOut)',
  'function cancelMyDeposits(uint256 maxCancellations)',
  'function cancelMyRedemptions(uint256 maxCancellations)',
  'function emergencyWithdraw(uint256 shares)',

  // ── Keeper / processor ───────────────────────────────────────────────────
  'function updateAum(uint256 newAum)',
  'function processDepositQueue(uint256 maxToProcess)',
  'function processRedemptionQueue(uint256 maxToProcess)',
  'function checkEmergencyThreshold()',

  // ── Admin ────────────────────────────────────────────────────────────────
  'function payoutAccruedFees()',
  'function pause()',
  'function unpause()',
  'function triggerEmergency()',
  'function exitEmergency()',
  'function setAutoProcess(bool deposits, bool redemptions)',
  'function proposeConfigChange(string key, uint256 value)',
  'function executeConfigProposal(string key, uint256 value)',
  'function cancelConfigProposal(string key, uint256 value)',
  'function rescueERC20(address token, uint256 amount)',
  'function rescueETH()',

  // ── RBAC ─────────────────────────────────────────────────────────────────
  'function hasRole(bytes32 role, address account) view returns (bool)',
  'function grantRole(bytes32 role, address account)',
  'function revokeRole(bytes32 role, address account)',
  'function renounceRole(bytes32 role, address account)',

  // ── Events (names match contract — Deposited / Redeemed, not Deposit / Redeem) ──
  'event Deposited(address indexed user, uint256 amount, uint256 shares)',
  'event Redeemed(address indexed user, uint256 shares, uint256 amount)',
  'event AumUpdated(uint256 aum, uint256 nav)',
  'event FeesPaid(uint256 amount)',
  'event EmergencyToggled(bool enabled)',
  'event EmergencyRedeemed(address indexed user, uint256 shares, uint256 amount)',
] as const

export const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
  'function name() view returns (string)',
] as const

// Computed at module load — guaranteed to match keccak256(role string) on chain.
// (The previous hardcoded values had at least one wrong hash for PROCESSOR.)
export const ROLES = {
  DEFAULT_ADMIN: '0x0000000000000000000000000000000000000000000000000000000000000000' as `0x${string}`,
  ADMIN: keccak256(toBytes('ADMIN_ROLE')),
  AUM_UPDATER: keccak256(toBytes('AUM_UPDATER_ROLE')),
  PROCESSOR: keccak256(toBytes('PROCESSOR_ROLE')),
  GUARDIAN: keccak256(toBytes('GUARDIAN_ROLE')),
} as const
