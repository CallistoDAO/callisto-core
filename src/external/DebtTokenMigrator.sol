// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Ownable } from "../../dependencies/@openzeppelin-contracts-5.3.0/access/Ownable.sol";
import { IERC20Metadata } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { SafeERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";
import { IMonoCooler } from "../interfaces/IMonoCooler.sol";
import { CallistoVault } from "../policies/CallistoVault.sol";
import { CallistoPSM } from "./CallistoPSM.sol";
import { VaultStrategy } from "./VaultStrategy.sol";

/**
 * @title Debt Token Migrator
 * @notice Migrates the debt token used by the Callisto vault to a new USD stablecoin and ERC4626 vault if
 * Olympus Cooler V2 changes its debt token. Initially, the debt token is USDS and the yield vault is sUSDS.
 */
contract DebtTokenMigrator is Ownable {
    using SafeERC20 for IERC20Metadata;
    using Math for uint256;

    // ___ CONSTANTS & IMMUTABLES ___

    /// @notice Represents 100.000%.
    uint256 public constant ONE_HUNDRED_PERCENT = 100_000;

    /// @notice The Olympus Cooler V2 contract.
    IMonoCooler public immutable OLYMPUS_COOLER;

    // ___ STORAGE ___

    /// @notice Callisto Peg Stability Module (PSM).
    CallistoPSM public psm;

    /// @notice The timestamp after which migration can be executed.
    uint256 public migrationTime;

    /**
     * @notice Allowed slippage (max loss from current total assets) during migration.
     */
    uint256 public slippage;

    /// @notice The new debt token.
    IERC20Metadata public newDebtToken;

    /// @notice The ERC4626 yield vault for the new debt token.
    IERC4626 public newYieldVault;

    /**
     * @notice Converter contract for wad (Olympus) to new debt token decimals.
     */
    address public newConverterToWadDebt;

    // ___ EVENTS ___

    /// @notice Emitted when the PSM address is set.
    event PSMAddressInitialized(address indexed psm);

    /// @notice Emitted when migration parameters are set.
    event MigrationSet(
        address indexed newDebtToken,
        address indexed newYieldVault,
        address indexed newConverterToWadDebt,
        uint256 migrationTime,
        uint256 slippage
    );

    /// @notice Emitted when debt token migration is executed.
    event DebtTokenMigrated(
        address indexed newDebtToken,
        address indexed newYieldVaultAddr,
        address indexed caller,
        uint256 debtTokenAmount,
        uint256 newDebtTokenAmount
    );

    // ___ ERRORS ___

    error ZeroAddress();

    error AlreadyInitialized();

    error MigrationTimeInPast();

    error TooSoon();

    error NewDebtTokenExpected();

    error YieldVaultHasAnotherAsset(address asset, address newDebtToken);

    error SlippageExceeded(uint256 diff, uint256 maxDiff);

    // ___ MODIFIERS ___

    modifier nonzeroAddress(address addr) {
        require(addr != address(0), ZeroAddress());
        _;
    }

    // ___ INITIALIZATION ___

    constructor(address owner, address olympusCooler) Ownable(owner) nonzeroAddress(olympusCooler) {
        OLYMPUS_COOLER = IMonoCooler(olympusCooler);
    }

    /**
     * @notice Sets the PSM address (can only be set once).
     * @param psm_ psm contract address.
     */
    function initializePSMAddress(address psm_) external onlyOwner nonzeroAddress(psm_) {
        require(address(psm) == address(0), AlreadyInitialized());
        psm = CallistoPSM(psm_);
        emit PSMAddressInitialized(psm_);
    }

    // ___ EXTERNAL FUNCTIONS ___

    /**
     * @notice Sets migration parameters.
     * @param migrationTime_ Timestamp when migration can begin.
     * @param slippage_ Max allowed slippage (see `ONE_HUNDRED_PERCENT`).
     * @param newYieldVaultAddr New ERC4626 yield vault address for a new debt token.
     * @param newConvertorToWadAddr Converter from wad to new debt token decimals.
     */
    function setMigration(
        uint256 migrationTime_,
        uint256 slippage_,
        address newYieldVaultAddr,
        address newConvertorToWadAddr
    ) external onlyOwner {
        require(migrationTime_ > block.timestamp, MigrationTimeInPast());
        require(newConvertorToWadAddr != address(0), ZeroAddress());

        address newDebtTokenAddr = address(OLYMPUS_COOLER.debtToken());
        // Ensure that the vault's debt token and the Olympus Cooler V2 debt token do not match.
        require(address(VaultStrategy(psm.liquidityProvider()).asset()) != newDebtTokenAddr, NewDebtTokenExpected());

        IERC4626 newYieldVault_ = IERC4626(newYieldVaultAddr);
        // Validate that the new yield vault's asset matches `newDebtTokenAddr`.
        if (newYieldVault_.asset() != newDebtTokenAddr) {
            revert YieldVaultHasAnotherAsset(newYieldVault_.asset(), newDebtTokenAddr);
        }

        migrationTime = migrationTime_;
        slippage = slippage_;
        newDebtToken = IERC20Metadata(newDebtTokenAddr);
        newYieldVault = newYieldVault_;
        newConverterToWadDebt = newConvertorToWadAddr;
        emit MigrationSet(newDebtTokenAddr, newYieldVaultAddr, newConvertorToWadAddr, migrationTime_, slippage_);
    }

    /**
     * @notice Executes migration to a new debt token set by `setMigration`.
     *
     * Caller can use a flash loan to provide `newDebtTokenAmount` of the new debt token, then receives
     * the old debt token to swap and repay the flash loan.
     *
     * @param newDebtTokenAmount Amount of new debt token provided by the caller.
     */
    function migrateDebtToken(uint256 newDebtTokenAmount) external {
        // Ensure the migration can start and is set.
        require(block.timestamp >= migrationTime && migrationTime != 0, TooSoon());

        // Reset the migration.
        delete migrationTime;

        // Calculates the total assets to be exchanged.
        CallistoPSM psm_ = psm;
        VaultStrategy strategy = VaultStrategy(psm_.liquidityProvider());
        CallistoVault vault = CallistoVault(strategy.vault());
        address psmAddr = address(psm_);
        uint256 debtTokenAmount = IERC4626(strategy.yieldVault()).maxWithdraw(psmAddr);

        // Gets the total assets supplied in the PSM to convert this value using new decimals.
        uint256 suppliedInPSM = psm_.suppliedByLP();

        /* Converts amounts to new decimals if necessary.
         *
         * Warning. When migrating from a debt token with higher decimals to one with lower decimals,
         * the operation involves division with upward rounding, ensuring that the Callisto vault has sufficient
         * tokens to fully repay its debt in Olympus Cooler Loans V2.
         */
        IERC20Metadata newDebtToken_ = newDebtToken;
        uint8 fromDecimals = IERC20Metadata(address(vault.debtToken())).decimals();
        uint8 toDecimals = newDebtToken_.decimals();
        uint256 debtTokenAmountConverted;
        uint256 suppliedInPSMConverted;
        if (fromDecimals > toDecimals) {
            uint256 precisionDiff = 10 ** uint256(fromDecimals - toDecimals);
            debtTokenAmountConverted = debtTokenAmount.ceilDiv(precisionDiff);
            suppliedInPSMConverted = suppliedInPSM.ceilDiv(precisionDiff);
        } else if (fromDecimals < toDecimals) {
            uint256 precisionDiff = 10 ** uint256(toDecimals - fromDecimals);
            debtTokenAmountConverted = debtTokenAmount * precisionDiff;
            suppliedInPSMConverted = suppliedInPSM * precisionDiff;
        } else {
            debtTokenAmountConverted = debtTokenAmount;
            suppliedInPSMConverted = suppliedInPSM;
        }

        /* If the passed `newDebtTokenAmount` is less than the current amount, validates that the difference is within
         * the allowed slippage.
         */
        if (newDebtTokenAmount < debtTokenAmountConverted) {
            uint256 diff = debtTokenAmountConverted - newDebtTokenAmount;
            uint256 maxDiff = (debtTokenAmountConverted * slippage) / ONE_HUNDRED_PERCENT;
            require(diff <= maxDiff, SlippageExceeded(diff, maxDiff));
        }

        // Migrates the asset and updates values within the contracts.
        address newDebtTokenAddr = address(newDebtToken_);
        IERC4626 newYieldVault_ = newYieldVault;
        address newYieldVaultAddr = address(newYieldVault_);
        psm_.migrateAsset(newDebtTokenAddr, newYieldVaultAddr, msg.sender, debtTokenAmount, suppliedInPSMConverted);
        strategy.migrateAsset(newDebtToken_, newYieldVault);
        vault.migrateDebtToken(newDebtTokenAddr, newConverterToWadDebt);

        // Transfers new debt tokens from the caller, deposits into the new yield vault and transfers shares to the PSM.
        newDebtToken_.safeTransferFrom(msg.sender, address(this), newDebtTokenAmount);
        newDebtToken_.approve(newYieldVaultAddr, newDebtTokenAmount);
        newYieldVault_.deposit({ assets: newDebtTokenAmount, receiver: psmAddr });

        emit DebtTokenMigrated(newDebtTokenAddr, newYieldVaultAddr, msg.sender, debtTokenAmount, newDebtTokenAmount);
    }
}
