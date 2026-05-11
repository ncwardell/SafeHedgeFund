// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";

import "../contracts/SafeHedgeFundVault.sol";
import "../contracts/lending/SharedPool.sol";
import "../test/mocks/MockSafe.sol";
import "../test/mocks/MockUSDC.sol";

/**
 * @title Testnet deployment script
 * @notice Deploys the full stack to a fresh chain (LitVM LiteForge in our
 *         case): MockUSDC + MockSafe + Vault + Pool, wires them, and
 *         bootstraps initial liquidity so the UI has something to work
 *         against.
 *
 *         Run with:
 *           forge script script/Deploy.s.sol:Deploy \
 *             --rpc-url $RPC_URL \
 *             --private-key $DEPLOYER_KEY \
 *             --broadcast
 *
 *         Outputs the deployed addresses to stdout — copy into
 *         portal/lib/contracts.ts. Also writes them to deployments/<chain>.json.
 */
contract Deploy is Script {
    SafeHedgeFundVault public vault;
    SharedPool public pool;
    MockSafe public safe;
    MockUSDC public usdc;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Deploying SafeHedgeFund stack ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast(deployerKey);

        // 1. Mock USDC (6-dec) — substitute for real USDC on testnets that
        //    don't have a canonical USDC deployment.
        usdc = new MockUSDC();
        console2.log("MockUSDC:", address(usdc));

        // 2. Mock Safe — substitute for real Gnosis Safe on chains where
        //    the Safe contracts aren't deployed.
        safe = new MockSafe();
        console2.log("MockSafe:", address(safe));

        // 3. Vault. Deployer is admin (DEFAULT_ADMIN + ADMIN roles).
        //    Mins set conservatively for testing; can be raised later via
        //    timelocked config.
        vault = new SafeHedgeFundVault(
            address(usdc),
            address(safe),
            deployer,    // feeRecipient — deployer for testing
            deployer,    // rescueTreasury — deployer for testing
            10e6,        // minDeposit: 10 USDC
            1e6          // minRedemption: 1 USDC
        );
        console2.log("SafeHedgeFundVault:", address(vault));

        // 4. Wire the Safe → vault as enabled module so Safe payouts work.
        safe.enableModule(address(vault));
        console2.log("Module enabled on Safe");

        // 5. Grant operational roles to deployer (testnet — single-user).
        vault.grantRole(vault.AUM_UPDATER_ROLE(), deployer);
        vault.grantRole(vault.PROCESSOR_ROLE(), deployer);
        vault.grantRole(vault.GUARDIAN_ROLE(), deployer);
        console2.log("Roles granted");

        // 6. Deploy the lending pool.
        pool = new SharedPool(address(vault));
        console2.log("SharedPool:", address(pool));

        // 7. Wire the pool to the vault.
        vault.setSharedPool(address(pool));
        console2.log("Pool wired to vault");

        // 8. Bootstrap. Order matters: deposit FIRST (creates HFS supply at
        //    the default initial NAV), THEN supply USDC to pool (without
        //    distorting that NAV).
        usdc.mint(deployer, 200_000e6);

        // 8a. Initial AUM seed so updateAum doesn't revert on the first call.
        usdc.mint(address(safe), 1);
        vault.updateAum(1);

        // 8b. Enable auto-process so UI testing doesn't need a separate
        //     processor call after every deposit.
        vault.setAutoProcess(true, true);

        // 8c. Deployer deposits 100K USDC → mints HFS shares.
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, 0);
        // Auto-process is on, so this minted immediately.

        // 8d. Refresh AUM so NAV reflects the new state.
        vault.updateAum(usdc.balanceOf(address(safe)) + usdc.balanceOf(address(pool)));

        // 8e. Supply 100K USDC to the pool (provides AMM depth + lending
        //     capacity). NAV will rise — that's expected; supply is a
        //     "donation" to the fund in v1 (no LP shares back).
        usdc.approve(address(pool), 100_000e6);
        pool.supply(100_000e6);

        // 8f. Final AUM refresh — keeper-style update reflecting the
        //     pool's USDC.
        vault.updateAum(usdc.balanceOf(address(safe)) + usdc.balanceOf(address(pool)));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment complete ===");
        console2.log("");
        console2.log("Addresses (paste into portal/lib/contracts.ts):");
        console2.log("  USDC:", address(usdc));
        console2.log("  Safe:", address(safe));
        console2.log("  Vault:", address(vault));
        console2.log("  Pool:", address(pool));
        console2.log("");
        console2.log("Initial state:");
        console2.log("  Deployer USDC balance:", usdc.balanceOf(deployer) / 1e6, "USDC");
        console2.log("  Deployer HFS balance:", vault.balanceOf(deployer));
        console2.log("  Pool USDC reserve:", pool.usdcReserve() / 1e6, "USDC");
        console2.log("  NAV per share:", vault.navPerShare());
        console2.log("");
        console2.log("Test users can:");
        console2.log("  1. Receive USDC via mockUSDC.mint() (it's permissionless)");
        console2.log("  2. Approve vault, call deposit() to get HFS shares");
        console2.log("  3. Approve pool with their HFS, call depositCollateral + borrow");
        console2.log("  4. Call swapUsdcForHfs / swapHfsForUsdc on the pool");

        // Write addresses file for the portal to consume.
        string memory json = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "usdc": "', vm.toString(address(usdc)), '",\n',
            '  "safe": "', vm.toString(address(safe)), '",\n',
            '  "vault": "', vm.toString(address(vault)), '",\n',
            '  "pool": "', vm.toString(address(pool)), '"\n',
            "}\n"
        );
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console2.log("Addresses written to:", path);
    }
}
