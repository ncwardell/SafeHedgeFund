'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import {
  usePoolStats,
  useLendingConfig,
  useUsdcBalance,
  useHfsBalance,
  useUsdcAllowanceForPool,
  useHfsAllowanceForPool,
  useApproveTokenForPool,
  useSwapUsdcForHfs,
  useSwapHfsForUsdc,
} from '@/hooks/usePool'
import { useNavPerShare } from '@/hooks/useVault'
import { USDC_ADDRESS, VAULT_ADDRESS } from '@/lib/contracts'
import {
  formatToken,
  parseTokenInput,
  calculateSlippage,
} from '@/lib/utils'
import { ArrowDownUp, Loader2, CheckCircle, XCircle } from 'lucide-react'

type Direction = 'usdc-to-hfs' | 'hfs-to-usdc'

const NORMALIZE_USDC = 10n ** 12n // 1e12

export function SwapForm() {
  const { address } = useAccount()
  const [direction, setDirection] = useState<Direction>('usdc-to-hfs')
  const [amount, setAmount] = useState('')
  const [slippage, setSlippage] = useState('0.5')

  const stats = usePoolStats()
  const config = useLendingConfig()
  const navData = useNavPerShare()
  const usdcBal = useUsdcBalance(address)
  const hfsBal = useHfsBalance(address)
  const usdcAllow = useUsdcAllowanceForPool(address)
  const hfsAllow = useHfsAllowanceForPool(address)

  const approveUsdc = useApproveTokenForPool(USDC_ADDRESS)
  const approveHfs = useApproveTokenForPool(VAULT_ADDRESS)

  const swapInToHfs = useSwapUsdcForHfs()
  const swapInToUsdc = useSwapHfsForUsdc()

  const isUsdcIn = direction === 'usdc-to-hfs'
  const inDecimals = isUsdcIn ? 6 : 18
  const outDecimals = isUsdcIn ? 18 : 6
  const inSymbol = isUsdcIn ? 'USDC' : 'HFS'
  const outSymbol = isUsdcIn ? 'HFS' : 'USDC'
  const balance = isUsdcIn
    ? ((usdcBal.data as bigint | undefined) ?? 0n)
    : ((hfsBal.data as bigint | undefined) ?? 0n)
  const allowance = isUsdcIn
    ? ((usdcAllow.data as bigint | undefined) ?? 0n)
    : ((hfsAllow.data as bigint | undefined) ?? 0n)

  const parsedIn = parseTokenInput(amount, inDecimals)

  // xy=k preview using the same math the contract uses, then deduct fee.
  const usdcReserve = stats.usdcReserve
  const hfsReserve = stats.hfsReserve
  const k = usdcReserve * hfsReserve
  const feeBps = config.swapFeeBps

  let estimatedOut = 0n
  if (parsedIn > 0n && usdcReserve > 0n && hfsReserve > 0n) {
    if (isUsdcIn) {
      const newUsdc = usdcReserve + parsedIn
      const gross = hfsReserve - k / newUsdc
      estimatedOut = gross - (gross * feeBps) / 10000n
    } else {
      const newHfs = hfsReserve + parsedIn
      const gross = usdcReserve - k / newHfs
      estimatedOut = gross - (gross * feeBps) / 10000n
    }
  }

  // Effective rate (out per in), and a NAV-fair benchmark for slippage display.
  const navRaw = (navData.data as bigint | undefined) ?? 0n
  let navFairOut = 0n
  if (parsedIn > 0n && navRaw > 0n) {
    if (isUsdcIn) {
      // USDC native -> HFS: hfs = usdc * 1e12 * 1e18 / nav
      navFairOut = (parsedIn * NORMALIZE_USDC * 10n ** 18n) / navRaw
    } else {
      // HFS -> USDC native: usdc = hfs * nav / 1e18 / 1e12
      navFairOut = (parsedIn * navRaw) / 10n ** 18n / NORMALIZE_USDC
    }
  }

  const needsApproval = parsedIn > 0n && allowance < parsedIn

  const slippageBps = Math.round(parseFloat(slippage || '0') * 100)
  const minOut = calculateSlippage(estimatedOut, slippageBps)

  const handleApprove = () => {
    if (isUsdcIn) approveUsdc.approve(parsedIn)
    else approveHfs.approve(parsedIn)
  }

  const handleSwap = () => {
    if (isUsdcIn) swapInToHfs.send(parsedIn, minOut)
    else swapInToUsdc.send(parsedIn, minOut)
  }

  const swap = isUsdcIn ? swapInToHfs : swapInToUsdc
  const approval = isUsdcIn ? approveUsdc : approveHfs
  const isApproving = approval.isPending || approval.isConfirming
  const isSwapping = swap.isPending || swap.isConfirming

  return (
    <div className="card">
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center space-x-3">
          <div className="p-2 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
            <ArrowDownUp className="h-6 w-6 text-blue-600 dark:text-blue-400" />
          </div>
          <div>
            <h2 className="text-xl font-bold text-gray-900 dark:text-white">Swap</h2>
            <p className="text-sm text-gray-600 dark:text-gray-400">
              xy=k AMM against the pool
            </p>
          </div>
        </div>
        <button
          onClick={() =>
            setDirection(isUsdcIn ? 'hfs-to-usdc' : 'usdc-to-hfs')
          }
          className="text-sm px-3 py-1 rounded border border-gray-300 dark:border-gray-700 hover:bg-gray-100 dark:hover:bg-gray-800"
        >
          Flip ({inSymbol} → {outSymbol})
        </button>
      </div>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            From ({inSymbol})
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
              Balance: {formatToken(balance, inDecimals)} {inSymbol}
            </p>
            <button
              onClick={() => setAmount(formatToken(balance, inDecimals, inDecimals))}
              className="text-primary-600 hover:text-primary-700 dark:text-primary-400"
            >
              Max
            </button>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Slippage tolerance (%)
          </label>
          <input
            type="text"
            value={slippage}
            onChange={(e) => setSlippage(e.target.value)}
            placeholder="0.5"
            className="input-field"
          />
        </div>

        {parsedIn > 0n && (
          <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-4 space-y-1">
            <div className="flex justify-between text-sm">
              <span className="text-gray-600 dark:text-gray-400">Estimated out</span>
              <span className="font-semibold text-gray-900 dark:text-white">
                {formatToken(estimatedOut, outDecimals)} {outSymbol}
              </span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-gray-600 dark:text-gray-400">NAV-fair out</span>
              <span className="text-gray-700 dark:text-gray-300">
                {formatToken(navFairOut, outDecimals)} {outSymbol}
              </span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-gray-600 dark:text-gray-400">Min received</span>
              <span className="text-gray-700 dark:text-gray-300">
                {formatToken(minOut, outDecimals)} {outSymbol}
              </span>
            </div>
          </div>
        )}

        {needsApproval ? (
          <button
            onClick={handleApprove}
            disabled={isApproving || !amount}
            className="btn-primary w-full"
          >
            {isApproving ? (
              <>
                <Loader2 className="h-5 w-5 animate-spin mr-2" />
                Approving {inSymbol}...
              </>
            ) : (
              `Approve ${inSymbol}`
            )}
          </button>
        ) : (
          <button
            onClick={handleSwap}
            disabled={isSwapping || !amount || estimatedOut === 0n}
            className="btn-primary w-full"
          >
            {isSwapping ? (
              <>
                <Loader2 className="h-5 w-5 animate-spin mr-2" />
                Swapping...
              </>
            ) : (
              `Swap ${inSymbol} → ${outSymbol}`
            )}
          </button>
        )}

        {swap.isSuccess && (
          <div className="flex items-center space-x-2 text-green-600 dark:text-green-400 text-sm">
            <CheckCircle className="h-5 w-5" />
            <span>Swap complete.</span>
          </div>
        )}

        {swap.error && (
          <div className="flex items-center space-x-2 text-red-600 dark:text-red-400 text-sm">
            <XCircle className="h-5 w-5" />
            <span>{swap.error.message}</span>
          </div>
        )}
      </div>
    </div>
  )
}
