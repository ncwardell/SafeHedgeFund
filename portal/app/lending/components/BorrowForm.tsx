'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import {
  useBorrow,
  useRepay,
  useUserLendingPosition,
  usePoolStats,
  useLendingConfig,
  useUsdcBalance,
  useUsdcAllowanceForPool,
  useApproveTokenForPool,
} from '@/hooks/usePool'
import { useNavPerShare } from '@/hooks/useVault'
import { USDC_ADDRESS } from '@/lib/contracts'
import {
  formatToken,
  formatUSD,
  parseTokenInput,
  bpsToPercent,
  formatPercent,
} from '@/lib/utils'
import { TrendingDown, TrendingUp, Loader2, CheckCircle, XCircle, Heart } from 'lucide-react'

const NORMALIZE_USDC = 10n ** 12n

export function BorrowForm() {
  const { address } = useAccount()
  const [mode, setMode] = useState<'borrow' | 'repay'>('borrow')
  const [amount, setAmount] = useState('')

  const navData = useNavPerShare()
  const stats = usePoolStats()
  const config = useLendingConfig()
  const position = useUserLendingPosition(address)
  const usdcBal = useUsdcBalance(address)
  const usdcAllow = useUsdcAllowanceForPool(address)
  const approveUsdc = useApproveTokenForPool(USDC_ADDRESS)
  const borrow = useBorrow()
  const repay = useRepay()

  const isBorrow = mode === 'borrow'
  const parsed = parseTokenInput(amount, 6) // USDC native

  const navRaw = (navData.data as bigint | undefined) ?? 0n
  const usdcBalance = (usdcBal.data as bigint | undefined) ?? 0n
  const usdcAllowance = (usdcAllow.data as bigint | undefined) ?? 0n

  // collateralValueUsdc (6-dec) = collateral (18-dec HFS) * nav (30-dec) / 1e18 / 1e12
  const collateralValueUsdc =
    navRaw > 0n
      ? (position.collateral * navRaw) / 10n ** 18n / NORMALIZE_USDC
      : 0n

  const lltvBps = config.lltvBps
  const maxBorrow = (collateralValueUsdc * lltvBps) / 10000n
  const headroom = maxBorrow > position.debt ? maxBorrow - position.debt : 0n

  // Health ratio: (collateralValue * LLTV) / debt. >1 = healthy.
  const healthRatio =
    position.debt > 0n
      ? Number((maxBorrow * 1000n) / position.debt) / 1000
      : Infinity

  const action = isBorrow ? borrow : repay
  const isPending = action.isPending || action.isConfirming
  const needsApproval = !isBorrow && parsed > 0n && usdcAllowance < parsed
  const isApproving = approveUsdc.isPending || approveUsdc.isConfirming

  const handleSubmit = () => {
    if (isBorrow) borrow.send(parsed)
    else repay.send(parsed)
  }

  const inputMax = isBorrow ? headroom : position.debt
  const reserveCap = isBorrow && parsed > stats.usdcReserve

  return (
    <div className="card">
      <div className="flex items-center space-x-3 mb-6">
        <div className="p-2 bg-orange-50 dark:bg-orange-900/20 rounded-lg">
          {isBorrow ? (
            <TrendingDown className="h-6 w-6 text-orange-600 dark:text-orange-400" />
          ) : (
            <TrendingUp className="h-6 w-6 text-orange-600 dark:text-orange-400" />
          )}
        </div>
        <div>
          <h2 className="text-xl font-bold text-gray-900 dark:text-white">
            Borrow / Repay
          </h2>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            {formatPercent(bpsToPercent(Number(config.borrowRateBps)))} APR · LLTV{' '}
            {formatPercent(bpsToPercent(Number(lltvBps)))}
          </p>
        </div>
      </div>

      <div className="flex mb-4 border-b border-gray-200 dark:border-gray-700">
        <button
          onClick={() => setMode('borrow')}
          className={`px-4 py-2 text-sm font-medium ${
            isBorrow
              ? 'border-b-2 border-primary-600 text-primary-700 dark:text-primary-300'
              : 'text-gray-600 dark:text-gray-400'
          }`}
        >
          Borrow
        </button>
        <button
          onClick={() => setMode('repay')}
          className={`px-4 py-2 text-sm font-medium ${
            !isBorrow
              ? 'border-b-2 border-primary-600 text-primary-700 dark:text-primary-300'
              : 'text-gray-600 dark:text-gray-400'
          }`}
        >
          Repay
        </button>
      </div>

      <div className="space-y-4">
        <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-3 text-sm space-y-1">
          <div className="flex justify-between">
            <span className="text-gray-600 dark:text-gray-400">Collateral value</span>
            <span className="font-semibold text-gray-900 dark:text-white">
              {formatUSD(collateralValueUsdc, 6)}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-gray-600 dark:text-gray-400">Outstanding debt</span>
            <span className="font-semibold text-gray-900 dark:text-white">
              {formatUSD(position.debt, 6)}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-gray-600 dark:text-gray-400">Borrow headroom</span>
            <span className="font-semibold text-gray-900 dark:text-white">
              {formatUSD(headroom, 6)}
            </span>
          </div>
          <div className="flex justify-between items-center pt-2 border-t border-gray-200 dark:border-gray-700">
            <span className="text-gray-600 dark:text-gray-400 flex items-center">
              <Heart
                className={`h-4 w-4 mr-1 ${
                  position.healthy ? 'text-green-500' : 'text-red-500'
                }`}
              />
              Health
            </span>
            <span
              className={`font-semibold ${
                position.healthy ? 'text-green-600' : 'text-red-600'
              }`}
            >
              {position.debt === 0n
                ? 'No debt'
                : healthRatio === Infinity
                ? '∞'
                : healthRatio.toFixed(2)}
            </span>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Amount (USDC)
          </label>
          <input
            type="text"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00"
            className="input-field"
          />
          <div className="mt-1 flex justify-between text-sm">
            <p className="text-gray-500 dark:text-gray-400">
              {isBorrow
                ? `Max borrow: ${formatToken(inputMax, 6)} USDC`
                : `Wallet: ${formatToken(usdcBalance, 6)} USDC · Debt: ${formatToken(
                    position.debt,
                    6,
                  )}`}
            </p>
            <button
              onClick={() => setAmount(formatToken(inputMax, 6, 6))}
              className="text-primary-600 hover:text-primary-700 dark:text-primary-400"
            >
              Max
            </button>
          </div>
        </div>

        {isBorrow && reserveCap && (
          <div className="text-sm text-yellow-700 dark:text-yellow-400 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded p-3">
            Pool only has {formatToken(stats.usdcReserve, 6)} USDC available right
            now. Borrow will revert.
          </div>
        )}

        {needsApproval ? (
          <button
            onClick={() => approveUsdc.approve(parsed)}
            disabled={isApproving || !amount}
            className="btn-primary w-full"
          >
            {isApproving ? (
              <>
                <Loader2 className="h-5 w-5 animate-spin mr-2" />
                Approving USDC...
              </>
            ) : (
              'Approve USDC'
            )}
          </button>
        ) : (
          <button
            onClick={handleSubmit}
            disabled={isPending || !amount}
            className="btn-primary w-full"
          >
            {isPending ? (
              <>
                <Loader2 className="h-5 w-5 animate-spin mr-2" />
                {isBorrow ? 'Borrowing...' : 'Repaying...'}
              </>
            ) : isBorrow ? (
              'Borrow USDC'
            ) : (
              'Repay USDC'
            )}
          </button>
        )}

        {action.isSuccess && (
          <div className="flex items-center space-x-2 text-green-600 dark:text-green-400 text-sm">
            <CheckCircle className="h-5 w-5" />
            <span>{isBorrow ? 'Borrowed.' : 'Repaid.'}</span>
          </div>
        )}

        {action.error && (
          <div className="flex items-center space-x-2 text-red-600 dark:text-red-400 text-sm">
            <XCircle className="h-5 w-5" />
            <span>{action.error.message}</span>
          </div>
        )}
      </div>
    </div>
  )
}
