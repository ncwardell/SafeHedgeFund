// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ConfigManager
 * @author Gnosis Safe Hedge Fund Team
 * @notice Library managing timelock-based configuration changes for the vault
 * @dev This library implements a two-step proposal system with mandatory waiting periods
 *      to prevent rapid or malicious configuration changes. All configuration updates
 *      must go through: propose → wait (timelock) → execute flow.
 *
 * ARCHITECTURE ROLE:
 * - Protects users from sudden parameter changes (rug pull protection)
 * - Enforces cooldown between consecutive changes to same parameter
 * - Validates all configuration values against hardcoded limits
 * - Enables transparent governance through proposal events
 *
 * KEY SECURITY FEATURES:
 * - 3-day timelock on all changes (TIMELOCK_DELAY)
 * - 5-day cooldown between changes to same parameter (PROPOSAL_COOLDOWN)
 * - Automatic proposal cleanup after execution
 * - One active proposal per configuration key at a time
 */
library ConfigManager {

    uint256 public constant TIMELOCK_DELAY = 3 days;
    uint256 public constant PROPOSAL_COOLDOWN = 5 days;
    uint256 public constant MAX_MGMT_FEE = 500;
    uint256 public constant MAX_PERF_FEE = 3_000;
    uint256 public constant MAX_ENTRANCE_FEE = 500;
    uint256 public constant MAX_EXIT_FEE = 500;
    uint256 public constant MIN_TARGET_LIQUIDITY = 200;
    uint256 public constant MAX_TARGET_LIQUIDITY = 10000;
    uint256 public constant MIN_AUM_AGE = 1 hours;
    uint256 public constant MAX_AUM_AGE = 30 days;
    uint256 public constant MIN_BATCH_SIZE = 1;
    uint256 public constant MAX_BATCH_SIZE = 200;
    uint256 public constant MAX_HWM_DRAWDOWN = 10_000;
    uint256 public constant MAX_HWM_RECOVERY_PCT = 10_000;
    uint256 public constant MIN_HWM_RECOVERY_PERIOD = 1 days;

    // Lending pool config bounds
    uint256 public constant MAX_SWAP_FEE = 100;          // 1%
    uint256 public constant MIN_LLTV = 1_000;            // 10%
    uint256 public constant MAX_LLTV = 9_000;            // 90%
    uint256 public constant MAX_BORROW_RATE = 5_000;     // 50% APR

    /**
     * @notice Represents a pending configuration change proposal
     * @dev Proposals are identified by hash of (key, value) pair
     * @param value The proposed new value for the configuration parameter
     * @param effectiveAt Timestamp when proposal can be executed (proposal_time + TIMELOCK_DELAY)
     * @param executed Whether this proposal has been executed already
     */
    struct Proposal {
        uint256 value;
        uint256 effectiveAt;
        bool executed;
    }

    /**
     * @notice Storage structure for managing all configuration proposals
     * @dev Uses mapping-based storage pattern for library usage
     * @param proposals Maps proposal ID (hash of key+value) to Proposal struct
     * @param lastConfigChange Maps configuration key to timestamp of last change (for cooldown)
     * @param activeProposalId Maps configuration key to currently active proposal ID
     */
    struct ConfigStorage {
        mapping(bytes32 => Proposal) proposals;
        mapping(string => uint256) lastConfigChange;
        mapping(string => bytes32) activeProposalId;
    }

    event ProposalCreated(bytes32 indexed id, string key, uint256 value, uint256 effectiveAt);
    event ProposalCancelled(bytes32 indexed id, string key, uint256 value);
    event ConfigUpdated(string param, uint256 value);

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
    bytes32 internal constant SWAP_FEE_KEY = keccak256("swapFeeBps");
    bytes32 internal constant LLTV_KEY = keccak256("lltvBps");
    bytes32 internal constant BORROW_RATE_KEY = keccak256("borrowRateBps");

    error CooldownActive();
    error ProposalExists();
    error ValueTooHigh();
    error ValueTooLow();
    error NotReady();
    error InvalidKey();

    /**
     * @notice Creates a new configuration change proposal with timelock
     * @dev CRITICAL FOR SECURITY: This is the entry point for all configuration changes.
     *      Enforces cooldown period and validates values before creating proposal.
     *      Users have visibility into pending changes via ProposalCreated event.
     *
     * WHY IT'S IMPORTANT:
     * - Prevents administrators from making instant malicious changes
     * - Gives users time to exit if they disagree with proposed changes
     * - Validates values to prevent DOS or economic attacks
     * - Ensures only one active proposal per parameter at a time
     *
     * @param cs Reference to configuration storage in main contract
     * @param key String identifier of parameter (e.g., "mgmt", "perf", "entrance")
     * @param value Proposed new value (in basis points for fees, e.g., 100 = 1%)
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
     * @notice Executes a proposal after timelock period expires
     * @dev CRITICAL: This applies the actual configuration change. Can only be called
     *      after TIMELOCK_DELAY has passed since proposal creation.
     *
     * WHY IT'S IMPORTANT:
     * - Final step in configuration change process
     * - Automatically cleans up proposal storage to save gas
     * - Updates lastConfigChange to enforce cooldown for next change
     * - Returns hash for main contract to apply the specific change
     *
     * FLOW:
     * 1. Verify timelock has expired
     * 2. Mark proposal as executed
     * 3. Record change timestamp for cooldown
     * 4. Clean up storage (delete proposal and active ID)
     * 5. Emit event and return key hash for main contract
     *
     * @param cs Reference to configuration storage
     * @param key Configuration parameter identifier
     * @param value Expected value (must match proposal exactly)
     * @return keyHash Hash of configuration key for main contract to identify which config to change
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

        if (cs.activeProposalId[key] == id) {
            delete cs.activeProposalId[key];
        }
        delete cs.proposals[id];

        emit ConfigUpdated(key, value);
        return (_getKeyHash(key), value);
    }

    /**
     * @notice Cancels a pending proposal before it can be executed
     * @dev Admin emergency function to cancel a proposal during timelock period.
     *      Cannot cancel after execution or after timelock expires.
     *
     * WHY IT'S IMPORTANT:
     * - Allows admin to retract mistaken proposals
     * - Provides emergency brake if proposal was created in error
     * - Must be used before timelock expires
     *
     * @param cs Reference to configuration storage
     * @param key Configuration parameter identifier
     * @param value Value of the proposal to cancel (must match exactly)
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

        if (cs.activeProposalId[key] == id) {
            delete cs.activeProposalId[key];
        }
        delete cs.proposals[id];

        emit ProposalCancelled(id, key, value);
    }

    /**
     * @notice Retrieves the currently active proposal for a configuration key
     * @dev Returns empty proposal if no active proposal exists or if proposal expired.
     *      A proposal is considered active if: not executed AND within cooldown window
     *
     * WHY IT'S IMPORTANT:
     * - Allows users to check what changes are pending
     * - Frontend can display upcoming changes to users
     * - Helps users make informed decisions about staying in fund
     *
     * @param cs Reference to configuration storage
     * @param key Configuration parameter to check
     * @return proposal The proposal details (value, effectiveAt, executed)
     * @return isActive Whether the proposal is still active and pending
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
     * @notice Retrieves a specific proposal by its key and value
     * @dev Direct lookup by proposal ID (hash of key+value)
     *
     * WHY IT'S IMPORTANT:
     * - Allows checking status of any historical or pending proposal
     * - Useful for verifying proposal details before execution
     *
     * @param cs Reference to configuration storage
     * @param key Configuration parameter identifier
     * @param value Value of the proposal to look up
     * @return Proposal struct with details
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
     * @notice Checks if a configuration key has an active pending proposal
     * @dev Quick boolean check without returning full proposal details
     *
     * WHY IT'S IMPORTANT:
     * - Gas-efficient way to check if changes are pending
     * - Used by UI to show warning indicators
     * - Prevents accidental duplicate proposals
     *
     * @param cs Reference to configuration storage
     * @param key Configuration parameter to check
     * @return true if active proposal exists, false otherwise
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

    /**
     * @notice Internal check for cooldown period enforcement
     * @dev Prevents changes to same parameter within PROPOSAL_COOLDOWN (5 days)
     *
     * WHY IT'S IMPORTANT:
     * - Prevents rapid successive changes that could manipulate NAV
     * - Gives stability to fund parameters
     * - Protects against admin mistakes (can't rapid-fire changes)
     *
     * @param cs Reference to configuration storage
     * @param key Configuration parameter to check
     */
    function _checkCooldown(ConfigStorage storage cs, string memory key) internal view {
        if (block.timestamp < cs.lastConfigChange[key] + PROPOSAL_COOLDOWN) {
            revert CooldownActive();
        }
    }

    /**
     * @notice Validates proposed configuration value against hardcoded limits
     * @dev Each configuration type has specific min/max bounds to prevent DOS or economic attacks
     *
     * WHY IT'S IMPORTANT:
     * - Prevents admin from setting 100% fees (economic attack)
     * - Prevents setting batch size to 0 or 10000 (DOS attack)
     * - Prevents setting AUM age too low (forcing constant updates) or too high (stale data)
     * - Ensures all values are economically and operationally reasonable
     *
     * VALIDATION RULES:
     * - Management fee: max 5% annual
     * - Performance fee: max 30%
     * - Entrance/Exit fees: max 5%
     * - Target liquidity: 2% to 100%
     * - AUM age: 1 hour to 30 days
     * - Batch size: 1 to 200 items
     * - HWM parameters: various limits for drawdown/recovery logic
     *
     * @param key Configuration parameter identifier
     * @param value Proposed value to validate
     */
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
        if (keyHash == SWAP_FEE_KEY && value > MAX_SWAP_FEE) revert ValueTooHigh();
        if (keyHash == LLTV_KEY && (value < MIN_LLTV || value > MAX_LLTV)) revert ValueTooHigh();
        if (keyHash == BORROW_RATE_KEY && value > MAX_BORROW_RATE) revert ValueTooHigh();
    }

    /**
     * @notice Converts string configuration key to standardized hash
     * @dev Ensures only recognized configuration keys can be used
     *
     * WHY IT'S IMPORTANT:
     * - Prevents typos in configuration keys
     * - Ensures only defined parameters can be changed
     * - Provides type safety for configuration system
     * - Returns consistent hash for main contract to identify which config to apply
     *
     * @param key Configuration parameter identifier string
     * @return Hash of the configuration key if valid
     */
    function _getKeyHash(string memory key) internal pure returns (bytes32) {
        bytes32 h = keccak256(bytes(key));
        if (
            h == MGMT_KEY || h == PERF_KEY || h == ENTRANCE_KEY || h == EXIT_KEY ||
            h == FEE_RECIPIENT_KEY || h == MIN_DEPOSIT_KEY || h == MIN_REDEMPTION_KEY ||
            h == TARGET_LIQUIDITY_KEY || h == MAX_AUM_AGE_KEY || h == MAX_BATCH_SIZE_KEY ||
            h == HWM_DRAWDOWN_PCT_KEY || h == HWM_RECOVERY_PCT_KEY || h == HWM_RECOVERY_PERIOD_KEY ||
            h == SWAP_FEE_KEY || h == LLTV_KEY || h == BORROW_RATE_KEY
        ) {
            return h;
        }
        revert InvalidKey();
    }
}
