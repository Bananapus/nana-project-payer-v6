// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjectPayer} from "./IJBProjectPayer.sol";

/// @notice Factory that deploys `JBProjectPayer` EIP-1167 minimal proxy clones, each configured to forward funds to
/// a specific Juicebox project.
interface IJBProjectPayerDeployer {
    /// @notice Emitted when a new project payer clone is deployed.
    /// @param projectPayer The newly deployed project payer contract.
    /// @param defaultProjectId The project that will receive payments.
    /// @param defaultBeneficiary The address that will receive project tokens.
    /// @param defaultMemo The memo forwarded with payments.
    /// @param defaultMetadata The metadata forwarded with payments.
    /// @param defaultAddToBalance Whether payments use `addToBalanceOf` instead of `pay`.
    /// @param directory The directory used to look up project terminals.
    /// @param owner The address that owns the project payer.
    /// @param caller The address that deployed the project payer.
    event DeployProjectPayer(
        IJBProjectPayer indexed projectPayer,
        uint256 defaultProjectId,
        address defaultBeneficiary,
        string defaultMemo,
        bytes defaultMetadata,
        bool defaultAddToBalance,
        IJBDirectory directory,
        address owner,
        address caller
    );

    /// @notice The EIP-1167 implementation contract that clones are based on.
    function IMPLEMENTATION() external view returns (address);

    /// @notice The directory of terminals and controllers for each project.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice Deploys a new project payer clone.
    /// @param defaultProjectId The ID of the project that should receive the payer's received payments.
    /// @param defaultBeneficiary The address that should receive tokens from the payments.
    /// @param defaultMemo The memo to forward with payments.
    /// @param defaultMetadata The metadata to forward with payments.
    /// @param defaultAddToBalance Whether received payments should call `addToBalanceOf` instead of `pay`.
    /// @param owner The address that will own the project payer.
    /// @return projectPayer The newly deployed project payer.
    function deployProjectPayer(
        uint256 defaultProjectId,
        address payable defaultBeneficiary,
        string memory defaultMemo,
        bytes memory defaultMetadata,
        bool defaultAddToBalance,
        address owner
    )
        external
        returns (IJBProjectPayer projectPayer);
}
