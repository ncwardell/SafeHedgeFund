'use client'

import {useAccount} from 'wagmi'
import {Navigation} from '@/components/Navigation'
import {PoolStats} from './components/PoolStats'
import {SwapForm} from './components/SwapForm'
import {CollateralForm} from './components/CollateralForm'
import {BorrowForm} from './components/BorrowForm'
import {UsdcFaucet} from './components/UsdcFaucet'
import {Wallet} from 'lucide-react'

export default function LendingPage() {
  const {isConnected} = useAccount()

  if (!isConnected) {
    return (
      <>
        <Navigation />
        <div className="min-h-[80vh] grid place-items-center px-4">
          <div className="card max-w-md w-full text-center">
            <div className="mx-auto w-12 h-12 rounded-2xl bg-primary-50 dark:bg-primary-900/40 grid place-items-center mb-4">
              <Wallet className="h-6 w-6 text-primary-600 dark:text-primary-300" />
            </div>
            <h1 className="text-xl font-semibold tracking-tight text-surface-900 dark:text-surface-50 mb-1">
              Connect your wallet
            </h1>
            <p className="text-sm text-surface-500 dark:text-surface-400">
              Connect on chain 4441 (LitVM LiteForge) to use the shared pool.
            </p>
          </div>
        </div>
      </>
    )
  }

  return (
    <>
      <Navigation />
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <header className="mb-8">
          <div className="flex items-center gap-2 text-xs uppercase tracking-wider text-surface-500 mb-1">
            <span className="h-1.5 w-1.5 rounded-full bg-accent-emerald animate-pulse" />
            Live · LitVM LiteForge
          </div>
          <h1 className="text-3xl md:text-4xl font-semibold tracking-tight text-surface-900 dark:text-surface-50">
            Lending & Pool
          </h1>
          <p className="mt-2 text-sm text-surface-600 dark:text-surface-400 max-w-2xl">
            Single shared pool: USDC reserves do triple duty for AMM swaps,
            lending capacity, and liquidation absorption. The HFS reserve is
            derived as <span className="font-mono text-surface-700 dark:text-surface-200">usdcReserve / NAV</span>;
            xy=k slippage applies on each swap, and the curve re-derives implicitly as NAV moves.
          </p>
        </header>

        <PoolStats />

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
          <SwapForm />
          <CollateralForm />
          <BorrowForm />
          <UsdcFaucet />
        </div>
      </main>
    </>
  )
}
