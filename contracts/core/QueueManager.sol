// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library QueueManager {

    uint256 private constant MAX_QUEUE_LENGTH = 1000;
    uint256 private constant MAX_PENDING_REQUESTS_PER_USER = 5;

    struct QueueItem {
        address user;
        uint256 amount;
        uint256 nav;
        bool processed;
        uint256 minOutput;
    }

    struct QueueStorage {
        mapping(uint256 => QueueItem) depositQueue;
        uint256 depositQueueHead;
        uint256 depositQueueTail;

        mapping(uint256 => QueueItem) redemptionQueue;
        uint256 redemptionQueueHead;
        uint256 redemptionQueueTail;

        mapping(address => uint256) pendingDeposits;
        mapping(address => uint256) pendingRedemptions;

        mapping(address => uint256[]) userDepositIndices;
        mapping(address => uint256[]) userRedemptionIndices;
    }

    event DepositQueued(address indexed user, uint256 amount, uint256 nav);
    event RedemptionQueued(address indexed user, uint256 shares, uint256 nav);
    event QueueProcessed(string queueType, uint256 count);
    event DepositCancelled(address indexed user, uint256 amount);
    event RedemptionCancelled(address indexed user, uint256 shares);
    event DepositSkipped(uint256 indexed queueIdx, address indexed user, uint256 amount, string reason);
    event RedemptionSkipped(uint256 indexed queueIdx, address indexed user, uint256 shares, string reason);

    error QueueFull();
    error NoPending();
    error InvalidBatch();
    error QueueIndexOutOfBounds();
    error SlippageTooHigh();
    error QueueOverflow();

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

        if (qs.depositQueueTail == type(uint256).max) revert QueueOverflow();

        qs.userDepositIndices[user].push(qs.depositQueueTail);

        qs.depositQueueTail++;
        qs.pendingDeposits[user] += amount;

        emit DepositQueued(user, amount, nav);
    }

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

        if (qs.redemptionQueueTail == type(uint256).max) revert QueueOverflow();

        qs.userRedemptionIndices[user].push(qs.redemptionQueueTail);

        qs.redemptionQueueTail++;
        qs.pendingRedemptions[user] += shares;

        emit RedemptionQueued(user, shares, nav);
    }

    function processSingleDeposit(
        QueueStorage storage qs,
        uint256 queueIdx,
        uint256 currentNav,
        function(uint256) view returns (uint256) normalize,
        function(uint256) view returns (uint256, uint256) previewEntranceFee,
        function(uint256) internal recordEntranceFee
    ) internal returns (bool success, uint256 sharesMinted, uint256 netAmount) {
        if (queueIdx >= qs.depositQueueTail || qs.depositQueue[queueIdx].processed) return (false, 0, 0);

        QueueItem storage item = qs.depositQueue[queueIdx];
        if (item.amount == 0) return (false, 0, 0);

        (uint256 netAmountNative, uint256 feeNative) = previewEntranceFee(item.amount);
        uint256 netAmountNormalized = normalize(netAmountNative);

        sharesMinted = currentNav > 0
            ? (netAmountNormalized * 1e18) / currentNav
            : netAmountNormalized;

        // shares==0 is a slippage failure, not a "successful zero-share mint"
        // (B-HIGH-5): the previous version returned ok=true with shares=0,
        // and the caller's mint path bailed without refunding the user.
        if (sharesMinted < item.minOutput || sharesMinted == 0) {
            return (false, 0, 0);
        }

        item.processed = true;
        qs.pendingDeposits[item.user] -= item.amount;
        if (feeNative > 0) recordEntranceFee(feeNative);

        success = true;
        netAmount = netAmountNative;
    }

    function processDepositBatch(
        QueueStorage storage qs,
        uint256 maxToProcess,
        uint256 currentNav,
        function(uint256) view returns (uint256) normalize,
        function(uint256) view returns (uint256, uint256) previewEntranceFee,
        function(uint256) internal recordEntranceFee,
        function(address, uint256, uint256, uint256) internal mintAndDeploy,
        function(uint256, address, uint256, string memory) internal emitDepositSkipped,
        function() view returns (uint256) getMaxBatchSize
    ) internal returns (uint256 processed) {
        uint256 batchLimit = getMaxBatchSize();
        if (maxToProcess == 0 || maxToProcess > batchLimit) revert InvalidBatch();

        uint256 start = qs.depositQueueHead;
        for (uint256 i = 0; i < maxToProcess && start + i < qs.depositQueueTail; i++) {
            if (_processDepositItem(
                qs, start + i, currentNav,
                normalize, previewEntranceFee, recordEntranceFee, mintAndDeploy, emitDepositSkipped
            )) {
                processed++;
            }
        }

        _cleanDepositQueue(qs);
        if (processed > 0) emit QueueProcessed("deposit", processed);
    }

    /// @dev Processes one deposit end-to-end. Computes the would-be shares
    /// using a PURE preview of the entrance fee, runs slippage / zero-shares
    /// checks, and only commits state (mark processed + decrement pending +
    /// record fee + mint) once every check has passed. Pre-fix the entrance
    /// fee was committed before the slippage check, so failed-then-cancelled
    /// deposits left phantom fee on the ledger (B-CRIT-2).
    ///
    /// Mint MUST happen here, not in a second pass — _cleanDepositQueue
    /// advances head past processed items, so a second pass reading
    /// post-cleanup head would silently miss them (B1, fixed earlier).
    function _processDepositItem(
        QueueStorage storage qs,
        uint256 idx,
        uint256 currentNav,
        function(uint256) view returns (uint256) normalize,
        function(uint256) view returns (uint256, uint256) previewEntranceFee,
        function(uint256) internal recordEntranceFee,
        function(address, uint256, uint256, uint256) internal mintAndDeploy,
        function(uint256, address, uint256, string memory) internal emitDepositSkipped
    ) private returns (bool success) {
        QueueItem storage item = qs.depositQueue[idx];
        if (item.processed || item.amount == 0) return false;

        (uint256 netAmountNative, uint256 feeNative) = previewEntranceFee(item.amount);
        uint256 netAmount = normalize(netAmountNative);
        uint256 shares = currentNav > 0 ? (netAmount * 1e18) / currentNav : netAmount;

        if (shares < item.minOutput) {
            emitDepositSkipped(idx, item.user, item.amount, "slippage");
            return false;
        }
        if (shares == 0) {
            emitDepositSkipped(idx, item.user, item.amount, "zero shares");
            return false;
        }

        item.processed = true;
        qs.pendingDeposits[item.user] -= item.amount;
        if (feeNative > 0) recordEntranceFee(feeNative);
        mintAndDeploy(item.user, item.amount, shares, netAmountNative);
        return true;
    }

    function processRedemptionBatch(
        QueueStorage storage qs,
        uint256 maxToProcess,
        function(address, uint256, uint256) internal returns (bool, uint256) payout,
        function(uint256, address, uint256, string memory) internal emitRedemptionSkipped,
        function() view returns (uint256) getMaxBatchSize
    ) internal returns (uint256 processed) {
        uint256 batchLimit = getMaxBatchSize();
        if (maxToProcess == 0 || maxToProcess > batchLimit) revert InvalidBatch();

        uint256 start = qs.redemptionQueueHead;
        for (uint256 i = 0; i < maxToProcess && start + i < qs.redemptionQueueTail; i++) {
            if (_processRedemptionItem(qs, start + i, payout, emitRedemptionSkipped)) {
                processed++;
            }
        }

        _cleanRedemptionQueue(qs);
        if (processed > 0) emit QueueProcessed("redemption", processed);
    }

    function _processRedemptionItem(
        QueueStorage storage qs,
        uint256 idx,
        function(address, uint256, uint256) internal returns (bool, uint256) payout,
        function(uint256, address, uint256, string memory) internal emitRedemptionSkipped
    ) private returns (bool success) {
        QueueItem storage item = qs.redemptionQueue[idx];
        if (item.processed) return false;

        (bool ok, uint256 paid) = payout(item.user, item.amount, item.nav);
        if (!ok) {
            emitRedemptionSkipped(idx, item.user, item.amount, "payout failed");
            return false;
        }

        if (paid < item.minOutput) {
            emitRedemptionSkipped(idx, item.user, item.amount, "slippage");
            return false;
        }

        item.processed = true;
        qs.pendingRedemptions[item.user] -= item.amount;
        return true;
    }

    /// @dev Iterates only the caller's own queue indices (B-HIGH-2). Pre-fix
    /// these scanned the whole queue head→tail, so a user with an item at
    /// index 999 of a 1000-item queue couldn't cancel without hitting the
    /// block gas limit. The per-user index list is already maintained at
    /// queueDeposit / queueRedemption time, so we only need to walk it.
    function cancelDeposits(
        QueueStorage storage qs,
        address user,
        uint256 maxCancellations,
        function(address, uint256) internal transferBack
    ) internal returns (uint256 cancelled) {
        if (qs.pendingDeposits[user] == 0) revert NoPending();

        uint256[] storage indices = qs.userDepositIndices[user];
        uint256 count = 0;
        for (uint256 i = 0; i < indices.length && count < maxCancellations; i++) {
            uint256 idx = indices[i];
            if (idx >= qs.depositQueueTail) continue;
            QueueItem storage item = qs.depositQueue[idx];
            if (item.processed || item.user != user || item.amount == 0) continue;

            item.processed = true;
            qs.pendingDeposits[user] -= item.amount;
            cancelled += item.amount;
            transferBack(user, item.amount);
            emit DepositCancelled(user, item.amount);
            count++;
        }
        _cleanDepositQueue(qs);
    }

    function cancelRedemptions(
        QueueStorage storage qs,
        address user,
        uint256 maxCancellations,
        function(address, uint256) internal mintBack
    ) internal returns (uint256 cancelled) {
        if (qs.pendingRedemptions[user] == 0) revert NoPending();

        uint256[] storage indices = qs.userRedemptionIndices[user];
        uint256 count = 0;
        for (uint256 i = 0; i < indices.length && count < maxCancellations; i++) {
            uint256 idx = indices[i];
            if (idx >= qs.redemptionQueueTail) continue;
            QueueItem storage item = qs.redemptionQueue[idx];
            if (item.processed || item.user != user) continue;

            item.processed = true;
            qs.pendingRedemptions[user] -= item.amount;
            cancelled += item.amount;
            mintBack(user, item.amount);
            emit RedemptionCancelled(user, item.amount);
            count++;
        }
        _cleanRedemptionQueue(qs);
    }

    function cancelDepositByIndex(
        QueueStorage storage qs,
        uint256 queueIdx,
        function(address, uint256) internal transferBack
    ) internal {
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
        function(address, uint256) internal mintBack
    ) internal {
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
        function(address, uint256) internal transferBack
    ) internal {
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
        function(address, uint256) internal mintBack
    ) internal {
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

    function queueLengths(QueueStorage storage qs)
        external
        view
        returns (uint256 deposits, uint256 redemptions)
    {
        deposits = qs.depositQueueTail - qs.depositQueueHead;
        redemptions = qs.redemptionQueueTail - qs.redemptionQueueHead;
    }

    function getUserDepositIndices(
        QueueStorage storage qs,
        address user
    ) external view returns (uint256[] memory indices) {
        return qs.userDepositIndices[user];
    }

    function getUserRedemptionIndices(
        QueueStorage storage qs,
        address user
    ) external view returns (uint256[] memory indices) {
        return qs.userRedemptionIndices[user];
    }

    function getDepositsByIndices(
        QueueStorage storage qs,
        uint256[] calldata indices
    ) external view returns (QueueItem[] memory items) {
        items = new QueueItem[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] < qs.depositQueueTail) {
                items[i] = qs.depositQueue[indices[i]];
            }
        }
    }

    function getRedemptionsByIndices(
        QueueStorage storage qs,
        uint256[] calldata indices
    ) external view returns (QueueItem[] memory items) {
        items = new QueueItem[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] < qs.redemptionQueueTail) {
                items[i] = qs.redemptionQueue[indices[i]];
            }
        }
    }

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

    function _enforceUserLimit(QueueStorage storage qs, address user, bool isDeposit) internal view {
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

    function _cleanDepositQueue(QueueStorage storage qs) internal {
        while (qs.depositQueueHead < qs.depositQueueTail && qs.depositQueue[qs.depositQueueHead].processed) {
            delete qs.depositQueue[qs.depositQueueHead];
            qs.depositQueueHead++;
        }
    }

    function _cleanRedemptionQueue(QueueStorage storage qs) internal {
        while (qs.redemptionQueueHead < qs.redemptionQueueTail && qs.redemptionQueue[qs.redemptionQueueHead].processed) {
            delete qs.redemptionQueue[qs.redemptionQueueHead];
            qs.redemptionQueueHead++;
        }
    }
}
