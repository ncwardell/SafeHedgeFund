'use client'

import { useState } from 'react'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { VAULT_ADDRESS, USDC_ADDRESS, ERC20_ABI } from '@/lib/contracts'
import { useDeposit } from '@/hooks/useVault'
import { parseTokenInput, calculateSlippage, formatToken } from '@/lib/utils'
import { TrendingUp, Loader2, CheckCircle, XCircle } from 'lucide-react'

export function DepositForm() {
  const { address } = useAccount()
  const [amount, setAmount] = useState('')
  const [slippage, setSlippage] = useState('0.5')

  // Get token info
  const { data: tokenBalance } = useReadContract({
    address: USDC_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
  })

  const { data: tokenSymbol } = useReadContract({
    address: USDC_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'symbol',
  })

  const { data: decimals } = useReadContract({
    address: USDC_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'decimals',
  })

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: USDC_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, VAULT_ADDRESS] : undefined,
  })

  // Approval
  const {
    writeContract: approve,
    data: approveHash,
    isPending: isApprovePending,
  } = useWriteContract()

  const { isLoading: isApproveConfirming, isSuccess: isApproveSuccess } =
    useWaitForTransactionReceipt({ hash: approveHash })

  // Deposit
  const deposit = useDeposit()

  const handleApprove = async () => {
    const parsedAmount = parseTokenInput(amount, decimals ?? 18)
    approve({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [VAULT_ADDRESS, parsedAmount],
    })
  }

  const handleDeposit = async () => {
    const parsedAmount = parseTokenInput(amount, decimals ?? 18)
    const minShares = calculateSlippage(parsedAmount, parseFloat(slippage) * 100)
    deposit.deposit(parsedAmount, minShares)
  }

  const parsedAmount = parseTokenInput(amount, decimals ?? 18)
  const needsApproval = allowance !== undefined && parsedAmount > allowance

  // Refetch allowance after approval
  if (isApproveSuccess && needsApproval) {
    refetchAllowance()
  }

  return (
    <div className="card">
      <div className="flex items-center space-x-3 mb-6">
        <div className="p-2 bg-green-50 dark:bg-green-900/20 rounded-lg">
          <TrendingUp className="h-6 w-6 text-green-600 dark:text-green-400" />
        </div>
        <div>
          <h2 className="text-xl font-bold text-gray-900 dark:text-white">
            Deposit
          </h2>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Add funds to the vault
          </p>
        </div>
      </div>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Amount ({tokenSymbol ?? 'Tokens'})
          </label>
          <input
            type="text"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00"
            className="input-field"
          />
          <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Balance: {formatToken(tokenBalance, decimals ?? 18)} {tokenSymbol}
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Slippage Tolerance (%)
          </label>
          <input
            type="text"
            value={slippage}
            onChange={(e) => setSlippage(e.target.value)}
            placeholder="0.5"
            className="input-field"
          />
        </div>

        {needsApproval ? (
          <button
            onClick={handleApprove}
            disabled={isApprovePending || isApproveConfirming || !amount}
            className="btn-primary w-full"
          >
            {isApprovePending || isApproveConfirming ? (
              <>
                <Loader2 className="h-5 w-5 animate-spin mr-2" />
                Approving...
              </>
            ) : (
              'Approve'
            )}
          </button>
        ) : (
          <button
            onClick={handleDeposit}
            disabled={deposit.isPending || deposit.isConfirming || !amount}
            className="btn-primary w-full"
          >
            {deposit.isPending || deposit.isConfirming ? (
              <>
                <Loader2 className="h-5 w-5 animate-spin mr-2" />
                Depositing...
              </>
            ) : (
              'Deposit'
            )}
          </button>
        )}

        {deposit.isSuccess && (
          <div className="flex items-center space-x-2 text-green-600 dark:text-green-400 text-sm">
            <CheckCircle className="h-5 w-5" />
            <span>Deposit queued successfully!</span>
          </div>
        )}

        {deposit.error && (
          <div className="flex items-center space-x-2 text-red-600 dark:text-red-400 text-sm">
            <XCircle className="h-5 w-5" />
            <span>Error: {deposit.error.message}</span>
          </div>
        )}
      </div>
    </div>
  )
}
