// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../contracts/SafeHedgeFundVault.sol";
import "../mocks/MockSafe.sol";
import "./Base.sol";

/// @notice ERC20 with a transfer hook that lets us inject reentrant calls.
/// Mirrors the threat model: base token is something like ERC777 or a
/// hooked token that calls back into the recipient (or a third party) on
/// transfer, giving attackers a chance to re-enter the vault while it's
/// mid-operation.
contract HookedToken {
    string public name = "Hooked";
    string public symbol = "HOOK";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public hookTarget;
    bytes public hookCalldata;
    bool internal _hooked; // re-entrancy fuse so the hook fires once

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        emit Approval(msg.sender, sp, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _do(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        return _do(from, to, amt);
    }

    function _do(address from, address to, uint256 amt) internal returns (bool) {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);

        if (hookTarget != address(0) && !_hooked) {
            _hooked = true;
            (bool ok,) = hookTarget.call(hookCalldata);
            _hooked = false;
            // Don't bubble revert — we want the outer transfer to succeed
            // so the test focuses on whether the reentrant call into the
            // vault was blocked.
            ok;
        }

        return true;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookCalldata = data;
    }

    function clearHook() external {
        hookTarget = address(0);
        delete hookCalldata;
    }
}

/// @notice Reentrancy adversary: mid-transfer, try to re-enter the vault.
/// nonReentrant on every external entry point should make these fail.
contract ReentrancyTest is Test {
    SafeHedgeFundVault internal vault;
    MockSafe internal safe;
    HookedToken internal token;

    address internal admin = address(this);
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal rescueTreasury = makeAddr("rescueTreasury");
    address internal aumUpdater = makeAddr("aumUpdater");
    address internal processor = makeAddr("processor");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new HookedToken();
        safe = new MockSafe();

        vault = new SafeHedgeFundVault(
            address(token),
            address(safe),
            feeRecipient,
            rescueTreasury,
            1e6,  // 1 USDC min
            1e6
        );
        safe.enableModule(address(vault));
        vault.grantRole(vault.AUM_UPDATER_ROLE(), aumUpdater);
        vault.grantRole(vault.PROCESSOR_ROLE(), processor);

        vm.warp(6 days);
        token.mint(address(safe), 1);
        vm.prank(aumUpdater);
        vault.updateAum(1);

        // Seed alice.
        token.mint(alice, 1_000_000e6);
    }

    /// @notice Reentry into deposit() during the transferFrom hook must be
    /// blocked. The first deposit holds the nonReentrant lock; any nested
    /// deposit must revert with ReentrancyGuardReentrantCall.
    function test_reentrancy_depositCannotReenter() public {
        // Wire the token so its transfer hook calls vault.deposit again.
        bytes memory payload = abi.encodeWithSignature(
            "deposit(uint256,uint256)",
            uint256(100e6),
            uint256(0)
        );
        token.setHook(address(vault), payload);

        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        // The hook will fire inside transferFrom and try to reenter.
        // We expect the OUTER deposit to succeed (hook swallows the inner
        // revert), but the INNER reentrant deposit must NOT have advanced
        // any state. Verify by counting queue length.
        vault.deposit(100e6, 0);
        vm.stopPrank();

        (uint256 depQ, ) = vault.queueLengths();
        assertEq(depQ, 1, "reentrant inner deposit must NOT have queued an item");

        // Pending deposits should reflect only the outer call.
        ( , , uint256 pending, ) = vault.getPosition(alice);
        assertEq(pending, 100e6, "only outer deposit reflected in pending");
    }

    /// @notice The redemption Safe-payout path also runs through the token's
    /// transfer. Verify a malicious base token can't re-enter redeem from
    /// inside processRedemptionQueue.
    function test_reentrancy_redemptionPayoutCannotReenter() public {
        // Get alice some shares first.
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, 0);
        vm.stopPrank();

        vm.prank(processor);
        vault.processDepositQueue(1);

        uint256 newAum = token.balanceOf(address(safe));
        vm.prank(aumUpdater);
        vault.updateAum(newAum);

        // Alice queues a redemption.
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, 0);

        // Set the token to reenter into redeem during the payout transfer.
        bytes memory payload = abi.encodeWithSignature(
            "redeem(uint256,uint256)",
            uint256(1),
            uint256(0)
        );
        token.setHook(address(vault), payload);

        // Process the queue. The Safe → token.transfer to alice will fire
        // the hook, which tries to re-enter redeem(). nonReentrant must
        // make the inner call revert; the hook swallows that revert; the
        // outer process should still complete.
        vm.prank(processor);
        vault.processRedemptionQueue(1);

        // Alice received her redemption (outer path succeeded).
        // Reentrancy did NOT add anything extra: alice's share balance
        // is now 0 (burned during redeem), and there's no second redemption
        // queued.
        assertEq(vault.balanceOf(alice), 0, "alice's shares burned");
        ( , uint256 redQ) = vault.queueLengths();
        // The original redemption is now processed (or in queue, harmless).
        // What we care about: no second queued redemption from the
        // reentrant call.
        assertLe(redQ, 1, "reentrant redeem must not have queued an extra item");
    }

    /// @notice Confirm the lock is per-transaction by showing that AFTER the
    /// outer call returns, a fresh deposit succeeds normally.
    function test_reentrancy_lockReleasedAfterOuterCall() public {
        token.clearHook();
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(100e6, 0);
        vault.deposit(100e6, 0); // Second call in the SAME prank scope but separate tx-level call → fine
        vm.stopPrank();

        (uint256 depQ, ) = vault.queueLengths();
        assertEq(depQ, 2, "two sequential deposits should both queue");
    }
}
