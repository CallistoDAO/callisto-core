// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Ownable } from "../../dependencies/@openzeppelin-contracts-5.3.0/access/Ownable.sol";
import { IERC20, IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { SafeERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";

import { CallistoVault } from "../../src/policies/CallistoVault.sol";
import { CallistoPSM } from "./CallistoPSM.sol";
import { DebtTokenMigrator } from "./DebtTokenMigrator.sol";

/**
 * @title Callisto Vault Strategy
 * @notice Implements a strategy for the Callisto vault: deposits assets (e.g., USDS) into an ERC4626 yield vault
 * (e.g., sUSDS). Yield is used to repay Olympus Cooler Loans V2 debt; surplus goes into the Callisto treasury.
 *
 * @dev Initially uses USDS as the asset and sUSDS as the yield vault. If Olympus Cooler V2 changes its debt token,
 * the new asset is assumed to be a USD stablecoin compatible with ERC4626.
 */
contract VaultStrategy is Ownable {
    using SafeERC20 for IERC20;

    // ___ IMMUTABLES ___

    /// @notice Callisto Peg Stability Module (PSM) for COLLAR stablecoin.
    CallistoPSM public immutable PSM;

    /// @notice The contract address authorized to migrate the debt token.
    address public debtTokenMigrator;

    // ___ STORAGE ___

    /// @notice Callisto vault address.
    address public vault;

    /// @notice The asset is the debt token of Olympus Cooler V2 (initially USDS).
    IERC20 public asset;

    /// @notice The ERC4626 yield vault for the debt token (initially sUSDS).
    IERC4626 public yieldVault;

    // ___ EVENTS ___

    /**
     * @notice Emitted when assets are deposited into the yield vault by the Callisto vault.
     * @param assets The amount of assets deposited.
     */
    event Invested(uint256 assets);

    /**
     * @notice Emitted when assets are withdrawn from the yield vault.
     * @param receiver Recipient of withdrawn assets.
     * @param assets The amount of assets withdrawn.
     */
    event Divested(address indexed receiver, uint256 assets);

    /**
     * @notice Emitted when asset and yield vault migration.
     * If Olympus Cooler V2 changes its debt token, `DEBT_TOKEN_MIGRATOR` replaces the asset with the new debt token.
     * @param newAsset The new debt token address.
     * @param newYieldVault The new ERC4626 yield vault address.
     */
    event AssetMigrated(address newAsset, address newYieldVault);

    /**
     * @dev Emitted when the vault address is set.
     * @param vault The vault address.
     */
    event VaultInitialized(address vault);

    /**
     * @notice Emitted when the debt token migrator address is updated
     * @param oldMigrator The previous migrator address
     * @param newMigrator The new migrator address
     */
    event DebtTokenMigratorSet(address indexed oldMigrator, address indexed newMigrator);

    // ___ ERRORS ___

    error ZeroAddress();

    error AlreadyInitialized();

    error OnlyVault();

    error ZeroValue();

    error UnexpectedAsset(address unexpected);

    error OnlyDebtTokenMigrator(address migrator);

    error MigratorNotSet();

    error MismatchedCoolerAddress();

    // ___ MODIFIERS ___

    modifier onlyVault() {
        require(msg.sender == vault, OnlyVault());
        _;
    }

    modifier nonzeroValue(uint256 v) {
        require(v != 0, ZeroValue());
        _;
    }

    // ___ INITIALIZATION ___

    /**
     * @dev Initializes strategy with asset, yield vault.
     * @param owner The initial owner.
     * @param asset_ The initial asset (e.g., USDS, Olympus Cooler V2 debt token).
     * @param psm The Callisto PSM address.
     * @param yieldVault_ The ERC4626 yield vault (e.g., sUSDS).
     * @dev Sets infinite approval for the yield vault.
     */
    constructor(address owner, IERC20 asset_, address psm, IERC4626 yieldVault_) Ownable(owner) {
        require(psm != address(0), ZeroAddress());
        require(yieldVault_.asset() == address(asset_), UnexpectedAsset(address(asset_)));

        asset = asset_;
        PSM = CallistoPSM(psm);
        yieldVault = yieldVault_;
        debtTokenMigrator = address(0);

        // Set the permanent allowance of `yieldVault_` over this strategy's assets.
        // slither-disable-next-line unused-return
        asset_.approve(address(yieldVault_), type(uint256).max);
    }

    /**
     * @dev Sets the Callisto vault address (can only be set once).
     * @param vault_ The vault address.
     */
    function initVault(address vault_) external onlyOwner {
        require(vault == address(0), AlreadyInitialized());
        require(vault_ != address(0), ZeroAddress());
        vault = vault_;
        emit VaultInitialized(vault_);
    }

    /**
     * @notice Sets the debt token migrator address.
     * @param newMigrator The new debt token migrator address (can be address(0) to disable migrations)
     */
    function setDebtTokenMigrator(address newMigrator) external onlyOwner {
        if (newMigrator != address(0)) {
            require(
                address(DebtTokenMigrator(newMigrator).OLYMPUS_COOLER())
                    == address(CallistoVault(vault).OLYMPUS_COOLER()),
                MismatchedCoolerAddress()
            );
        }
        address oldMigrator = debtTokenMigrator;
        debtTokenMigrator = newMigrator;
        emit DebtTokenMigratorSet(oldMigrator, newMigrator);
    }

    // ___ DEPOSIT & WITHDRAWAL LOGIC ___

    /**
     * @notice Deposits `assets` into the yield vault and provides shares to the Callisto PSM as liquidity.
     * @param assets The amount to deposit.
     */
    function invest(uint256 assets) external onlyVault nonzeroValue(assets) {
        // Deposit `assets` into `yieldVault` obtaining shares.
        IERC4626 yieldVault_ = yieldVault;
        // slither-disable-next-line unused-return
        asset.approve(address(yieldVault_), assets);
        uint256 shares = yieldVault_.deposit(assets, address(PSM));

        // record `shares` (sUSDS) into the Callisto PSM.
        PSM.addLiquidity(shares);
        emit Invested(assets);
    }

    /**
     * @notice Withdraws `assets` from the Callisto PSM (PSM redeems shares from the yield vault) to a `receiver`.
     * @param assets The amount to withdraw.
     * @param receiver The recipient address.
     */
    function divest(uint256 assets, address receiver) external onlyVault nonzeroValue(assets) {
        // slither-disable-next-line unused-return
        PSM.removeLiquidityAsAssets(assets, receiver);
        emit Divested(receiver, assets);
    }

    // ___ VIEWERS ___

    /// @notice Returns total assets invested by the Callisto vault.
    function totalAssetsInvested() external view returns (uint256) {
        return yieldVault.previewRedeem(PSM.suppliedByLP());
    }

    /// @notice Returns the maximum assets currently withdrawable by the Callisto vault.
    function totalAssetsAvailable() external view returns (uint256 assets) {
        CallistoPSM psm = PSM;
        IERC4626 yieldVault_ = yieldVault;
        assets = yieldVault_.maxWithdraw(address(psm));
        uint256 totalAssetsSupplied = yieldVault_.previewRedeem(psm.suppliedByLP());
        if (assets > totalAssetsSupplied) assets = totalAssetsSupplied;
        return assets;
    }

    // ___ DEBT TOKEN MIGRATION LOGIC ___

    /**
     * @notice Migrates to the `newAsset` and `newYieldVault`. Sets infinite approval for the `newYieldVault`.
     *
     * This function should be called by the `DEBT_TOKEN_MIGRATOR`.
     *
     * @param newAsset The new debt token address.
     * @param newYieldVault The new ERC4626 yield vault address.
     */
    function migrateAsset(IERC20 newAsset, IERC4626 newYieldVault) external {
        address migrator = debtTokenMigrator;
        require(migrator != address(0), MigratorNotSet());
        require(msg.sender == migrator, OnlyDebtTokenMigrator(migrator));
        require(address(newAsset) == address(CallistoVault(vault).OLYMPUS_COOLER().treasuryBorrower().debtToken()));

        asset = newAsset;
        yieldVault = newYieldVault;

        // Set the permanent allowance of `newYieldVault` over this strategy's assets.
        address newYieldVaultAddr = address(newYieldVault);
        // slither-disable-next-line unused-return
        newAsset.approve(newYieldVaultAddr, type(uint256).max);

        emit AssetMigrated(address(newAsset), newYieldVaultAddr);
    }
}
