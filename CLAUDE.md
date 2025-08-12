# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Solidity smart contract project called "Callisto" that implements a DeFi protocol with vault functionality, PSM (Peg Stability Module), and various supporting contracts. The project is built on the Olympus DAO Kernel architecture and uses Foundry as the primary development framework.

## Development Commands

### Essential Commands

- `pnpm run setup` - Initial project setup (installs dependencies, runs forge soldeer, sets up husky)
- `forge test` - Run all tests
- `forge test --match-contract ContractName` - Run tests for specific contract
- `forge test --match-test testFunctionName` - Run specific test
- `forge build` - Compile contracts
- `forge fmt` - Format Solidity code
- `pnpm run lint` - Run pre-commit hooks and linting (covers solhint, forge fmt, forge test)

### Testing & Coverage

- `forge coverage` - Generate coverage report
- `pnpm run coverage` - Generate HTML coverage report (requires lcov)
- `pnpm run lcov` - Generate lcov coverage report
- `forge snapshot` - Generate gas snapshots
- `pnpm run diff` - Compare gas snapshots

### Analysis & Security

- `pnpm run slither` - Run static analysis with slither
- `forge inspect ContractName abi` - Get contract ABI
- `pnpm run size` - Check contract sizes for vault policies

### Dependencies

- `forge soldeer install` - Install dependencies via soldeer
- `forge soldeer update` - Update dependencies
- `pnpm run remapping` - Generate remappings

## Architecture Overview

### Kernel System

The project uses the Olympus DAO Kernel architecture:

- **Kernel.sol**: Core system that manages modules and policies
- **Modules**: Independent state components (MINTR, TRSRY, ROLES)
- **Policies**: Business logic that interacts with modules through permissions

### Key Components

#### Core Modules

- **MINTR** (`src/modules/MINTR/`): Token minting/burning functionality
- **TRSRY** (`src/modules/TRSRY/`): Treasury management for protocol assets
- **ROLES** (`src/modules/ROLES/`): Role-based access control system

#### Main Policies

- **CallistoVault** (`src/policies/vault/`): ERC4626 vault implementation with OHM backing
- **CallistoHeart** (`src/policies/CallistoHeart.sol`): Keeper reward system with auction mechanism
- **RolesAdmin** (`src/policies/RolesAdmin.sol`): Role management policy

#### External Contracts

- **CallistoPSM** (`src/external/CallistoPSM.sol`): Peg Stability Module
- **CallistoToken** (`src/external/CallistoToken.sol`): Main protocol token
- **VaultStrategy** (`src/external/VaultStrategy.sol`): Vault strategy implementation
- **DebtTokenMigrator** (`src/external/DebtTokenMigrator.sol`): Debt token migration utility

### Directory Structure

```
src/
├── Kernel.sol              # Core kernel system
├── modules/                # System modules (MINTR, TRSRY, ROLES)
├── policies/               # Business logic policies
├── external/               # External contracts
├── interfaces/             # Contract interfaces
└── libraries/              # Utility libraries

test/
├── modules/                # Module tests
├── policies/               # Policy tests
├── external/               # External contract tests
└── test-common/            # Shared test utilities
```

## Testing Patterns

### Test Organization

- Tests are organized by component type (modules, policies, external)
- Fork tests are in separate files (e.g., `CallistoVaultFork.t.sol`)
- Common test utilities are in `test/test-common/`

### Running Tests

- Use `forge test` for standard tests
- Fork tests may require `MAINNET_RPC_URL` environment variable
- Coverage excludes `test/` and `script/` directories by default

## Key Dependencies

### External Libraries

- **OpenZeppelin Contracts 5.3.0**: Standard contract implementations
- **Solmate 6.8.0**: Gas-optimized contract primitives
- **Solady 0.1.19**: Additional utility contracts
- **Olympus V3**: Base kernel architecture and utilities

### Development Tools

- **Foundry**: Primary development framework
- **Soldeer**: Dependency management
- **Pre-commit**: Code quality checks
- **Husky**: Git hooks management

## Configuration

### Foundry Configuration

- Solidity version: 0.8.30
- Optimizer: Enabled (200 runs)
- EVM version: Prague
- Via IR: Enabled for better optimization

### Code Style

- Line length: 120 characters
- Double quotes for strings
- Imports sorted alphabetically
- Comments wrapped at line length

## Security Considerations

- All contracts use role-based access control via the ROLES module
- Kernel system provides controlled access to module functions
- Treasury operations require proper approvals
- Vault implements ERC4626 with additional security features

## Working with the Codebase

### Adding New Contracts

1. Follow the existing directory structure
2. Implement proper kernel integration for policies
3. Add comprehensive tests in corresponding test directory
4. Update deployment scripts if needed

### Modifying Existing Contracts

1. Understand the kernel permission system
2. Check dependencies and module interactions
3. Update tests to reflect changes
4. Run full test suite and coverage analysis

### Debugging

- Use `forge test -vvv` for detailed trace output
- Check gas usage with `forge snapshot`
- Use `forge inspect` to examine contract metadata
- Static analysis with `slither` for security issues
