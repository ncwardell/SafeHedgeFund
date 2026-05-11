'use client'

import Link from 'next/link'
import { Navigation } from '@/components/Navigation'
import { useAccount } from 'wagmi'
import {
  useTotalAum,
  useNavPerShare,
  useUserRoles,
  useVaultStatus,
} from '@/hooks/useVault'
import { formatUSD } from '@/lib/utils'
import {
  TrendingUp,
  Shield,
  Users,
  Activity,
  Settings,
  ArrowRight,
  CheckCircle,
  AlertCircle,
} from 'lucide-react'

export default function Home() {
  const { isConnected } = useAccount()
  const totalAum = useTotalAum()
  const navPerShare = useNavPerShare()
  const roles = useUserRoles()
  const vaultStatus = useVaultStatus()

  const features = [
    {
      icon: Shield,
      title: 'Institutional Grade Security',
      description: 'Gnosis Safe integration with role-based access control and emergency mechanisms',
    },
    {
      icon: TrendingUp,
      title: 'Transparent Performance',
      description: 'Real-time NAV tracking with high water mark performance fee system',
    },
    {
      icon: Users,
      title: 'Queue-Based Processing',
      description: 'Fair deposit and redemption processing with KYC compliance support',
    },
    {
      icon: Activity,
      title: 'Comprehensive Fee Management',
      description: 'Management, performance, entrance, and exit fees with transparent accrual',
    },
  ]

  const roleCards = [
    {
      title: 'Investor Dashboard',
      description: 'Deposit funds, redeem shares, and track your position',
      icon: TrendingUp,
      href: '/user',
      show: true,
      color: 'blue',
    },
    {
      title: 'Admin Panel',
      description: 'Manage vault configuration, fees, and controls',
      icon: Settings,
      href: '/admin',
      show: roles.isAdmin,
      color: 'purple',
    },
    {
      title: 'AUM Updater',
      description: 'Update assets under management and track performance',
      icon: Activity,
      href: '/aum-updater',
      show: roles.isAumUpdater,
      color: 'green',
    },
    {
      title: 'Processor',
      description: 'Process deposit and redemption queues',
      icon: Users,
      href: '/processor',
      show: roles.isProcessor,
      color: 'orange',
    },
    {
      title: 'Guardian',
      description: 'Emergency controls and vault protection',
      icon: Shield,
      href: '/guardian',
      show: roles.isGuardian,
      color: 'red',
    },
  ]

  return (
    <>
      <Navigation />
      <div className="min-h-screen bg-gradient-to-b from-gray-50 to-white dark:from-gray-900 dark:to-gray-800">
        {/* Hero Section */}
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-16">
          <div className="text-center mb-16">
            <h1 className="text-5xl font-bold text-gray-900 dark:text-white mb-4">
              Hedge Fund Management Portal
            </h1>
            <p className="text-xl text-gray-600 dark:text-gray-400 max-w-3xl mx-auto">
              Professional DeFi hedge fund management with institutional-grade security,
              transparent fee structures, and role-based access control
            </p>
          </div>

          {/* Status Alert */}
          {vaultStatus.paused && (
            <div className="mb-8 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-4 max-w-3xl mx-auto">
              <div className="flex items-start">
                <AlertCircle className="h-5 w-5 text-yellow-600 dark:text-yellow-500 mt-0.5 mr-3" />
                <div>
                  <h3 className="font-semibold text-yellow-800 dark:text-yellow-300">
                    Vault Status: Paused
                  </h3>
                  <p className="text-sm text-yellow-700 dark:text-yellow-400">
                    The vault is currently paused. Please contact the administrator.
                  </p>
                </div>
              </div>
            </div>
          )}

          {/* Stats */}
          {isConnected && (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-16 max-w-3xl mx-auto">
              <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6 border border-gray-200 dark:border-gray-700">
                <p className="text-sm font-medium text-gray-600 dark:text-gray-400 mb-2">
                  Total AUM
                </p>
                <p className="text-3xl font-bold text-gray-900 dark:text-white">
                  {formatUSD(totalAum.data, 6)}
                </p>
              </div>
              <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6 border border-gray-200 dark:border-gray-700">
                <p className="text-sm font-medium text-gray-600 dark:text-gray-400 mb-2">
                  NAV Per Share
                </p>
                <p className="text-3xl font-bold text-gray-900 dark:text-white">
                  {formatUSD(navPerShare.data, 30)}
                </p>
              </div>
            </div>
          )}

          {/* Role-Based Quick Access */}
          {isConnected && (
            <div className="mb-16">
              <h2 className="text-3xl font-bold text-gray-900 dark:text-white text-center mb-8">
                Quick Access
              </h2>
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                {roleCards.map((card) => {
                  if (!card.show) return null
                  const Icon = card.icon

                  return (
                    <Link
                      key={card.href}
                      href={card.href}
                      className="group bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6 border border-gray-200 dark:border-gray-700 hover:shadow-xl transition-all hover:-translate-y-1"
                    >
                      <div className={`p-3 bg-${card.color}-50 dark:bg-${card.color}-900/20 rounded-lg w-fit mb-4`}>
                        <Icon className={`h-8 w-8 text-${card.color}-600 dark:text-${card.color}-400`} />
                      </div>
                      <h3 className="text-xl font-bold text-gray-900 dark:text-white mb-2 group-hover:text-primary-600">
                        {card.title}
                      </h3>
                      <p className="text-gray-600 dark:text-gray-400 mb-4">
                        {card.description}
                      </p>
                      <div className="flex items-center text-primary-600 dark:text-primary-400 font-semibold">
                        Access <ArrowRight className="ml-2 h-5 w-5 group-hover:translate-x-1 transition-transform" />
                      </div>
                    </Link>
                  )
                })}
              </div>
            </div>
          )}

          {/* Features Grid */}
          <div className="mb-16">
            <h2 className="text-3xl font-bold text-gray-900 dark:text-white text-center mb-8">
              Platform Features
            </h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              {features.map((feature) => {
                const Icon = feature.icon
                return (
                  <div
                    key={feature.title}
                    className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6 border border-gray-200 dark:border-gray-700"
                  >
                    <div className="flex items-start space-x-4">
                      <div className="p-3 bg-primary-50 dark:bg-primary-900/20 rounded-lg">
                        <Icon className="h-6 w-6 text-primary-600 dark:text-primary-400" />
                      </div>
                      <div>
                        <h3 className="text-lg font-bold text-gray-900 dark:text-white mb-2">
                          {feature.title}
                        </h3>
                        <p className="text-gray-600 dark:text-gray-400">
                          {feature.description}
                        </p>
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>

          {/* CTA Section */}
          {!isConnected && (
            <div className="text-center bg-primary-50 dark:bg-primary-900/20 rounded-xl p-12 border border-primary-200 dark:border-primary-800">
              <h2 className="text-3xl font-bold text-gray-900 dark:text-white mb-4">
                Get Started
              </h2>
              <p className="text-lg text-gray-600 dark:text-gray-400 mb-8 max-w-2xl mx-auto">
                Connect your wallet to access the hedge fund portal and manage your investments
              </p>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Use the "Connect Wallet" button in the navigation bar above
              </p>
            </div>
          )}
        </div>
      </div>
    </>
  )
}
