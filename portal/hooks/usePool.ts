import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi'
import {
  POOL_ADDRESS,
  USDC_ADDRESS,
  VAULT_ADDRESS,
  SHARED_POOL_ABI,
  ERC20_ABI,
  VAULT_ABI,
} from '@/lib/contracts'

// ── Views ─────────────────────────────────────────────────────────────────

export function usePoolStats() {
  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      { address: POOL_ADDRESS, abi: SHARED_POOL_ABI, functionName: 'usdcReserve' },
      { address: POOL_ADDRESS, abi: SHARED_POOL_ABI, functionName: 'totalBorrowed' },
      { address: POOL_ADDRESS, abi: SHARED_POOL_ABI, functionName: 'hfsReserve' },
      { address: POOL_ADDRESS, abi: SHARED_POOL_ABI, functionName: 'activeBorrowerCount' },
    ],
  })

  return {
    usdcReserve: (data?.[0]?.result as bigint | undefined) ?? 0n,
    totalBorrowed: (data?.[1]?.result as bigint | undefined) ?? 0n,
    hfsReserve: (data?.[2]?.result as bigint | undefined) ?? 0n,
    activeBorrowers: (data?.[3]?.result as bigint | undefined) ?? 0n,
    isLoading,
    refetch,
  }
}

export function useLendingConfig() {
  const { data, isLoading } = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'swapFeeBps' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'lltvBps' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'borrowRateBps' },
    ],
  })

  return {
    swapFeeBps: (data?.[0]?.result as bigint | undefined) ?? 0n,
    lltvBps: (data?.[1]?.result as bigint | undefined) ?? 0n,
    borrowRateBps: (data?.[2]?.result as bigint | undefined) ?? 0n,
    isLoading,
  }
}

export function useUserLendingPosition(address?: `0x${string}`) {
  const enabled = !!address
  const { data, isLoading, refetch } = useReadContracts({
    contracts: address
      ? [
          {
            address: POOL_ADDRESS,
            abi: SHARED_POOL_ABI,
            functionName: 'collateralOf',
            args: [address],
          },
          {
            address: POOL_ADDRESS,
            abi: SHARED_POOL_ABI,
            functionName: 'borrowOf',
            args: [address],
          },
          {
            address: POOL_ADDRESS,
            abi: SHARED_POOL_ABI,
            functionName: 'isHealthy',
            args: [address],
          },
        ]
      : [],
    query: { enabled },
  })

  return {
    collateral: (data?.[0]?.result as bigint | undefined) ?? 0n,
    debt: (data?.[1]?.result as bigint | undefined) ?? 0n,
    healthy: (data?.[2]?.result as boolean | undefined) ?? true,
    isLoading,
    refetch,
  }
}

// HFS balance (the share token = the vault contract itself)
export function useHfsBalance(address?: `0x${string}`) {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })
}

// USDC balance + allowances against the pool
export function useUsdcBalance(address?: `0x${string}`) {
  return useReadContract({
    address: USDC_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })
}

export function useUsdcAllowanceForPool(address?: `0x${string}`) {
  return useReadContract({
    address: USDC_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, POOL_ADDRESS] : undefined,
    query: { enabled: !!address },
  })
}

export function useHfsAllowanceForPool(address?: `0x${string}`) {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, POOL_ADDRESS] : undefined,
    query: { enabled: !!address },
  })
}

// ── Writes ────────────────────────────────────────────────────────────────

function makePoolWrite(functionName: string) {
  return function usePoolWrite() {
    const { writeContract, data: hash, isPending, error, reset } = useWriteContract()
    const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

    const send = (...args: unknown[]) => {
      writeContract({
        address: POOL_ADDRESS,
        abi: SHARED_POOL_ABI,
        functionName,
        args,
      } as Parameters<typeof writeContract>[0])
    }

    return { send, isPending, isConfirming, isSuccess, error, hash, reset }
  }
}

export const useSwapUsdcForHfs = makePoolWrite('swapUsdcForHfs')
export const useSwapHfsForUsdc = makePoolWrite('swapHfsForUsdc')
export const useDepositCollateral = makePoolWrite('depositCollateral')
export const useWithdrawCollateral = makePoolWrite('withdrawCollateral')
export const useBorrow = makePoolWrite('borrow')
export const useRepay = makePoolWrite('repay')

// Approval helpers for USDC and HFS toward the pool.
export function useApproveTokenForPool(token: `0x${string}`) {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const approve = (amount: bigint) => {
    writeContract({
      address: token,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [POOL_ADDRESS, amount],
    })
  }

  return { approve, isPending, isConfirming, isSuccess, error, hash }
}

// MockUSDC permissionless faucet (testnet only).
export function useMintUsdc() {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const mint = (to: `0x${string}`, amount: bigint) => {
    writeContract({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'mint',
      args: [to, amount],
    })
  }

  return { mint, isPending, isConfirming, isSuccess, error, hash }
}

// Convenience wrapper: returns the connected address's full lending picture
// (balances, allowances, position) in one shape.
export function useConnectedLendingState() {
  const { address } = useAccount()
  const usdcBal = useUsdcBalance(address)
  const hfsBal = useHfsBalance(address)
  const usdcAllow = useUsdcAllowanceForPool(address)
  const hfsAllow = useHfsAllowanceForPool(address)
  const position = useUserLendingPosition(address)

  return {
    address,
    usdcBalance: (usdcBal.data as bigint | undefined) ?? 0n,
    hfsBalance: (hfsBal.data as bigint | undefined) ?? 0n,
    usdcAllowance: (usdcAllow.data as bigint | undefined) ?? 0n,
    hfsAllowance: (hfsAllow.data as bigint | undefined) ?? 0n,
    collateral: position.collateral,
    debt: position.debt,
    healthy: position.healthy,
    refetch: () => {
      usdcBal.refetch()
      hfsBal.refetch()
      usdcAllow.refetch()
      hfsAllow.refetch()
      position.refetch()
    },
  }
}
