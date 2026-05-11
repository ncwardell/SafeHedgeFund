'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useMintUsdc, useUsdcBalance } from '@/hooks/usePool'
import { formatToken, parseTokenInput } from '@/lib/utils'
import { Droplet, Loader2, CheckCircle, XCircle } from 'lucide-react'

export function UsdcFaucet() {
  const { address } = useAccount()
  const [amount, setAmount] = useState('1000')
  const balance = useUsdcBalance(address)
  const mint = useMintUsdc()

  const handleMint = () => {
    if (!address) return
    mint.mint(address, parseTokenInput(amount, 6))
  }

  const isPending = mint.isPending || mint.isConfirming

  return (
    <div className="card">
      <div className="flex items-center space-x-3 mb-4">
        <div className="p-2 bg-cyan-50 dark:bg-cyan-900/20 rounded-lg">
          <Droplet className="h-6 w-6 text-cyan-600 dark:text-cyan-400" />
        </div>
        <div>
          <h2 className="text-xl font-bold text-gray-900 dark:text-white">
            Testnet USDC Faucet
          </h2>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            MockUSDC.mint is permissionless on this deployment.
          </p>
        </div>
      </div>

      <div className="space-y-3">
        <div className="text-sm text-gray-600 dark:text-gray-400">
          Wallet balance:{' '}
          <span className="font-semibold text-gray-900 dark:text-white">
            {formatToken((balance.data as bigint | undefined) ?? 0n, 6)} USDC
          </span>
        </div>
        <div className="flex space-x-2">
          <input
            type="text"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="1000"
            className="input-field flex-1"
          />
          <button
            onClick={handleMint}
            disabled={!address || isPending || !amount}
            className="btn-primary"
          >
            {isPending ? (
              <Loader2 className="h-5 w-5 animate-spin" />
            ) : (
              'Mint'
            )}
          </button>
        </div>

        {mint.isSuccess && (
          <div className="flex items-center space-x-2 text-green-600 dark:text-green-400 text-sm">
            <CheckCircle className="h-5 w-5" />
            <span>USDC minted to your wallet.</span>
          </div>
        )}

        {mint.error && (
          <div className="flex items-center space-x-2 text-red-600 dark:text-red-400 text-sm">
            <XCircle className="h-5 w-5" />
            <span>{mint.error.message}</span>
          </div>
        )}
      </div>
    </div>
  )
}
