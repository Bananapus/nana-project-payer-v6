// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjectPayer} from "./IJBProjectPayer.sol";

/// @notice Deploys `JBProjectPayer` EIP-1167 clones.
interface IJBProjectPayerDeployer {
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
