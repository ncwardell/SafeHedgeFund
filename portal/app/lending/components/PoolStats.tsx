'use client'

import { StatsCard } from '@/components/StatsCard'
import { usePoolStats, useLendingConfig } from '@/hooks/usePool'
import { formatToken, formatUSD, bpsToPercent, formatPercent } from '@/lib/utils'
import { Coins, ArrowDownUp, Percent, Users } from 'lucide-react'

export function PoolStats() {
  const stats = usePoolStats()
  const config = useLendingConfig()

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
      <StatsCard
        title="USDC Reserve"
        value={formatUSD(stats.usdcReserve, 6)}
        subtitle="Available to swap & borrow"
        icon={Coins}
        loading={stats.isLoading}
      />
      <StatsCard
        title="HFS Reserve (derived)"
        value={`${formatToken(stats.hfsReserve, 18)} HFS`}
        subtitle="usdcReserve / NAV"
        icon={ArrowDownUp}
        loading={stats.isLoading}
      />
      <StatsCard
        title="Borrowed"
        value={formatUSD(stats.totalBorrowed, 6)}
        subtitle={`${stats.activeBorrowers.toString()} active borrower${stats.activeBorrowers === 1n ? '' : 's'}`}
        icon={Users}
        loading={stats.isLoading}
      />
      <StatsCard
        title="Lending Config"
        value={`LLTV ${formatPercent(bpsToPercent(Number(config.lltvBps)))}`}
        subtitle={`${formatPercent(bpsToPercent(Number(config.borrowRateBps)))} APR · ${formatPercent(bpsToPercent(Number(config.swapFeeBps)))} swap fee`}
        icon={Percent}
        loading={config.isLoading}
      />
    </div>
  )
}
