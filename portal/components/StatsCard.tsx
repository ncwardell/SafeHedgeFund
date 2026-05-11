import {LucideIcon} from 'lucide-react'

interface StatsCardProps {
  title: string
  value: string | number
  subtitle?: string
  icon?: LucideIcon
  trend?: {
    value: number
    isPositive: boolean
  }
  loading?: boolean
}

export function StatsCard({title, value, subtitle, icon: Icon, trend, loading}: StatsCardProps) {
  if (loading) {
    return (
      <div className="card">
        <div className="skeleton h-3 w-1/3 mb-4" />
        <div className="skeleton h-8 w-2/3 mb-3" />
        <div className="skeleton h-3 w-1/4" />
      </div>
    )
  }

  return (
    <div className="card group transition-shadow hover:shadow-glow">
      <div className="flex items-start justify-between gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs font-medium uppercase tracking-wider text-surface-500 dark:text-surface-400">
            {title}
          </p>
          <p className="mt-2 text-2xl md:text-3xl font-semibold tracking-tight text-surface-900 dark:text-surface-50 font-tabular truncate">
            {value}
          </p>
          {subtitle && (
            <p className="mt-1 text-sm text-surface-500 dark:text-surface-400 truncate">
              {subtitle}
            </p>
          )}
          {trend && (
            <div className="mt-2 flex items-center gap-2">
              <span
                className={`pill ${
                  trend.isPositive
                    ? 'bg-accent-emerald/10 text-accent-emerald'
                    : 'bg-accent-rose/10 text-accent-rose'
                }`}
              >
                {trend.isPositive ? '+' : ''}
                {trend.value.toFixed(2)}%
              </span>
              <span className="text-xs text-surface-500">vs last period</span>
            </div>
          )}
        </div>
        {Icon && (
          <div className="shrink-0 p-2.5 rounded-xl bg-primary-50 dark:bg-primary-900/30 ring-1 ring-primary-100/60 dark:ring-primary-800/40">
            <Icon className="h-5 w-5 text-primary-600 dark:text-primary-300" />
          </div>
        )}
      </div>
    </div>
  )
}
