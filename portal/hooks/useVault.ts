import { useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { VAULT_ADDRESS, VAULT_ABI, ROLES } from '@/lib/contracts'
import { useAccount } from 'wagmi'

// View hooks
export function useNavPerShare() {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'navPerShare',
  })
}

export function useTotalAum() {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'getTotalAum',
  })
}

export function useUserPosition(address?: `0x${string}`) {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'getPosition',
    args: address ? [address] : undefined,
    query: {
      enabled: !!address,
    },
  })
}

export function useAccruedFees() {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'accruedFees',
  })
}

export function useHWMStatus() {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'getHWMStatus',
  })
}

export function useQueueLengths() {
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'queueLengths',
  })
}

export function useVaultStatus() {
  const paused = useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'paused',
  })

  const emergencyMode = useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'isEmergencyActive',
  })

  return {
    paused: paused.data,
    emergencyMode: emergencyMode.data,
    isLoading: paused.isLoading || emergencyMode.isLoading,
  }
}

// Role checking hooks
export function useHasRole(role: keyof typeof ROLES, address?: `0x${string}`) {
  const roleHash = ROLES[role]
  return useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'hasRole',
    args: address ? [roleHash as `0x${string}`, address] : undefined,
    query: {
      enabled: !!address,
    },
  })
}

export function useUserRoles() {
  const { address } = useAccount()

  const isAdmin = useHasRole('ADMIN', address)
  const isAumUpdater = useHasRole('AUM_UPDATER', address)
  const isProcessor = useHasRole('PROCESSOR', address)
  const isGuardian = useHasRole('GUARDIAN', address)

  return {
    isAdmin: isAdmin.data ?? false,
    isAumUpdater: isAumUpdater.data ?? false,
    isProcessor: isProcessor.data ?? false,
    isGuardian: isGuardian.data ?? false,
    isLoading: isAdmin.isLoading || isAumUpdater.isLoading || isProcessor.isLoading || isGuardian.isLoading,
  }
}

// Write hooks
export function useDeposit() {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const deposit = (amount: bigint, minShares: bigint) => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'deposit',
      args: [amount, minShares],
    })
  }

  return {
    deposit,
    isPending,
    isConfirming,
    isSuccess,
    error,
    hash,
  }
}

export function useRedeem() {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const redeem = (shares: bigint, minAmountOut: bigint) => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'redeem',
      args: [shares, minAmountOut],
    })
  }

  return {
    redeem,
    isPending,
    isConfirming,
    isSuccess,
    error,
    hash,
  }
}

export function useUpdateAum() {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const updateAum = (newAum: bigint) => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'updateAum',
      args: [newAum],
    })
  }

  return {
    updateAum,
    isPending,
    isConfirming,
    isSuccess,
    error,
    hash,
  }
}

export function useProcessQueues() {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const processDeposits = (maxToProcess: bigint) => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'processDepositQueue',
      args: [maxToProcess],
    })
  }

  const processRedemptions = (maxToProcess: bigint) => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'processRedemptionQueue',
      args: [maxToProcess],
    })
  }

  return {
    processDeposits,
    processRedemptions,
    isPending,
    isConfirming,
    isSuccess,
    error,
    hash,
  }
}

export function usePayoutFees() {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const payoutFees = () => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'payoutAccruedFees',
    })
  }

  return {
    payoutFees,
    isPending,
    isConfirming,
    isSuccess,
    error,
    hash,
  }
}

export function useEmergencyControls() {
  const { writeContract, data: hash, isPending, error } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const pause = () => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'pause',
    })
  }

  const unpause = () => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'unpause',
    })
  }

  const triggerEmergency = () => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'triggerEmergency',
    })
  }

  const exitEmergency = () => {
    writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: 'exitEmergency',
    })
  }

  return {
    pause,
    unpause,
    triggerEmergency,
    exitEmergency,
    isPending,
    isConfirming,
    isSuccess,
    error,
    hash,
  }
}
