'use client'

import { useAccount } from 'wagmi'
import { useUserPosition } from '@/hooks/useVault'
import { formatToken, formatUSD } from '@/lib/utils'
import { Clock, CheckCircle, DollarSign } from 'lucide-react'

export function PositionOverview() {
  const { address } = useAccount()
  const position = useUserPosition(address)

  if (position.isLoading) {
    return (
      <div className="card animate-pulse">
        <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-1/3 mb-4"></div>
        <div className="space-y-3">
          <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded"></div>
          <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded"></div>
          <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded"></div>
        </div>
      </div>
    )
  }

  const shares = position.data?.[0] ?? 0n
  const value = position.data?.[1] ?? 0n
  const pendingDeposits = position.data?.[2] ?? 0n
  const pendingRedemptions = position.data?.[3] ?? 0n

  const hasPendingTransactions = pendingDeposits > 0n || pendingRedemptions > 0n

  return (
    <div className="card">
      <h2 className="text-xl font-bold text-gray-900 dark:text-white mb-6">
        Position Details
      </h2>

      <div className="space-y-4">
        <div className="flex justify-between items-center py-3 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-center space-x-2">
            <CheckCircle className="h-5 w-5 text-green-600" />
            <span className="text-gray-700 dark:text-gray-300">Active Shares</span>
          </div>
          <span className="text-lg font-semibold text-gray-900 dark:text-white">
            {formatToken(shares, 18)}
          </span>
        </div>

        <div className="flex justify-between items-center py-3 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-center space-x-2">
            <DollarSign className="h-5 w-5 text-green-600" />
            <span className="text-gray-700 dark:text-gray-300">Position Value</span>
          </div>
          <span className="text-lg font-semibold text-gray-900 dark:text-white">
            {formatUSD(value, 6)}
          </span>
        </div>

        <div className="flex justify-between items-center py-3 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-center space-x-2">
            <Clock className="h-5 w-5 text-yellow-600" />
            <span className="text-gray-700 dark:text-gray-300">Pending Deposits (USDC)</span>
          </div>
          <span className="text-lg font-semibold text-gray-900 dark:text-white">
            {formatToken(pendingDeposits, 6)}
          </span>
        </div>

        <div className="flex justify-between items-center py-3">
          <div className="flex items-center space-x-2">
            <Clock className="h-5 w-5 text-yellow-600" />
            <span className="text-gray-700 dark:text-gray-300">Pending Redemptions (HFS)</span>
          </div>
          <span className="text-lg font-semibold text-gray-900 dark:text-white">
            {formatToken(pendingRedemptions, 18)}
          </span>
        </div>

        {hasPendingTransactions && (
          <div className="mt-4 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
            <p className="text-sm text-blue-800 dark:text-blue-300">
              Your pending transactions will be processed by the fund administrator. Processing typically occurs within 24-48 hours.
            </p>
          </div>
        )}
      </div>
    </div>
  )
}
