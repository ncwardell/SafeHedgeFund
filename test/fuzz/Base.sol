// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

import "../../contracts/SafeHedgeFundVault.sol";
import "../mocks/MockSafe.sol";

/// @notice Mock ERC20 with parameterizable decimals. Used to fuzz the vault
/// against tokens with different decimals (USDC=6, WBTC=8, DAI/WETH=18).
contract MockToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint8 _decimals) {
        decimals = _decimals;
        name = "MockToken";
        symbol = "MOCK";
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Common setup shared by all fuzz harnesses.
abstract contract FuzzBase is Test {
    SafeHedgeFundVault internal vault;
    MockSafe internal safe;
    MockToken internal token;

    address internal admin = address(this);
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal rescueTreasury = makeAddr("rescueTreasury");
    address internal aumUpdater = makeAddr("aumUpdater");
    address internal processor = makeAddr("processor");
    address internal guardian = makeAddr("guardian");

    uint256 internal minDeposit;
    uint256 internal minRedemption;

    function _deployVault(uint8 decimals_) internal {
        token = new MockToken(decimals_);
        safe = new MockSafe();

        // Scale mins to the token's decimals.
        minDeposit = 10 ** decimals_;     // 1 unit
        minRedemption = 10 ** decimals_;  // 1 unit

        vault = new SafeHedgeFundVault(
            address(token),
            address(safe),
            feeRecipient,
            rescueTreasury,
            minDeposit,
            minRedemption
        );

        safe.enableModule(address(vault));
        vault.grantRole(vault.AUM_UPDATER_ROLE(), aumUpdater);
        vault.grantRole(vault.PROCESSOR_ROLE(), processor);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        // Past the cooldown window for any later config changes.
        vm.warp(6 days);

        // Seed initial AUM.
        token.mint(address(safe), 1);
        vm.prank(aumUpdater);
        vault.updateAum(1);
    }

    function _refreshAum() internal {
        uint256 newAum = token.balanceOf(address(safe)) + token.balanceOf(address(vault));
        vm.prank(aumUpdater);
        vault.updateAum(newAum);
    }

    function _depositAs(address user, uint256 amount, uint256 minShares) internal {
        deal(address(token), user, amount);
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, minShares);
        vm.stopPrank();
    }

    function _processOneDeposit() internal {
        vm.prank(processor);
        vault.processDepositQueue(1);
    }

    function _processOneRedemption() internal {
        vm.prank(processor);
        vault.processRedemptionQueue(1);
    }

    function _setFeeBps(string memory key, uint256 bps) internal {
        vault.proposeConfigChange(key, bps);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeConfigProposal(key, bps);
        _refreshAum();
    }
}
