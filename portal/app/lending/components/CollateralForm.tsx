'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import {
  useDepositCollateral,
  useWithdrawCollateral,
  useHfsBalance,
  useHfsAllowanceForPool,
  useApproveTokenForPool,
  useUserLendingPosition,
} from '@/hooks/usePool'
import { VAULT_ADDRESS } from '@/lib/contracts'
import { formatToken, parseTokenInput } from '@/lib/utils'
import { Lock, Unlock, Loader2, CheckCircle, XCircle } from 'lucide-react'

export function CollateralForm() {
  const { address } = useAccount()
  const [mode, setMode] = useState<'deposit' | 'withdraw'>('deposit')
  const [amount, setAmount] = useState('')

  const hfsBal = useHfsBalance(address)
  const hfsAllow = useHfsAllowanceForPool(address)
  const position = useUserLendingPosition(address)

  const approveHfs = useApproveTokenForPool(VAULT_ADDRESS)
  const depositColl = useDepositCollateral()
  const withdrawColl = useWithdrawCollateral()

  const parsed = parseTokenInput(amount, 18)
  const balance = (hfsBal.data as bigint | undefined) ?? 0n
  const allowance = (hfsAllow.data as bigint | undefined) ?? 0n
  const collateral = position.collateral

  const isDeposit = mode === 'deposit'
  const max = isDeposit ? balance : collateral
  const needsApproval = isDeposit && parsed > 0n && allowance < parsed

  const action = isDeposit ? depositColl : withdrawColl
  const isPending = action.isPending || action.isConfirming
  const isApproving = approveHfs.isPending || approveHfs.isConfirming

  const handleSubmit = () => {
    if (isDeposit) depositColl.send(parsed)
    else withdrawColl.send(parsed)
  }

  return (
    <div className="card">
      <div className="flex items-center space-x-3 mb-6">
        <div className="p-2 bg-purple-50 dark:bg-purple-900/20 rounded-lg">
          {isDeposit ? (
            <Lock className="h-6 w-6 text-purple-600 dark:text-purple-400" />
          ) : (
            <Unlock className="h-6 w-6 text-purple-600 dark:text-purple-400" />
          )}
        </div>
        <div>
          <h2 className="text-xl font-bold text-gray-900 dark:text-white">
            Collateral (HFS)
          </h2>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Lock HFS to enable borrowing
          </p>
        </div>
      </div>

      <div className="flex mb-4 border-b border-gray-200 dark:border-gray-700">
        <button
          onClick={() => setMode('deposit')}
          className={`px-4 py-2 text-sm font-medium ${
            isDeposit
              ? 'border-b-2 border-primary-600 text-primary-700 dark:text-primary-300'
              : 'text-gray-600 dark:text-gray-400'
          }`}
        >
          Deposit
        </button>
        <button
          onClick={() => setMode('withdraw')}
          className={`px-4 py-2 text-sm font-medium ${
            !isDeposit
              ? 'border-b-2 border-primary-600 text-primary-700 dark:text-primary-300'
              : 'text-gray-600 dark:text-gray-400'
          }`}
        >
          Withdraw
        </button>
      </div>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Amount (HFS)
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
              {isDeposit ? 'Wallet' : 'Collateral'}:{' '}
              {formatToken(max, 18)} HFS
            </p>
            <button
              onClick={() => setAmount(formatToken(max, 18, 18))}
              className="text-primary-600 hover:text-primary-700 dark:text-primary-400"
            >
              Max
            </button>
          </div>
        </div>

        <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-3 text-sm space-y-1">
          <div className="flex justify-between">
            <span className="text-gray-600 dark:text-gray-400">Currently locked</span>
            <span className="font-semibold text-gray-900 dark:text-white">
              {formatToken(collateral, 18)} HFS
            </span>
          </div>
          <p className="text-xs text-gray-500 dark:text-gray-400">
            Withdrawals revert if your remaining position would become unhealthy.
          </p>
        </div>

        {needsApproval ? (
          <button
            onClick={() => approveHfs.approve(parsed)}
            disabled={isApproving || !amount}
            className="btn-primary w-full"
          >
            {isApproving ? (
              <>
                <Loader2 className="h-5 w-5 animate-spin mr-2" />
                Approving HFS...
              </>
            ) : (
              'Approve HFS'
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
                {isDeposit ? 'Depositing...' : 'Withdrawing...'}
              </>
            ) : isDeposit ? (
              'Deposit collateral'
            ) : (
              'Withdraw collateral'
            )}
          </button>
        )}

        {action.isSuccess && (
          <div className="flex items-center space-x-2 text-green-600 dark:text-green-400 text-sm">
            <CheckCircle className="h-5 w-5" />
            <span>{isDeposit ? 'Collateral deposited.' : 'Collateral withdrawn.'}</span>
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
