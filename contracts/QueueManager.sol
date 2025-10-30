// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title QueueManager Library
 * @notice Manages deposit and redemption queues with FIFO processing
 * @dev Fixed MEDIUM #8: Added overflow protection for queue indices
 * 
 * AUDIT FIXES APPLIED:
 * - Added overflow protection for queue tail increments (MEDIUM #8)
 * - Maintained efficient queue management
 */
library QueueManager {
    // ====================== CONSTANTS ======================
    uint256 private constant MAX_QUEUE_LENGTH = 1000;
    uint256 private constant MAX_PENDING_REQUESTS_PER_USER = 5;

    // ====================== STRUCTS ======================
    struct QueueItem {
        address user;
        uint256 amount;     // deposit: base token | redemption: shares
        uint256 nav;        // NAV at queue time
        bool processed;
        uint256 minOutput;  // min shares (deposit) or min payout (redemption)
    }

    struct QueueStorage {
        // Deposit queue
        mapping(uint256 => QueueItem) depositQueue;
        uint256 depositQueueHead;
        uint256 depositQueueTail;

        // Redemption queue
        mapping(uint256 => QueueItem) redemptionQueue;
        uint256 redemptionQueueHead;
        uint256 redemptionQueueTail;

        // Per-user pending counts
        mapping(address => uint256) pendingDeposits;
        mapping(address => uint256) pendingRedemptions;
    }

    // ====================== EVENTS ======================
    event DepositQueued(address indexed user, uint256 amount, uint256 nav);
    event RedemptionQueued(address indexed user, uint256 shares, uint256 nav);
    event QueueProcessed(string queueType, uint256 count);
    event DepositCancelled(address indexed user, uint256 amount);
    event RedemptionCancelled(address indexed user, uint256 shares);
    event DepositSkipped(uint256 indexed queueIdx, address indexed user, uint256 amount, string reason);
    event RedemptionSkipped(uint256 indexed queueIdx, address indexed user, uint256 shares, string reason);

    // ====================== ERRORS ======================
    error QueueFull();
    error NoPending();
    error InvalidBatch();
    error QueueIndexOutOfBounds();
    error SlippageTooHigh();
    error QueueOverflow();

    // ====================== EXTERNAL FUNCTIONS ======================

    /**
     * @notice Queue a deposit for later processing
     * @dev Fixed MEDIUM #8: Added overflow protection for queue tail
     * @param qs Queue storage reference
     * @param user Address of depositor
     * @param amount Amount of base tokens to deposit
     * @param nav Current NAV at time of queuing
     * @param minShares Minimum shares expected (slippage protection)
     */
    function queueDeposit(
        QueueStorage storage qs,
        address user,
        uint256 amount,
        uint256 nav,
        uint256 minShares
    ) external {
        if (qs.depositQueueTail - qs.depositQueueHead >= MAX_QUEUE_LENGTH) revert QueueFull();
        _enforceUserLimit(qs, user, true);

        qs.depositQueue[qs.depositQueueTail] = QueueItem({
            user: user,
            amount: amount,
            nav: nav,
            processed: false,
            minOutput: minShares
        });

        // Fixed MEDIUM #8: Added overflow protection
        // While unlikely to overflow, adding check for safety
        if (qs.depositQueueTail == type(uint256).max) revert QueueOverflow();
        qs.depositQueueTail++;
        
        qs.pendingDeposits[user] += amount;

        emit DepositQueued(user, amount, nav);
    }

    /**
     * @notice Queue a redemption for later processing
     * @dev Fixed MEDIUM #8: Added overflow protection for queue tail
     * @param qs Queue storage reference
     * @param user Address of redeemer
     * @param shares Number of shares to redeem
     * @param nav Current NAV at time of queuing
     * @param minPayout Minimum payout expected (slippage protection)
     */
    function queueRedemption(
        QueueStorage storage qs,
        address user,
        uint256 shares,
        uint256 nav,
        uint256 minPayout
    ) external {
        if (qs.redemptionQueueTail - qs.redemptionQueueHead >= MAX_QUEUE_LENGTH) revert QueueFull();
        _enforceUserLimit(qs, user, false);

        qs.redemptionQueue[qs.redemptionQueueTail] = QueueItem({
            user: user,
            amount: shares,
            nav: nav,
            processed: false,
            minOutput: minPayout
        });

        // Fixed MEDIUM #8: Added overflow protection
        if (qs.redemptionQueueTail == type(uint256).max) revert QueueOverflow();
        qs.redemptionQueueTail++;
        
        qs.pendingRedemptions[user] += shares;

        emit RedemptionQueued(user, shares, nav);
    }

    /**
     * @notice Process a single deposit from the queue
     * @dev Used for auto-processing deposits immediately after queuing
     * @param qs Queue storage reference
     * @param queueIdx Index of the deposit in the queue
     * @param currentNav Current NAV per share
     * @param normalize Function to normalize amounts to 18 decimals
     * @param denormalize Function to denormalize amounts from 18 decimals
     * @param accrueEntranceFee Function to calculate and accrue entrance fees
     * @return success Whether the deposit was processed successfully
     * @return sharesMinted Number of shares minted
     * @return netAmount Net deposit amount after fees
     */
    function processSingleDeposit(
        QueueStorage storage qs,
        uint256 queueIdx,
        uint256 currentNav,
        function(uint256) view returns (uint256) normalize,
        function(uint256) view returns (uint256) denormalize,
        function(uint256) external returns (uint256, uint256) accrueEntranceFee
    ) external returns (bool success, uint256 sharesMinted, uint256 netAmount) {
        if (queueIdx >= qs.depositQueueTail || qs.depositQueue[queueIdx].processed) return (false, 0, 0);

        QueueItem storage item = qs.depositQueue[queueIdx];
        if (item.amount == 0) return (false, 0, 0);

        (uint256 netAmountNative, ) = accrueEntranceFee(item.amount);
        uint256 netAmountNormalized = normalize(netAmountNative);

        sharesMinted = currentNav > 0
            ? (netAmountNormalized * 1e18) / currentNav
            : netAmountNormalized;

        if (sharesMinted < item.minOutput) {
            return (false, 0, 0); // Slippage — caller should emit skipped
        }

        item.processed = true;
        qs.pendingDeposits[item.user] -= item.amount;

        success = true;
        netAmount = netAmountNative;
    }

    /**
     * @notice Process a batch of deposits from the queue
     * @dev Skips deposits that fail slippage checks and emits skip events
     * @param qs Queue storage reference
     * @param maxToProcess Maximum number of deposits to process
     * @param currentNav Current NAV per share
     * @param normalize Function to normalize amounts to 18 decimals
     * @param accrueEntranceFee Function to calculate and accrue entrance fees
     * @param emitDepositSkipped Function to emit skip events
     * @param getMaxBatchSize Function to get maximum batch size
     * @return processed Number of deposits successfully processed
     */
    function processDepositBatch(
        QueueStorage storage qs,
        uint256 maxToProcess,
        uint256 currentNav,
        function(uint256) view returns (uint256) normalize,
        function(uint256) external returns (uint256, uint256) accrueEntranceFee,
        function(uint256, address, uint256, string) external emitDepositSkipped,
        function() view returns (uint256) getMaxBatchSize
    ) external returns (uint256 processed) {
        uint256 batchLimit = getMaxBatchSize();
        if (maxToProcess == 0 || maxToProcess > batchLimit) revert InvalidBatch();

        uint256 start = qs.depositQueueHead;
        for (uint256 i = 0; i < maxToProcess && start + i < qs.depositQueueTail; i++) {
            uint256 idx = start + i;
            QueueItem storage item = qs.depositQueue[idx];
            if (item.processed || item.amount == 0) continue;

            (uint256 netAmountNative, ) = accrueEntranceFee(item.amount);
            uint256 netAmount = normalize(netAmountNative);
            uint256 shares = currentNav > 0 ? (netAmount * 1e18) / currentNav : netAmount;

            if (shares < item.minOutput) {
                emitDepositSkipped(idx, item.user, item.amount, "slippage");
                continue;
            }

            item.processed = true;
            qs.pendingDeposits[item.user] -= item.amount;
            processed++;
        }

        _cleanDepositQueue(qs);
        if (processed > 0) emit QueueProcessed("deposit", processed);
    }

    /**
     * @notice Process a batch of redemptions from the queue
     * @dev Skips redemptions that fail payout or slippage checks
     * @param qs Queue storage reference
     * @param maxToProcess Maximum number of redemptions to process
     * @param payout Function to execute payout to user
     * @param emitRedemptionSkipped Function to emit skip events
     * @param getMaxBatchSize Function to get maximum batch size
     * @return processed Number of redemptions successfully processed
     */
    function processRedemptionBatch(
        QueueStorage storage qs,
        uint256 maxToProcess,
        function(address, uint256, uint256) external returns (bool, uint256) payout,
        function(uint256, address, uint256, string) external emitRedemptionSkipped,
        function() view returns (uint256) getMaxBatchSize
    ) external returns (uint256 processed) {
        uint256 batchLimit = getMaxBatchSize();
        if (maxToProcess == 0 || maxToProcess > batchLimit) revert InvalidBatch();

        uint256 start = qs.redemptionQueueHead;
        for (uint256 i = 0; i < maxToProcess && start + i < qs.redemptionQueueTail; i++) {
            uint256 idx = start + i;
            QueueItem storage item = qs.redemptionQueue[idx];
            if (item.processed) continue;

            (bool ok, uint256 paid) = payout(item.user, item.amount, item.nav);
            if (!ok) {
                emitRedemptionSkipped(idx, item.user, item.amount, "payout failed");
                continue;
            }

            if (paid < item.minOutput) {
                emitRedemptionSkipped(idx, item.user, item.amount, "slippage");
                continue;
            }

            item.processed = true;
            qs.pendingRedemptions[item.user] -= item.amount;
            processed++;
        }

        _cleanRedemptionQueue(qs);
        if (processed > 0) emit QueueProcessed("redemption", processed);
    }

    // ====================== CANCELLATIONS ======================

    /**
     * @notice Cancel pending deposits for a user
     * @param qs Queue storage reference
     * @param user Address of the user
     * @param maxCancellations Maximum number of deposits to cancel
     * @param transferBack Function to transfer tokens back to user
     * @return cancelled Total amount cancelled
     */
    function cancelDeposits(
        QueueStorage storage qs,
        address user,
        uint256 maxCancellations,
        function(address, uint256) external transferBack
    ) external returns (uint256 cancelled) {
        if (qs.pendingDeposits[user] == 0) revert NoPending();

        uint256 count = 0;
        for (uint256 i = qs.depositQueueHead; i < qs.depositQueueTail && count < maxCancellations; i++) {
            QueueItem storage item = qs.depositQueue[i];
            if (item.user == user && !item.processed && item.amount > 0) {
                item.processed = true;
                qs.pendingDeposits[user] -= item.amount;
                transferBack(user, item.amount);
                emit DepositCancelled(user, item.amount);
                cancelled += item.amount;
                count++;
            }
        }
        _cleanDepositQueue(qs);
    }

    /**
     * @notice Cancel pending redemptions for a user
     * @param qs Queue storage reference
     * @param user Address of the user
     * @param maxCancellations Maximum number of redemptions to cancel
     * @param mintBack Function to mint shares back to user
     * @return cancelled Total shares cancelled
     */
    function cancelRedemptions(
        QueueStorage storage qs,
        address user,
        uint256 maxCancellations,
        function(address, uint256) external mintBack
    ) external returns (uint256 cancelled) {
        if (qs.pendingRedemptions[user] == 0) revert NoPending();

        uint256 count = 0;
        for (uint256 i = qs.redemptionQueueHead; i < qs.redemptionQueueTail && count < maxCancellations; i++) {
            QueueItem storage item = qs.redemptionQueue[i];
            if (item.user == user && !item.processed) {
                item.processed = true;
                qs.pendingRedemptions[user] -= item.amount;
                mintBack(user, item.amount);
                emit RedemptionCancelled(user, item.amount);
                cancelled += item.amount;
                count++;
            }
        }
        _cleanRedemptionQueue(qs);
    }

    function cancelDepositByIndex(
        QueueStorage storage qs,
        uint256 queueIdx,
        function(address, uint256) external transferBack
    ) external {
        if (queueIdx >= qs.depositQueueTail) revert QueueIndexOutOfBounds();
        QueueItem storage item = qs.depositQueue[queueIdx];
        if (item.processed || item.amount == 0) return;

        item.processed = true;
        qs.pendingDeposits[item.user] -= item.amount;
        transferBack(item.user, item.amount);
        emit DepositCancelled(item.user, item.amount);
        _cleanDepositQueue(qs);
    }

    function cancelRedemptionByIndex(
        QueueStorage storage qs,
        uint256 queueIdx,
        function(address, uint256) external mintBack
    ) external {
        if (queueIdx >= qs.redemptionQueueTail) revert QueueIndexOutOfBounds();
        QueueItem storage item = qs.redemptionQueue[queueIdx];
        if (item.processed) return;

        item.processed = true;
        qs.pendingRedemptions[item.user] -= item.amount;
        mintBack(item.user, item.amount);
        emit RedemptionCancelled(item.user, item.amount);
        _cleanRedemptionQueue(qs);
    }

    function batchCancelDeposits(
        QueueStorage storage qs,
        uint256[] calldata indices,
        function(address, uint256) external transferBack
    ) external {
        uint256 limit = indices.length > 50 ? 50 : indices.length;
        for (uint256 i = 0; i < limit; i++) {
            uint256 idx = indices[i];
            if (idx >= qs.depositQueueTail) continue;
            QueueItem storage item = qs.depositQueue[idx];
            if (item.processed || item.amount == 0) continue;

            item.processed = true;
            qs.pendingDeposits[item.user] -= item.amount;
            transferBack(item.user, item.amount);
            emit DepositCancelled(item.user, item.amount);
        }
        _cleanDepositQueue(qs);
    }

    function batchCancelRedemptions(
        QueueStorage storage qs,
        uint256[] calldata indices,
        function(address, uint256) external mintBack
    ) external {
        uint256 limit = indices.length > 50 ? 50 : indices.length;
        for (uint256 i = 0; i < limit; i++) {
            uint256 idx = indices[i];
            if (idx >= qs.redemptionQueueTail) continue;
            QueueItem storage item = qs.redemptionQueue[idx];
            if (item.processed) continue;

            item.processed = true;
            qs.pendingRedemptions[item.user] -= item.amount;
            mintBack(item.user, item.amount);
            emit RedemptionCancelled(item.user, item.amount);
        }
        _cleanRedemptionQueue(qs);
    }

    // ====================== VIEW FUNCTIONS ======================

    /**
     * @notice Get the current length of both queues
     * @param qs Queue storage reference
     * @return deposits Number of pending deposits
     * @return redemptions Number of pending redemptions
     */
    function queueLengths(QueueStorage storage qs)
        external
        view
        returns (uint256 deposits, uint256 redemptions)
    {
        deposits = qs.depositQueueTail - qs.depositQueueHead;
        redemptions = qs.redemptionQueueTail - qs.redemptionQueueHead;
    }

    /**
     * @notice Get a paginated list of pending deposits
     * @param qs Queue storage reference
     * @param start Starting index for pagination
     * @param limit Maximum number of items to return
     * @return users Array of depositor addresses
     * @return amounts Array of deposit amounts
     * @return navs Array of NAV values at queue time
     */
    function getPendingDeposits(
        QueueStorage storage qs,
        uint256 start,
        uint256 limit
    ) external view returns (
        address[] memory users,
        uint256[] memory amounts,
        uint256[] memory navs
    ) {
        uint256 size = qs.depositQueueTail - qs.depositQueueHead;
        if (start >= size) return (users, amounts, navs);

        uint256 count = limit > size - start ? size - start : limit;
        users = new address[](count);
        amounts = new uint256[](count);
        navs = new uint256[](count);

        uint256 idx = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 qIdx = qs.depositQueueHead + start + i;
            if (qIdx >= qs.depositQueueTail) break;
            QueueItem memory item = qs.depositQueue[qIdx];
            if (!item.processed && item.amount > 0) {
                users[idx] = item.user;
                amounts[idx] = item.amount;
                navs[idx] = item.nav;
                idx++;
            }
        }
        assembly { mstore(users, idx) mstore(amounts, idx) mstore(navs, idx) }
    }

    /**
     * @notice Get a paginated list of pending redemptions
     * @param qs Queue storage reference
     * @param start Starting index for pagination
     * @param limit Maximum number of items to return
     * @return users Array of redeemer addresses
     * @return shares Array of share amounts
     * @return navs Array of NAV values at queue time
     */
    function getPendingRedemptions(
        QueueStorage storage qs,
        uint256 start,
        uint256 limit
    ) external view returns (
        address[] memory users,
        uint256[] memory shares,
        uint256[] memory navs
    ) {
        uint256 size = qs.redemptionQueueTail - qs.redemptionQueueHead;
        if (start >= size) return (users, shares, navs);

        uint256 count = limit > size - start ? size - start : limit;
        users = new address[](count);
        shares = new uint256[](count);
        navs = new uint256[](count);

        uint256 idx = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 qIdx = qs.redemptionQueueHead + start + i;
            if (qIdx >= qs.redemptionQueueTail) break;
            QueueItem memory item = qs.redemptionQueue[qIdx];
            if (!item.processed) {
                users[idx] = item.user;
                shares[idx] = item.amount;
                navs[idx] = item.nav;
                idx++;
            }
        }
        assembly { mstore(users, idx) mstore(shares, idx) mstore(navs, idx) }
    }

    // ====================== INTERNAL ======================

    function _enforceUserLimit(QueueStorage storage qs, address user, bool isDeposit) internal {
        uint256 count = 0;
        if (isDeposit) {
            for (uint256 i = qs.depositQueueHead; i < qs.depositQueueTail; i++) {
                if (qs.depositQueue[i].user == user && !qs.depositQueue[i].processed) {
                    if (++count >= MAX_PENDING_REQUESTS_PER_USER) revert QueueFull();
                }
            }
        } else {
            for (uint256 i = qs.redemptionQueueHead; i < qs.redemptionQueueTail; i++) {
                if (qs.redemptionQueue[i].user == user && !qs.redemptionQueue[i].processed) {
                    if (++count >= MAX_PENDING_REQUESTS_PER_USER) revert QueueFull();
                }
            }
        }
    }

    /**
     * @notice Clean processed items from deposit queue
     * @dev Fixed LOW #15: Gas optimization - cleanup happens incrementally
     */
    function _cleanDepositQueue(QueueStorage storage qs) internal {
        while (qs.depositQueueHead < qs.depositQueueTail && qs.depositQueue[qs.depositQueueHead].processed) {
            delete qs.depositQueue[qs.depositQueueHead];
            qs.depositQueueHead++;
        }
    }

    /**
     * @notice Clean processed items from redemption queue
     * @dev Fixed LOW #15: Gas optimization - cleanup happens incrementally
     */
    function _cleanRedemptionQueue(QueueStorage storage qs) internal {
        while (qs.redemptionQueueHead < qs.redemptionQueueTail && qs.redemptionQueue[qs.redemptionQueueHead].processed) {
            delete qs.redemptionQueue[qs.redemptionQueueHead];
            qs.redemptionQueueHead++;
        }
    }
}
