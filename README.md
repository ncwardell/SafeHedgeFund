# SafeHedgeFund

A production-ready, modular hedge fund vault smart contract system with Gnosis Safe integration for institutional-grade asset management.

## Overview

SafeHedgeFund is a sophisticated DeFi protocol that enables the creation and management of tokenized hedge fund vaults. The system leverages Gnosis Safe's multi-signature capabilities for secure treasury management while providing transparent, on-chain tracking of fund performance and investor positions.

## Key Features

### Core Functionality
- **ERC20 Share Tokens**: Investors receive fungible shares representing their proportional ownership in the fund
- **Multi-Asset Support**: Compatible with any ERC20 base token (USDC, USDT, DAI, etc.)
- **Gnosis Safe Integration**: Secure multi-signature treasury management with module-based execution
- **Queue-Based Processing**: Deposit and redemption queues for efficient batch processing and gas optimization

### Fee Management
- **Management Fees**: Configurable annual management fees on AUM
- **Performance Fees**: High-water mark based performance fees with drawdown protection
- **Entrance/Exit Fees**: Customizable deposit and redemption fees
- **Fee Accrual**: Automatic fee calculation and tracking with transparent payout mechanisms

### Risk Management
- **Pause Mechanism**: Emergency pause functionality to halt operations
- **Emergency Mode**: Special withdrawal mode triggered during crisis scenarios
- **Configurable Parameters**: Time-locked configuration changes via proposal system
- **Role-Based Access Control**: Granular permissions for different operational roles

### Operational Features
- **AUM Tracking**: Off-chain AUM updates with staleness checks
- **Auto-Processing**: Optional automatic processing of deposits and redemptions
- **Batch Operations**: Efficient processing of multiple queue items
- **Liquidity Management**: Target liquidity ratio for optimal capital efficiency

## Architecture

### Contract Structure

```
contracts/
├── SafeHedgeFundVault.sol    # Main vault contract (ERC20 shares, core logic)
├── AUMManager.sol             # Assets Under Management calculations and NAV tracking
├── ConfigManager.sol          # Time-locked configuration proposal system
├── EmergencyManager.sol       # Emergency pause and withdrawal mechanisms
├── FeeManager.sol             # Comprehensive fee accrual and payment logic
└── QueueManager.sol           # Deposit and redemption queue management
```

### Library Pattern

The codebase uses Solidity libraries with storage structs for modular, reusable logic:
- Reduces main contract size and complexity
- Enables easier auditing and testing of individual components
- Provides clear separation of concerns

### Key Components

#### SafeHedgeFundVault
The main entry point that inherits from OpenZeppelin's ERC20, ReentrancyGuard, Pausable, and AccessControl. Coordinates all operations and maintains vault state.

#### AUMManager
Handles Assets Under Management tracking, NAV (Net Asset Value) calculations, share/payout estimations, and high-water mark logic for performance fees.

#### FeeManager
Manages all fee types (management, performance, entrance, exit) with automatic accrual, high-water mark tracking, and pro-rata distribution.

#### QueueManager
Implements deposit and redemption queues with batch processing, cancellation support, and user-specific tracking.

#### ConfigManager
Provides a time-locked proposal system for configuration changes, ensuring governance transparency and security.

#### EmergencyManager
Handles emergency scenarios with pausable operations, emergency mode triggering, and pro-rata emergency withdrawals.

## Security

### Roles

The system implements four distinct roles:

- **DEFAULT_ADMIN_ROLE**: Master admin role from AccessControl
- **ADMIN_ROLE**: Main administrative functions (config, fees, pause)
- **AUM_UPDATER_ROLE**: Authorized to update Assets Under Management
- **PROCESSOR_ROLE**: Can process deposit/redemption queues
- **GUARDIAN_ROLE**: Emergency functions and protective actions

### Security Features

- **ReentrancyGuard**: Protection against reentrancy attacks on critical functions
- **SafeERC20**: Safe token transfer operations
- **Access Control**: Role-based permissions for sensitive operations
- **Time-locked Changes**: Configuration proposals require a delay before execution
- **Emergency Mechanisms**: Pause and emergency withdrawal capabilities
- **Input Validation**: Comprehensive checks on user inputs and state transitions

### Audit Status

This codebase has undergone a comprehensive security audit. Critical findings have been addressed in the current implementation:

- Fixed infinite recursion in burn function (CRITICAL-1)
- Corrected emergency mode modifier logic (CRITICAL-2)
- Added proper error definitions
- Fixed decimal handling with validation
- Improved reentrancy protection
- Enhanced Safe integration validation
- Added AUM staleness checks in queue processing

**See [docs/AUDIT_REPORT.md](docs/AUDIT_REPORT.md) for the complete audit report.**

## Installation

### Prerequisites

- Solidity ^0.8.24
- Node.js and npm (for development tools)
- Hardhat or Foundry (recommended)
- OpenZeppelin Contracts v5.x

### Setup

```bash
# Clone the repository
git clone https://github.com/ncwardell/SafeHedgeFund.git
cd SafeHedgeFund

# Install dependencies
npm install
```

