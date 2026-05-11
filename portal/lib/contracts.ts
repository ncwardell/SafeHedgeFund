import { keccak256, parseAbi, toBytes } from 'viem'

// ── Addresses ─────────────────────────────────────────────────────────────
// Set per-chain via env vars. After running script/Deploy.s.sol, copy the
// addresses from deployments/<chainId>.json into portal/.env.local:
//
//   NEXT_PUBLIC_VAULT_ADDRESS=0x...
//   NEXT_PUBLIC_POOL_ADDRESS=0x...
//   NEXT_PUBLIC_USDC_ADDRESS=0x...
//   NEXT_PUBLIC_SAFE_ADDRESS=0x...
//
const ZERO = '0x0000000000000000000000000000000000000000' as const

export const VAULT_ADDRESS =
  (process.env.NEXT_PUBLIC_VAULT_ADDRESS as `0x${string}`) || ZERO
export const POOL_ADDRESS =
  (process.env.NEXT_PUBLIC_POOL_ADDRESS as `0x${string}`) || ZERO
export const USDC_ADDRESS =
  (process.env.NEXT_PUBLIC_USDC_ADDRESS as `0x${string}`) || ZERO
export const SAFE_ADDRESS =
  (process.env.NEXT_PUBLIC_SAFE_ADDRESS as `0x${string}`) || ZERO

// ── Vault ABI ─────────────────────────────────────────────────────────────
// Human-readable, parsed via viem so wagmi receives a structured ABI.
// Signatures match contracts/SafeHedgeFundVault.sol.
export const VAULT_ABI = parseAbi([
  // ── Views ────────────────────────────────────────────────────────────────
  'function navPerShare() view returns (uint256)',
  'function getTotalAum() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function baseToken() view returns (address)',
  'function baseDecimals() view returns (uint8)',
  'function lastAumBlock() view returns (uint256)',
  'function sharedPool() view returns (address)',

  'function getPosition(address user) view returns (uint256 shares, uint256 value, uint256 pendingDep, uint256 pendingRed)',
  'function accruedFees() view returns (uint256 mgmt, uint256 perf, uint256 entrance, uint256 exit, uint256 total, uint256 totalNative)',
  'function getHWMStatus() view returns (uint256 hwm, uint256 lowestNav, uint256 recoveryStart, uint256 daysToReset)',
  'function queueLengths() view returns (uint256 deposits, uint256 redemptions)',

  'function paused() view returns (bool)',
  'function isEmergencyActive() view returns (bool)',
  'function emergencyInfo() view returns (bool active, uint256 snapshot, uint256 snapshotSupply, uint256 withdrawn, uint256 pauseTime)',

  'function getUserDepositIndices(address user) view returns (uint256[])',
  'function getUserRedemptionIndices(address user) view returns (uint256[])',
  'struct QueueItem { address user; uint256 amount; uint256 nav; bool processed; uint256 minOutput; }',
  'function getDepositsByIndices(uint256[] indices) view returns (QueueItem[])',
  'function getRedemptionsByIndices(uint256[] indices) view returns (QueueItem[])',

  // Lending config (read by the pool, exposed publicly)
  'function swapFeeBps() view returns (uint256)',
  'function lltvBps() view returns (uint256)',
  'function borrowRateBps() view returns (uint256)',

  // Fund-config struct
  'struct FundConfig { uint256 managementFeeBps; uint256 performanceFeeBps; uint256 entranceFeeBps; uint256 exitFeeBps; uint256 targetLiquidityBps; uint256 minDeposit; uint256 minRedemption; uint256 maxAumAge; uint256 maxBatchSize; uint256 hwmDrawdownPct; uint256 hwmRecoveryPct; uint256 hwmRecoveryPeriod; bool autoProcessDeposits; bool autoPayoutRedemptions; address feeRecipient; address rescueTreasury; uint256 lastAumUpdate; }',
  'function getFundConfig() view returns (FundConfig)',

  // Role getters
  'function ADMIN_ROLE() view returns (bytes32)',
  'function AUM_UPDATER_ROLE() view returns (bytes32)',
  'function PROCESSOR_ROLE() view returns (bytes32)',
  'function GUARDIAN_ROLE() view returns (bytes32)',
  'function DEFAULT_ADMIN_ROLE() view returns (bytes32)',

  // ── User actions ─────────────────────────────────────────────────────────
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
  'function setSharedPool(address pool)',
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

  // ── Events ──────────────────────────────────────────────────────────────
  'event Deposited(address indexed user, uint256 amount, uint256 shares)',
  'event Redeemed(address indexed user, uint256 shares, uint256 amount)',
  'event AumUpdated(uint256 aum, uint256 nav)',
  'event FeesPaid(uint256 amount)',
  'event EmergencyToggled(bool enabled)',
  'event EmergencyRedeemed(address indexed user, uint256 shares, uint256 amount)',
])

// ── SharedPool ABI ────────────────────────────────────────────────────────
// Signatures match contracts/lending/SharedPool.sol.
export const SHARED_POOL_ABI = parseAbi([
  // Views
  'function vault() view returns (address)',
  'function usdc() view returns (address)',
  'function baseDecimals() view returns (uint8)',
  'function usdcReserve() view returns (uint256)',
  'function totalBorrowed() view returns (uint256)',
  'function hfsReserve() view returns (uint256)',
  'function collateralOf(address) view returns (uint256)',
  'function borrowOf(address) view returns (uint256)',
  'function lastAccrual(address) view returns (uint256)',
  'function isHealthy(address user) view returns (bool)',
  'function activeBorrowerCount() view returns (uint256)',
  'function activeBorrowerAt(uint256 i) view returns (address)',

  // Pool actions
  'function supply(uint256 amount)',
  'function swapUsdcForHfs(uint256 usdcIn, uint256 minOut) returns (uint256 hfsOut)',
  'function swapHfsForUsdc(uint256 hfsIn, uint256 minOut) returns (uint256 usdcOut)',
  'function depositCollateral(uint256 amount)',
  'function withdrawCollateral(uint256 amount)',
  'function borrow(uint256 amount)',
  'function repay(uint256 amount)',

  // Events
  'event SwappedUsdcForHfs(address indexed user, uint256 usdcIn, uint256 hfsOut)',
  'event SwappedHfsForUsdc(address indexed user, uint256 hfsIn, uint256 usdcOut)',
  'event CollateralDeposited(address indexed user, uint256 amount)',
  'event CollateralWithdrawn(address indexed user, uint256 amount)',
  'event Borrowed(address indexed user, uint256 amount)',
  'event Repaid(address indexed user, uint256 amount)',
  'event Liquidated(address indexed borrower, uint256 collateralBurned, uint256 debtWrittenOff)',
])

export const ERC20_ABI = parseAbi([
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
  'function name() view returns (string)',
  // MockUSDC adds a permissionless mint for testnet UX
  'function mint(address to, uint256 amount)',
])

// Computed at module load — guaranteed to match keccak256(role string) on chain.
export const ROLES = {
  DEFAULT_ADMIN: '0x0000000000000000000000000000000000000000000000000000000000000000' as `0x${string}`,
  ADMIN: keccak256(toBytes('ADMIN_ROLE')),
  AUM_UPDATER: keccak256(toBytes('AUM_UPDATER_ROLE')),
  PROCESSOR: keccak256(toBytes('PROCESSOR_ROLE')),
  GUARDIAN: keccak256(toBytes('GUARDIAN_ROLE')),
} as const
