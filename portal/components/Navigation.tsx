'use client'

import Link from 'next/link'
import {usePathname} from 'next/navigation'
import {ConnectButton} from '@rainbow-me/rainbowkit'
import {useUserRoles} from '@/hooks/useVault'
import {Home, Settings, TrendingUp, Users, Shield, Coins} from 'lucide-react'

export function Navigation() {
  const pathname = usePathname()
  const roles = useUserRoles()

  const navItems = [
    {href: '/user', label: 'Dashboard', icon: Home, show: true},
    {href: '/lending', label: 'Lending', icon: Coins, show: true},
    {href: '/admin', label: 'Admin', icon: Settings, show: roles.isAdmin},
    {href: '/aum-updater', label: 'AUM', icon: TrendingUp, show: roles.isAumUpdater},
    {href: '/processor', label: 'Processor', icon: Users, show: roles.isProcessor},
    {href: '/guardian', label: 'Guardian', icon: Shield, show: roles.isGuardian},
  ]

  return (
    <nav className="sticky top-0 z-50 backdrop-blur-md bg-surface-0/70 dark:bg-surface-900/60 border-b border-surface-200/70 dark:border-surface-700/40">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between h-14">
          <div className="flex items-center gap-6">
            <Link href="/" className="flex items-center gap-2 group">
              <div className="h-7 w-7 rounded-lg bg-gradient-to-br from-primary-500 to-primary-700 grid place-items-center shadow-soft group-hover:shadow-glow transition-shadow">
                <TrendingUp className="h-4 w-4 text-white" />
              </div>
              <span className="text-sm font-semibold tracking-tight text-surface-900 dark:text-surface-50">
                Hedge Fund
              </span>
            </Link>

            <div className="hidden md:flex items-center gap-1">
              {navItems.map((item) => {
                if (!item.show) return null
                const Icon = item.icon
                const isActive = pathname.startsWith(item.href)

                return (
                  <Link
                    key={item.href}
                    href={item.href}
                    className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm font-medium transition-colors ${
                      isActive
                        ? 'bg-primary-50 text-primary-700 dark:bg-primary-900/40 dark:text-primary-200'
                        : 'text-surface-600 hover:text-surface-900 dark:text-surface-400 dark:hover:text-surface-50 hover:bg-surface-100 dark:hover:bg-surface-800/60'
                    }`}
                  >
                    <Icon className="h-4 w-4" />
                    <span>{item.label}</span>
                  </Link>
                )
              })}
            </div>
          </div>

          <div className="flex items-center">
            <ConnectButton
              accountStatus="address"
              chainStatus={{smallScreen: 'icon', largeScreen: 'icon'}}
              showBalance={false}
            />
          </div>
        </div>
      </div>
    </nav>
  )
}
