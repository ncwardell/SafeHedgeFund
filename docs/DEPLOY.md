# Deploying to LitVM LiteForge

End-to-end recipe for shipping the full stack (MockUSDC + MockSafe + Vault +
SharedPool) onto LitVM LiteForge and pointing the portal at it.

## Chain reference

| | |
|---|---|
| Chain ID | `4441` |
| Name | LitVM LiteForge |
| RPC | `https://liteforge.rpc.caldera.xyz/http` |
| WS  | `wss://liteforge.rpc.caldera.xyz/ws` |
| Explorer | `https://liteforge.explorer.caldera.xyz` |
| Native gas token | `zkLTC` (18 decimals) |

You'll need a small balance of `zkLTC` in the deployer wallet to cover gas.

---

## 1. Prereqs

The repo ships a Nix flake that pins `foundry-bin`, `bun`, and `nodejs_20`.
Drop into the dev shell:

```sh
nix develop
```

(Or prefix individual commands with `nix develop --command <cmd>`.)

Then export deployer credentials:

```sh
export DEPLOYER_KEY=0x<your_private_key>
export RPC_URL=https://liteforge.rpc.caldera.xyz/http
```

A funded EOA on LiteForge is required to cover gas in `zkLTC`.

## 2. Build

From repo root, inside the dev shell:

```sh
forge build
```

This compiles with `via_ir = true` (set in `foundry.toml`) — required to
keep the vault under the 24,576-byte EIP-170 limit.

## 3. (Optional) dry run on local anvil

Sanity check the deploy script before spending real gas:

```sh
anvil &
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

Look for the `=== Deployment complete ===` block and check
`deployments/31337.json` got written.

## 4. Deploy to LiteForge

```sh
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_KEY \
  --broadcast
```

The script will:

1. Deploy `MockUSDC` (6 decimals, permissionless `mint` for testers)
2. Deploy `MockSafe`
3. Deploy `SafeHedgeFundVault` with deployer as admin and conservative mins
4. Enable the vault as a Safe module
5. Grant `AUM_UPDATER`, `PROCESSOR`, `GUARDIAN` roles to deployer
6. Deploy `SharedPool` and wire it to the vault
7. Bootstrap state in the right order:
   - Mint 200K USDC to deployer
   - Seed AUM (1 wei) so `updateAum` doesn't revert on the first call
   - Enable auto-process for deposits + redemptions
   - Deposit 100K USDC into the vault → mints HFS
   - Refresh AUM
   - Supply 100K USDC into the pool (donation; no LP shares in v1)
   - Final AUM refresh

Addresses are printed to stdout and written to `deployments/4441.json`:

```json
{
  "chainId": 4441,
  "deployer": "0x...",
  "usdc": "0x...",
  "safe": "0x...",
  "vault": "0x...",
  "pool": "0x..."
}
```

## 5. Wire up the portal

Create `portal/.env.local` with the four addresses from `deployments/4441.json`:

```sh
NEXT_PUBLIC_VAULT_ADDRESS=0x...
NEXT_PUBLIC_POOL_ADDRESS=0x...
NEXT_PUBLIC_USDC_ADDRESS=0x...
NEXT_PUBLIC_SAFE_ADDRESS=0x...
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=<your_wc_project_id>
```

The chain definition (`litvmLiteforge`, id `4441`) is already in
`portal/lib/wagmi.ts`.

## 6. Run the portal

```sh
cd portal
bun install
bun run dev
```

Open <http://localhost:3000> and connect a wallet on chain `4441`.

## 7. Tester flow

Anyone with a wallet on LiteForge can:

1. Call `MockUSDC.mint(<their_address>, <amount>)` — permissionless, gives
   them test USDC
2. Approve the vault for that USDC, call `deposit(amount, 0)` — auto-process
   is on, so HFS mints in the same tx
3. Approve the pool with their HFS, call `depositCollateral` then `borrow` —
   pulls USDC at up to 50% LLTV
4. Or call `swapHfsForUsdc` / `swapUsdcForHfs` for instant exits/entries
   against the pool's xy=k curve

## 8. Keeper duties

The portal does not run a keeper. As deployer (you have `AUM_UPDATER_ROLE`)
you should periodically call:

```sh
cast send $VAULT "updateAum(uint256)" <new_aum> \
  --rpc-url $RPC_URL --private-key $DEPLOYER_KEY
```

`updateAum` also sweeps liquidations on the pool, so it does double duty.
A safe value during testing:

```sh
SAFE_BAL=$(cast call $USDC "balanceOf(address)(uint256)" $SAFE --rpc-url $RPC_URL)
POOL_BAL=$(cast call $USDC "balanceOf(address)(uint256)" $POOL --rpc-url $RPC_URL)
NEW_AUM=$((SAFE_BAL + POOL_BAL))
cast send $VAULT "updateAum(uint256)" $NEW_AUM --rpc-url $RPC_URL --private-key $DEPLOYER_KEY
```

(Real production AUM would also include the value of any positions held in
the Safe beyond plain USDC.)

## Troubleshooting

**`ContractSizeAboveLimit` on deploy.** Confirm `via_ir = true` is still in
`foundry.toml [profile.default]`.

**`updateAum` reverts with `MaxAumAgeExceeded` or similar after long idle.**
The `maxAumAge` config in `getFundConfig()` enforces a freshness window.
Bump it via the timelocked config flow if testing across long gaps.

**Portal shows zero everywhere.** Most likely `.env.local` addresses don't
match the chain you're connected to. Check the chain ID in your wallet
matches `4441` and the addresses in `.env.local` match `deployments/4441.json`.

**`SwapFrozenThisBlock` on a swap.** Same-block freeze after `updateAum` —
expected; just wait one block.
