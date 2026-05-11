'use client'

import { Navigation } from '@/components/Navigation'
import { StatsCard } from '@/components/StatsCard'
import { DepositForm } from './components/DepositForm'
import { RedeemForm } from './components/RedeemForm'
import { PositionOverview } from './components/PositionOverview'
import { useAccount } from 'wagmi'
import {
  useNavPerShare,
  useTotalAum,
  useUserPosition,
  useVaultStatus,
} from '@/hooks/useVault'
import { formatToken, formatUSD } from '@/lib/utils'
import {
  DollarSign,
  TrendingUp,
  Wallet,
  AlertCircle
} from 'lucide-react'

export default function UserDashboard() {
  const { address, isConnected } = useAccount()
  const navPerShare = useNavPerShare()
  const totalAum = useTotalAum()
  const position = useUserPosition(address)
  const vaultStatus = useVaultStatus()

  if (!isConnected) {
    return (
      <>
        <Navigation />
        <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center">
          <div className="card max-w-md w-full text-center">
            <Wallet className="h-16 w-16 text-primary-600 mx-auto mb-4" />
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
              Connect Your Wallet
            </h1>
            <p className="text-gray-600 dark:text-gray-400">
              Please connect your wallet to access the hedge fund portal
            </p>
          </div>
        </div>
      </>
    )
  }

  const userShares = position.data?.[0] ?? 0n
  const userValue = position.data?.[1] ?? 0n // USDC native (6-dec)

  return (
    <>
      <Navigation />
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          {/* Status Alerts */}
          {vaultStatus.paused && (
            <div className="mb-6 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-4 flex items-start">
              <AlertCircle className="h-5 w-5 text-yellow-600 dark:text-yellow-500 mt-0.5 mr-3" />
              <div>
                <h3 className="font-semibold text-yellow-800 dark:text-yellow-300">
                  Vault Paused
                </h3>
                <p className="text-sm text-yellow-700 dark:text-yellow-400">
                  The vault is currently paused. Deposits and redemptions are temporarily disabled.
                </p>
              </div>
            </div>
          )}

          {vaultStatus.emergencyMode && (
            <div className="mb-6 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 flex items-start">
              <AlertCircle className="h-5 w-5 text-red-600 dark:text-red-500 mt-0.5 mr-3" />
              <div>
                <h3 className="font-semibold text-red-800 dark:text-red-300">
                  Emergency Mode Active
                </h3>
                <p className="text-sm text-red-700 dark:text-red-400">
                  The vault is in emergency mode. Only emergency withdrawals are available.
                </p>
              </div>
            </div>
          )}

          {/* Header */}
          <div className="mb-8">
            <h1 className="text-3xl font-bold text-gray-900 dark:text-white">
              Investor Dashboard
            </h1>
            <p className="mt-2 text-gray-600 dark:text-gray-400">
              Manage your hedge fund investments
            </p>
          </div>

          {/* Stats Grid */}
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
            <StatsCard
              title="NAV Per Share"
              value={formatUSD(navPerShare.data, 30)}
              subtitle="Current share value"
              icon={TrendingUp}
              loading={navPerShare.isLoading}
            />
            <StatsCard
              title="Total AUM"
              value={formatUSD(totalAum.data, 6)}
              subtitle="Assets under management"
              icon={DollarSign}
              loading={totalAum.isLoading}
            />
            <StatsCard
              title="Your Position"
              value={formatUSD(userValue, 6)}
              subtitle={`${formatToken(userShares, 18)} shares`}
              icon={Wallet}
              loading={position.isLoading}
            />
          </div>

          {/* Position Overview */}
          <div className="mb-8">
            <PositionOverview />
          </div>

          {/* Deposit and Redeem Forms */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <DepositForm />
            <RedeemForm />
          </div>
        </div>
      </div>
    </>
  )
}
