// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IERC4626 } from "../../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import {
    ERC20, IERC20, IERC20Metadata
} from "../../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/ERC20.sol";
import { SafeERC20 } from "../../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";

/**
 * @dev Implementation of the ERC-4626 "Tokenized Vault Standard" as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[ERC-4626].
 *
 * Features:
 * - The asset is assumed to be Olympus OHM and should have 9 decimals.
 * - Shares have 18 decimal places.
 * - The asset-to-share rate is 1-to-1.
 */
abstract contract CallistoOHMVaultBase is ERC20, IERC4626 {
    using Math for uint256;

    uint256 private constant _TO_18_DECIMALS_FACTOR = 1e9;
    IERC20 internal immutable _OHM;

    error OHMExpected();

    /// @dev Attempted to withdraw more assets than the max amount for `receiver`.
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);

    /// @dev Attempted to redeem more shares than the max amount for `receiver`.
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    /// @dev Set the underlying asset contract. This must be an ERC20-compatible contract.
    constructor(IERC20Metadata asset_) {
        require(asset_.decimals() == 9, OHMExpected());
        _OHM = IERC20(address(asset_));
    }

    /// @dev See {IERC4626-asset}.
    function asset() public view returns (address) {
        return address(_OHM);
    }

    /// @dev See {IERC4626-totalAssets}.
    function totalAssets() public view returns (uint256) {
        return _convertToAssets(totalSupply(), Math.Rounding.Floor);
    }

    /// @dev See {IERC4626-convertToShares}.
    function convertToShares(uint256 assets) public pure returns (uint256) {
        return _convertToShares(assets);
    }

    /// @dev See {IERC4626-convertToAssets}.
    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @dev See {IERC4626-maxDeposit}.
    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @dev See {IERC4626-maxMint}.
    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @dev See {IERC4626-maxWithdraw}.
    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    /// @dev See {IERC4626-maxRedeem}.
    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    /// @dev See {IERC4626-previewDeposit}.
    function previewDeposit(uint256 assets) public pure returns (uint256) {
        return _convertToShares(assets);
    }

    /// @dev See {IERC4626-previewMint}.
    function previewMint(uint256 shares) public pure returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @dev See {IERC4626-previewWithdraw}.
    function previewWithdraw(uint256 assets) public pure returns (uint256) {
        return _convertToShares(assets);
    }

    /// @dev See {IERC4626-previewRedeem}.
    function previewRedeem(uint256 shares) public pure returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @dev See {IERC4626-deposit}.
    function deposit(uint256 assets, address receiver) external virtual returns (uint256);

    /// @dev See {IERC4626-mint}.
    function mint(uint256 shares, address receiver) external virtual returns (uint256);

    /// @dev See {IERC4626-withdraw}.
    function withdraw(uint256 assets, address receiver, address owner) external virtual returns (uint256);

    /// @dev See {IERC4626-redeem}.
    function redeem(uint256 shares, address receiver, address owner) external virtual returns (uint256);

    /// @dev Deposit/mint common workflow.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        // slither-disable-next-line reentrancy-no-eth
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdraw/redeem common workflow.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
        if (caller != owner) _spendAllowance(owner, caller, shares);

        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _convertToShares(uint256 assets) private pure returns (uint256) {
        return assets * _TO_18_DECIMALS_FACTOR;
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) private pure returns (uint256) {
        if (rounding == Math.Rounding.Ceil || rounding == Math.Rounding.Expand) {
            return shares.ceilDiv(_TO_18_DECIMALS_FACTOR);
        }
        return shares / _TO_18_DECIMALS_FACTOR;
    }
}
