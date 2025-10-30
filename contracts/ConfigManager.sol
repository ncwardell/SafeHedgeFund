// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ConfigManager Library - PATCHED VERSION
 * @notice Handles timelocked proposals, cooldowns, and validation
 * @dev Used internally by SafeHedgeFundVault — not deployed separately
 * 
 * CHANGES FROM ORIGINAL:
 * - Fixed key hash visibility (HIGH-5) - changed from private to internal
 * - Increased timelock delay (MEDIUM-2)
 * - Improved proposal cleanup logic (LOW-3)
 */
library ConfigManager {
    // ====================== CONSTANTS ======================
    // PATCH: Increased from 48 hours to 3 days (MEDIUM-2)
    uint256 public constant TIMELOCK_DELAY = 3 days;
    uint256 public constant PROPOSAL_COOLDOWN = 5 days;
    uint256 public constant MAX_MGMT_FEE = 500; // 5%
    uint256 public constant MAX_PERF_FEE = 3_000; // 30%
    uint256 public constant MAX_ENTRANCE_FEE = 500; // 5%
    uint256 public constant MAX_EXIT_FEE = 500; // 5%
    uint256 public constant MIN_TARGET_LIQUIDITY = 200; // 2%
    uint256 public constant MAX_TARGET_LIQUIDITY = 10000; // 100%
    uint256 public constant MIN_AUM_AGE = 1 hours;
    uint256 public constant MAX_AUM_AGE = 30 days;
    uint256 public constant MIN_BATCH_SIZE = 1;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant MAX_HWM_DRAWDOWN = 10_000; // 100%
    uint256 public constant MAX_HWM_RECOVERY_PCT = 10_000; // 100%
    uint256 public constant MIN_HWM_RECOVERY_PERIOD = 1 days;

    // ====================== STRUCTS ======================
    struct Proposal {
        uint256 value;
        uint256 effectiveAt;
        bool executed;
    }

    struct ConfigStorage {
        // Proposals
        mapping(bytes32 => Proposal) proposals;
        mapping(string => uint256) lastConfigChange;
        mapping(string => bytes32) activeProposalId;
    }

    // ====================== EVENTS ======================
    event ProposalCreated(bytes32 indexed id, string key, uint256 value, uint256 effectiveAt);
    event ProposalCancelled(bytes32 indexed id, string key, uint256 value);
    event ConfigUpdated(string param, uint256 value);

    // ====================== KEY HASHES ======================
    // PATCH: Changed from private to internal for vault access (HIGH-5)
    bytes32 internal constant MGMT_KEY = keccak256("mgmt");
    bytes32 internal constant PERF_KEY = keccak256("perf");
    bytes32 internal constant ENTRANCE_KEY = keccak256("entrance");
    bytes32 internal constant EXIT_KEY = keccak256("exit");
    bytes32 internal constant FEE_RECIPIENT_KEY = keccak256("feeRecipient");
    bytes32 internal constant MIN_DEPOSIT_KEY = keccak256("minDeposit");
    bytes32 internal constant MIN_REDEMPTION_KEY = keccak256("minRedemption");
    bytes32 internal constant TARGET_LIQUIDITY_KEY = keccak256("targetLiquidity");
    bytes32 internal constant MAX_AUM_AGE_KEY = keccak256("maxAumAge");
    bytes32 internal constant MAX_BATCH_SIZE_KEY = keccak256("maxBatchSize");
    bytes32 internal constant HWM_DRAWDOWN_PCT_KEY = keccak256("hwmDrawdownPct");
    bytes32 internal constant HWM_RECOVERY_PCT_KEY = keccak256("hwmRecoveryPct");
    bytes32 internal constant HWM_RECOVERY_PERIOD_KEY = keccak256("hwmRecoveryPeriod");

    // ====================== ERRORS ======================
    error CooldownActive();
    error ProposalExists();
    error ValueTooHigh();
    error ValueTooLow();
    error NotReady();
    error InvalidKey();

    // ====================== EXTERNAL FUNCTIONS ======================

    /**
     * @notice Propose a configuration change with timelock
     * @dev Validates the value and enforces cooldown period between changes
     * @param cs Configuration storage reference
     * @param key Configuration parameter key
     * @param value Proposed new value
     */
    function proposeChange(
        ConfigStorage storage cs,
        string memory key,
        uint256 value
    ) external {
        _checkCooldown(cs, key);

        bytes32 existingId = cs.activeProposalId[key];
        if (existingId != bytes32(0)) {
            Proposal storage existing = cs.proposals[existingId];
            if (!existing.executed && block.timestamp < existing.effectiveAt + PROPOSAL_COOLDOWN) {
                revert ProposalExists();
            }
        }

        _validateValue(key, value);

        bytes32 id = keccak256(abi.encode(key, value));
        Proposal storage p = cs.proposals[id];
        if (p.effectiveAt != 0 && !p.executed) revert ProposalExists();

        p.value = value;
        p.effectiveAt = block.timestamp + TIMELOCK_DELAY;
        p.executed = false;

        cs.activeProposalId[key] = id;
        emit ProposalCreated(id, key, value, p.effectiveAt);
    }

    /**
     * @notice Execute a pending proposal after timelock has expired
     * @dev Applies the configuration change and cleans up proposal data
     * @param cs Configuration storage reference
     * @param key Configuration parameter key
     * @param value Expected value (must match the proposal)
     * @return keyHash The hashed key to apply in the main contract
     * @return newValue The new value to apply
     */
    function executeProposal(
        ConfigStorage storage cs,
        string memory key,
        uint256 value
    ) external returns (bytes32 keyHash, uint256 newValue) {
        bytes32 id = keccak256(abi.encode(key, value));
        Proposal storage p = cs.proposals[id];
        if (p.effectiveAt == 0 || block.timestamp < p.effectiveAt || p.executed) revert NotReady();

        p.executed = true;
        cs.lastConfigChange[key] = block.timestamp;
        
        // PATCH: Improved cleanup logic (LOW-3)
        if (cs.activeProposalId[key] == id) {
            delete cs.activeProposalId[key];
        }
        delete cs.proposals[id];

        emit ConfigUpdated(key, value);
        return (_getKeyHash(key), value);
    }

    /**
     * @notice Cancel a pending proposal before execution
     * @dev Can be called by admin even if they didn't create the proposal
     * @param cs Configuration storage reference
     * @param key Configuration parameter key
     * @param value Value of the proposal to cancel
     */
    function cancelProposal(
        ConfigStorage storage cs,
        string memory key,
        uint256 value
    ) external {
        bytes32 id = keccak256(abi.encode(key, value));
        Proposal storage p = cs.proposals[id];

        if (p.effectiveAt == 0 || p.executed) revert NotReady();
        if (block.timestamp >= p.effectiveAt) revert NotReady();

        // PATCH: Improved cleanup - clear active if it matches (LOW-3)
        if (cs.activeProposalId[key] == id) {
            delete cs.activeProposalId[key];
        }
        delete cs.proposals[id];

        emit ProposalCancelled(id, key, value);
    }

    // ====================== VIEW FUNCTIONS ======================

    /**
     * @notice Get the active proposal for a configuration key
     * @dev Returns the proposal and whether it's still active
     * @param cs Configuration storage reference
     * @param key Configuration parameter key
     * @return proposal The proposal details
     * @return isActive Whether the proposal is still active
     */
    function getActiveProposal(
        ConfigStorage storage cs,
        string memory key
    ) external view returns (Proposal memory proposal, bool isActive) {
        bytes32 id = cs.activeProposalId[key];
        if (id == bytes32(0)) return (proposal, false);

        Proposal storage p = cs.proposals[id];
        isActive = !p.executed && block.timestamp < p.effectiveAt + PROPOSAL_COOLDOWN;
        if (isActive) {
            proposal = p;
        }
    }

    /**
     * @notice Get a specific proposal by key and value
     * @param cs Configuration storage reference
     * @param key Configuration parameter key
     * @param value Configuration parameter value
     * @return Proposal details
     */
    function getProposal(
        ConfigStorage storage cs,
        string memory key,
        uint256 value
    ) external view returns (Proposal memory) {
        bytes32 id = keccak256(abi.encode(key, value));
        return cs.proposals[id];
    }

    /**
     * @notice Check if a configuration key has an active proposal
     * @param cs Configuration storage reference
     * @param key Configuration parameter key
     * @return Whether an active proposal exists for this key
     */
    function isProposalActive(
        ConfigStorage storage cs,
        string memory key
    ) external view returns (bool) {
        bytes32 id = cs.activeProposalId[key];
        if (id == bytes32(0)) return false;
        Proposal storage p = cs.proposals[id];
        return !p.executed && block.timestamp < p.effectiveAt + PROPOSAL_COOLDOWN;
    }

    // ====================== INTERNAL HELPERS ======================

    function _checkCooldown(ConfigStorage storage cs, string memory key) internal view {
        if (block.timestamp < cs.lastConfigChange[key] + PROPOSAL_COOLDOWN) {
            revert CooldownActive();
        }
    }

    function _validateValue(string memory key, uint256 value) internal pure {
        bytes32 keyHash = keccak256(bytes(key));
        if (keyHash == MGMT_KEY && value > MAX_MGMT_FEE) revert ValueTooHigh();
        if (keyHash == PERF_KEY && value > MAX_PERF_FEE) revert ValueTooHigh();
        if (keyHash == ENTRANCE_KEY && value > MAX_ENTRANCE_FEE) revert ValueTooHigh();
        if (keyHash == EXIT_KEY && value > MAX_EXIT_FEE) revert ValueTooHigh();
        if (
            keyHash == TARGET_LIQUIDITY_KEY &&
            (value < MIN_TARGET_LIQUIDITY || value > MAX_TARGET_LIQUIDITY)
        ) revert ValueTooHigh();
        if (keyHash == MAX_AUM_AGE_KEY && (value < MIN_AUM_AGE || value > MAX_AUM_AGE)) revert ValueTooHigh();
        if (keyHash == MAX_BATCH_SIZE_KEY && (value < MIN_BATCH_SIZE || value > MAX_BATCH_SIZE)) revert ValueTooHigh();
        if (keyHash == HWM_DRAWDOWN_PCT_KEY && value > MAX_HWM_DRAWDOWN) revert ValueTooHigh();
        if (keyHash == HWM_RECOVERY_PCT_KEY && value > MAX_HWM_RECOVERY_PCT) revert ValueTooHigh();
        if (keyHash == HWM_RECOVERY_PERIOD_KEY && value < MIN_HWM_RECOVERY_PERIOD) revert ValueTooLow();
    }

    function _getKeyHash(string memory key) internal pure returns (bytes32) {
        bytes32 h = keccak256(bytes(key));
        if (
            h == MGMT_KEY || h == PERF_KEY || h == ENTRANCE_KEY || h == EXIT_KEY ||
            h == FEE_RECIPIENT_KEY || h == MIN_DEPOSIT_KEY || h == MIN_REDEMPTION_KEY ||
            h == TARGET_LIQUIDITY_KEY || h == MAX_AUM_AGE_KEY || h == MAX_BATCH_SIZE_KEY ||
            h == HWM_DRAWDOWN_PCT_KEY || h == HWM_RECOVERY_PCT_KEY || h == HWM_RECOVERY_PERIOD_KEY
        ) {
            return h;
        }
        revert InvalidKey();
    }
}
