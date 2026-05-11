'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useRedeem, useUserPosition, useNavPerShare } from '@/hooks/useVault'
import { parseTokenInput, calculateSlippage, formatToken } from '@/lib/utils'
import { TrendingDown, Loader2, CheckCircle, XCircle } from 'lucide-react'

export function RedeemForm() {
  const { address } = useAccount()
  const [shares, setShares] = useState('')
  const [slippage, setSlippage] = useState('0.5')

  const position = useUserPosition(address)
  const navPerShare = useNavPerShare()
  const redeem = useRedeem()

  const userShares = position.data?.[0] ?? 0n
  const nav = navPerShare.data ?? 0n

  // navPerShare is 18-dec normalized × 1e18 (i.e. 30-dec scaled).
  // shares (18-dec) * nav / 1e18 / 1e12 = USDC native (6-dec).
  const NORMALIZE_USDC = 10n ** 12n // 18 - 6
  const parsedShares = parseTokenInput(shares, 18)
  const estimatedAmount =
    nav > 0n ? (parsedShares * nav) / BigInt(1e18) / NORMALIZE_USDC : 0n

  const handleRedeem = async () => {
    // minAmountOut is in USDC native — match what the contract pays out.
    const minAmountOut = calculateSlippage(estimatedAmount, parseFloat(slippage) * 100)
    redeem.redeem(parsedShares, minAmountOut)
  }

  return (
    <div className="card">
      <div className="flex items-center space-x-3 mb-6">
        <div className="p-2 bg-red-50 dark:bg-red-900/20 rounded-lg">
          <TrendingDown className="h-6 w-6 text-red-600 dark:text-red-400" />
        </div>
        <div>
          <h2 className="text-xl font-bold text-gray-900 dark:text-white">
            Redeem
          </h2>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Withdraw funds from the vault
          </p>
        </div>
      </div>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Shares to Redeem
          </label>
          <input
            type="text"
            value={shares}
            onChange={(e) => setShares(e.target.value)}
            placeholder="0.00"
            className="input-field"
          />
          <div className="mt-1 flex justify-between text-sm">
            <p className="text-gray-500 dark:text-gray-400">
              Your shares: {formatToken(userShares, 18)}
            </p>
            <button
              onClick={() => setShares(formatToken(userShares, 18, 18))}
              className="text-primary-600 hover:text-primary-700 dark:text-primary-400"
            >
              Max
            </button>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Slippage Tolerance (%)
          </label>
          <input
            type="text"
            value={slippage}
            onChange={(e) => setSlippage(e.target.value)}
            placeholder="0.5"
            className="input-field"
          />
        </div>

        {parsedShares > 0n && (
          <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-4">
            <p className="text-sm text-gray-600 dark:text-gray-400">
              Estimated amount
            </p>
            <p className="text-lg font-semibold text-gray-900 dark:text-white">
              {formatToken(estimatedAmount, 6)} USDC
            </p>
          </div>
        )}

        <button
          onClick={handleRedeem}
          disabled={redeem.isPending || redeem.isConfirming || !shares}
          className="btn-danger w-full"
        >
          {redeem.isPending || redeem.isConfirming ? (
            <>
              <Loader2 className="h-5 w-5 animate-spin mr-2" />
              Redeeming...
            </>
          ) : (
            'Redeem'
          )}
        </button>

        {redeem.isSuccess && (
          <div className="flex items-center space-x-2 text-green-600 dark:text-green-400 text-sm">
            <CheckCircle className="h-5 w-5" />
            <span>Redemption queued successfully!</span>
          </div>
        )}

        {redeem.error && (
          <div className="flex items-center space-x-2 text-red-600 dark:text-red-400 text-sm">
            <XCircle className="h-5 w-5" />
            <span>Error: {redeem.error.message}</span>
          </div>
        )}
      </div>
    </div>
  )
}