## Usage

### Deployment

```solidity
// Deploy with constructor parameters
SafeHedgeFundVault vault = new SafeHedgeFundVault(
    baseTokenAddress,     // ERC20 token address (e.g., USDC)
    safeWalletAddress,    // Gnosis Safe address
    feeRecipientAddress,  // Fee recipient address
    rescueTreasuryAddress,// Emergency rescue address
    minDeposit,          // Minimum deposit amount
    minRedemption        // Minimum redemption amount
);

// Grant roles
vault.grantRole(AUM_UPDATER_ROLE, aumUpdaterAddress);
vault.grantRole(PROCESSOR_ROLE, processorAddress);
vault.grantRole(GUARDIAN_ROLE, guardianAddress);
```

### Investor Operations

#### Depositing

```solidity
// Approve tokens
baseToken.approve(address(vault), amount);

// Deposit with slippage protection
vault.deposit(amount, minSharesExpected);
```

#### Redeeming

```solidity
// Redeem shares for base tokens
vault.redeem(shares, minAmountOut);
```

#### Checking Position

```solidity
// Get user position details
(uint256 shares, uint256 value, uint256 pendingDep, uint256 pendingRed)
    = vault.getPosition(userAddress);
```

### Fund Manager Operations

#### Updating AUM

```solidity
// Update Assets Under Management
vault.updateAum(newAumValue);
```

#### Processing Queues

```solidity
// Process deposit queue
vault.processDepositQueue(maxItemsToProcess);

// Process redemption queue
vault.processRedemptionQueue(maxItemsToProcess);
```

#### Managing Fees

```solidity
// Payout accrued fees
vault.payoutAccruedFees();

// Check accrued fees
(uint256 mgmt, uint256 perf, uint256 entrance, uint256 exit, uint256 total, uint256 totalNative)
    = vault.accruedFees();
```

### Configuration Changes

```solidity
// Propose configuration change
vault.proposeConfigChange("mgmt", 200); // 2% management fee

// Wait for timelock period...

// Execute proposal
vault.executeConfigProposal("mgmt", 200);
```

## Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `managementFeeBps` | Annual management fee (basis points) | 0 |
| `performanceFeeBps` | Performance fee on profits (basis points) | 0 |
| `entranceFeeBps` | Fee on deposits (basis points) | 0 |
| `exitFeeBps` | Fee on redemptions (basis points) | 0 |
| `targetLiquidityBps` | Target liquidity ratio (basis points) | 500 (5%) |
| `minDeposit` | Minimum deposit amount | Constructor param |
| `minRedemption` | Minimum redemption amount | Constructor param |
| `maxAumAge` | Maximum AUM staleness | 3 days |
| `maxBatchSize` | Maximum queue batch processing size | 50 |
| `hwmDrawdownPct` | High-water mark drawdown threshold | 6000 (60%) |
| `hwmRecoveryPct` | High-water mark recovery threshold | 500 (5%) |
| `hwmRecoveryPeriod` | High-water mark recovery period | 90 days |

## Development

### Project Structure

```
SafeHedgeFund/
├── contracts/              # Solidity smart contracts
│   ├── SafeHedgeFundVault.sol
│   ├── AUMManager.sol
│   ├── ConfigManager.sol
│   ├── EmergencyManager.sol
│   ├── FeeManager.sol
│   └── QueueManager.sol
├── docs/                   # Documentation
│   └── AUDIT_REPORT.md    # Security audit report
├── test/                   # Test files (to be added)
├── scripts/                # Deployment scripts (to be added)
└── README.md              # This file
```

### Testing

```bash
# Run tests
npm test

# Run coverage
npm run coverage

# Run gas report
npm run gas-report
```

### Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## Known Issues and Limitations

As documented in the audit report, please be aware of:

1. **AUM Update Validation**: Issue #13 (Missing upper bound input validation) is acknowledged but not fixed by design choice
2. **Token Decimal Support**: Currently tested with 6-decimal tokens (USDC/USDT). Extensive testing required for other decimals
3. **Queue Size Limits**: Large queue sizes may encounter gas limits during cancellation operations

See [docs/AUDIT_REPORT.md](docs/AUDIT_REPORT.md) for complete details.

## License

MIT License - see LICENSE file for details

## Disclaimer

This software is provided "as is" without warranty of any kind. Use at your own risk. This code has been audited but no audit can guarantee complete security. Users should:

- Conduct their own security review
- Test thoroughly on testnets before mainnet deployment
- Consider additional audits for production use
- Implement proper operational security practices
- Understand the risks of smart contract interactions

## Contact

For questions, issues, or contributions:
- GitHub Issues: https://github.com/ncwardell/SafeHedgeFund/issues
- Project Repository: https://github.com/ncwardell/SafeHedgeFund

## Acknowledgments

Built with:
- OpenZeppelin Contracts
- Gnosis Safe
- Solidity
- Hardhat/Foundry

Special thanks to the audit team and contributors who helped identify and resolve security issues.
