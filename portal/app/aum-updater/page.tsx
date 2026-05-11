'use client'

import { useState } from 'react'
import { Navigation } from '@/components/Navigation'
import { StatsCard } from '@/components/StatsCard'
import { useAccount } from 'wagmi'
import {
  useTotalAum,
  useNavPerShare,
  useUpdateAum,
  useUserRoles,
  useHWMStatus,
} from '@/hooks/useVault'
import { formatUSD, formatToken, parseTokenInput } from '@/lib/utils'
import {
  TrendingUp,
  DollarSign,
  Activity,
  Loader2,
  CheckCircle,
  XCircle,
  AlertCircle,
} from 'lucide-react'

export default function AumUpdaterDashboard() {
  const { isConnected } = useAccount()
  const roles = useUserRoles()
  const totalAum = useTotalAum()
  const navPerShare = useNavPerShare()
  const hwmStatus = useHWMStatus()
  const updateAum = useUpdateAum()

  const [newAum, setNewAum] = useState('')

  const handleUpdateAum = () => {
    // AUM is in USDC native decimals (6) — input is human-readable USDC.
    const parsedAum = parseTokenInput(newAum, 6)
    updateAum.updateAum(parsedAum)
    setNewAum('')
  }

  if (!isConnected) {
    return (
      <>
        <Navigation />
        <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center">
          <div className="card max-w-md w-full text-center">
            <Activity className="h-16 w-16 text-primary-600 mx-auto mb-4" />
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
              Connect Your Wallet
            </h1>
            <p className="text-gray-600 dark:text-gray-400">
              Please connect your wallet to access the AUM updater panel
            </p>
          </div>
        </div>
      </>
    )
  }

  if (!roles.isAumUpdater && !roles.isLoading) {
    return (
      <>
        <Navigation />
        <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center">
          <div className="card max-w-md w-full text-center">
            <AlertCircle className="h-16 w-16 text-red-600 mx-auto mb-4" />
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
              Access Denied
            </h1>
            <p className="text-gray-600 dark:text-gray-400">
              You do not have AUM updater permissions for this vault
            </p>
          </div>
        </div>
      </>
    )
  }

  // HWM tuple: (hwm, lowestNav, recoveryStart, daysToReset).
  // hwm/lowestNav are in NAV units (30-dec). recoveryStart is a unix timestamp,
  // daysToReset is a day count (0 outside drawdown).
  const currentHWM = hwmStatus.data?.[0] ?? 0n
  const lowestNavInDrawdown = hwmStatus.data?.[1] ?? 0n
  const recoveryStart = hwmStatus.data?.[2] ?? 0n
  const daysToReset = hwmStatus.data?.[3] ?? 0n
  const inDrawdown = lowestNavInDrawdown > 0n && recoveryStart === 0n
  const inRecovery = recoveryStart > 0n && daysToReset > 0n

  return (
    <>
      <Navigation />
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          {/* Header */}
          <div className="mb-8">
            <h1 className="text-3xl font-bold text-gray-900 dark:text-white">
              AUM Updater Dashboard
            </h1>
            <p className="mt-2 text-gray-600 dark:text-gray-400">
              Update assets under management and track performance
            </p>
          </div>

          {/* Stats Grid */}
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
            <StatsCard
              title="Current AUM"
              value={formatUSD(totalAum.data, 6)}
              subtitle="Total assets under management"
              icon={DollarSign}
              loading={totalAum.isLoading}
            />
            <StatsCard
              title="NAV Per Share"
              value={formatUSD(navPerShare.data, 30)}
              subtitle="Current share price"
              icon={TrendingUp}
              loading={navPerShare.isLoading}
            />
            <StatsCard
              title="High Water Mark"
              value={formatUSD(currentHWM, 30)}
              subtitle={inDrawdown ? 'In Drawdown' : inRecovery ? 'In Recovery' : 'Active'}
              icon={Activity}
              loading={hwmStatus.isLoading}
            />
          </div>

          {/* HWM Status Alert */}
          {inDrawdown && (
            <div className="mb-6 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4">
              <div className="flex items-start">
                <AlertCircle className="h-5 w-5 text-red-600 dark:text-red-500 mt-0.5 mr-3" />
                <div>
                  <h3 className="font-semibold text-red-800 dark:text-red-300">
                    Drawdown Period Active
                  </h3>
                  <p className="text-sm text-red-700 dark:text-red-400">
                    The fund is currently in a drawdown period. Performance fees are paused.
                  </p>
                </div>
              </div>
            </div>
          )}

          {inRecovery && (
            <div className="mb-6 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-4">
              <div className="flex items-start">
                <AlertCircle className="h-5 w-5 text-yellow-600 dark:text-yellow-500 mt-0.5 mr-3" />
                <div>
                  <h3 className="font-semibold text-yellow-800 dark:text-yellow-300">
                    Recovery Period Active
                  </h3>
                  <p className="text-sm text-yellow-700 dark:text-yellow-400">
                    The fund is recovering from a drawdown. HWM will reset after recovery period completes.
                  </p>
                </div>
              </div>
            </div>
          )}

          {/* Update AUM Form */}
          <div className="card max-w-2xl">
            <h2 className="text-xl font-bold text-gray-900 dark:text-white mb-6">
              Update Assets Under Management
            </h2>

            <div className="space-y-6">
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                  New AUM Value
                </label>
                <input
                  type="text"
                  value={newAum}
                  onChange={(e) => setNewAum(e.target.value)}
                  placeholder="Enter new AUM value"
                  className="input-field"
                />
                <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">
                  Current AUM: {formatToken(totalAum.data, 6, 2)} USDC
                </p>
              </div>

              <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
                <h4 className="font-semibold text-blue-800 dark:text-blue-300 mb-2">
                  Important Notes
                </h4>
                <ul className="text-sm text-blue-700 dark:text-blue-400 space-y-1 list-disc list-inside">
                  <li>Updating AUM will accrue management and performance fees</li>
                  <li>NAV per share will be automatically recalculated</li>
                  <li>High water mark will be updated if NAV exceeds current HWM</li>
                  <li>Ensure accurate valuation of off-chain and on-chain assets</li>
                </ul>
              </div>

              <button
                onClick={handleUpdateAum}
                disabled={updateAum.isPending || updateAum.isConfirming || !newAum}
                className="btn-primary w-full"
              >
                {updateAum.isPending || updateAum.isConfirming ? (
                  <>
                    <Loader2 className="h-5 w-5 animate-spin mr-2" />
                    Updating AUM...
                  </>
                ) : (
                  'Update AUM'
                )}
              </button>

              {updateAum.isSuccess && (
                <div className="flex items-center space-x-2 text-green-600 dark:text-green-400 text-sm">
                  <CheckCircle className="h-5 w-5" />
                  <span>AUM updated successfully!</span>
                </div>
              )}

              {updateAum.error && (
                <div className="flex items-center space-x-2 text-red-600 dark:text-red-400 text-sm">
                  <XCircle className="h-5 w-5" />
                  <span>Error: {updateAum.error.message}</span>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
