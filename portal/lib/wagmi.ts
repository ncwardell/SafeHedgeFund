import {connectorsForWallets, getDefaultConfig} from '@rainbow-me/rainbowkit'
import {
  injectedWallet,
  metaMaskWallet,
  rainbowWallet,
  trustWallet,
  walletConnectWallet,
} from '@rainbow-me/rainbowkit/wallets'
import {createConfig} from 'wagmi'
import {mainnet, sepolia, hardhat} from 'wagmi/chains'
import {defineChain, http} from 'viem'

/**
 * LitVM LiteForge — Caldera-hosted L2 for Litecoin.
 * https://liteforge.explorer.caldera.xyz
 */
export const litvmLiteforge = defineChain({
  id: 4441,
  name: 'LitVM LiteForge',
  nativeCurrency: {name: 'zkLTC', symbol: 'zkLTC', decimals: 18},
  rpcUrls: {
    default: {
      http: ['https://liteforge.rpc.caldera.xyz/http'],
      webSocket: ['wss://liteforge.rpc.caldera.xyz/ws'],
    },
  },
  blockExplorers: {
    default: {name: 'LiteForge Explorer', url: 'https://liteforge.explorer.caldera.xyz'},
  },
  testnet: true,
})

const chains = [litvmLiteforge, mainnet, sepolia, hardhat] as const

// Batched HTTP transports collapse multiple JSON-RPC calls in the same tick
// into one request — important on Caldera's throttled gateway.
const batchedHttp = (url: string) => http(url, {batch: true})

const transports = {
  [litvmLiteforge.id]: batchedHttp('https://liteforge.rpc.caldera.xyz/http'),
  [mainnet.id]: batchedHttp('https://eth.llamarpc.com'),
  [sepolia.id]: batchedHttp('https://ethereum-sepolia.publicnode.com'),
  [hardhat.id]: batchedHttp('http://127.0.0.1:8545'),
}

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID
const hasValidProjectId = !!projectId && projectId !== 'YOUR_PROJECT_ID'

// When no real WalletConnect project ID is configured, omit the WalletConnect
// connector entirely. Initializing it with a placeholder produces "Init was
// called N times" warnings and can crash mobile wallet webviews (Trust Wallet
// in particular). Injected covers Trust Wallet's browser extension and its
// in-app browser, which is what most testnet users will be on.
export const config = hasValidProjectId
  ? getDefaultConfig({
      appName: 'Hedge Fund Portal',
      projectId: projectId!,
      chains,
      transports,
      ssr: false,
    })
  : (() => {
      const connectors = connectorsForWallets(
        [
          {
            groupName: 'Recommended',
            wallets: [injectedWallet, metaMaskWallet, trustWallet],
          },
        ],
        // RainbowKit refuses an empty string here even when no WC wallet
        // is in the list. Pass a stub; it isn't used because walletConnectWallet
        // is omitted from the wallets array above.
        {appName: 'Hedge Fund Portal', projectId: 'injected-only'},
      )
      return createConfig({chains, transports, connectors, ssr: false})
    })()

// Re-export wallets for any caller that wants them.
export {injectedWallet, metaMaskWallet, rainbowWallet, trustWallet, walletConnectWallet}
