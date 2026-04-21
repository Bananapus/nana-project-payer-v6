// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjectPayer} from "./interfaces/IJBProjectPayer.sol";
import {IJBProjectPayerDeployer} from "./interfaces/IJBProjectPayerDeployer.sol";
import {JBProjectPayer} from "./JBProjectPayer.sol";

/// @notice Deploys `JBProjectPayer` EIP-1167 clones.
contract JBProjectPayerDeployer is IJBProjectPayerDeployer {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The EIP-1167 implementation contract that clones are based on.
    address public immutable override IMPLEMENTATION;

    /// @notice The directory of terminals and controllers for each project.
    IJBDirectory public immutable override DIRECTORY;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    constructor(IJBDirectory directory) {
        IMPLEMENTATION = address(new JBProjectPayer(directory));
        DIRECTORY = directory;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

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
        override
        returns (IJBProjectPayer projectPayer)
    {
        // Deploy the project payer clone.
        projectPayer = IJBProjectPayer(payable(Clones.clone(IMPLEMENTATION)));

        // Initialize the project payer.
        projectPayer.initialize({
            projectId: defaultProjectId,
            beneficiary: defaultBeneficiary,
            memo: defaultMemo,
            metadata: defaultMetadata,
            addToBalance: defaultAddToBalance,
            owner: owner
        });

        emit DeployProjectPayer({
            projectPayer: projectPayer,
            defaultProjectId: defaultProjectId,
            defaultBeneficiary: defaultBeneficiary,
            defaultMemo: defaultMemo,
            defaultMetadata: defaultMetadata,
            defaultAddToBalance: defaultAddToBalance,
            directory: DIRECTORY,
            owner: owner,
            caller: msg.sender
        });
    }
}
