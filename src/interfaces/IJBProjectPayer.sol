// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";

/// @notice A contract that can receive ETH or ERC20 tokens and forward them to a Juicebox project treasury.
interface IJBProjectPayer is IERC165 {
    event SetDefaultValues(
        uint256 indexed projectId,
        address indexed beneficiary,
        string memo,
        bytes metadata,
        bool addToBalance,
        address caller
    );

    /// @notice The directory of terminals and controllers for each project.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The deployer that created this contract. Only it can call `initialize`.
    function DEPLOYER() external view returns (address);

    /// @notice The ID of the project that should receive this contract's received payments.
    function defaultProjectId() external view returns (uint256);

    /// @notice The beneficiary that should receive tokens from payments made when this contract receives funds.
    function defaultBeneficiary() external view returns (address payable);

    /// @notice The memo that should be forwarded with payments.
    function defaultMemo() external view returns (string memory);

    /// @notice The metadata that should be forwarded with payments.
    function defaultMetadata() external view returns (bytes memory);

    /// @notice Whether received payments should call `addToBalanceOf` instead of `pay` on the project's terminal.
    function defaultAddToBalance() external view returns (bool);

    /// @notice Initializes the clone with default values.
    /// @param projectId The ID of the project that should receive this contract's received payments.
    /// @param beneficiary The address that should receive tokens from payments.
    /// @param memo The memo that should be forwarded with payments.
    /// @param metadata The metadata that should be forwarded with payments.
    /// @param addToBalance Whether to use `addToBalanceOf` instead of `pay`.
    /// @param owner The address that will own this contract.
    function initialize(
        uint256 projectId,
        address payable beneficiary,
        string memory memo,
        bytes memory metadata,
        bool addToBalance,
        address owner
    )
        external;

    /// @notice Updates the default values used when this contract receives direct payments.
    /// @param projectId The ID of the project that should receive this contract's received payments.
    /// @param beneficiary The address that should receive tokens from payments.
    /// @param memo The memo that should be forwarded with payments.
    /// @param metadata The metadata that should be forwarded with payments.
    /// @param addToBalance Whether to use `addToBalanceOf` instead of `pay`.
    function setDefaultValues(
        uint256 projectId,
        address payable beneficiary,
        string memory memo,
        bytes memory metadata,
        bool addToBalance
    )
        external;

    /// @notice Pay the specified project.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in. Use `JBConstants.NATIVE_TOKEN` for the native token.
    /// @param amount The amount of tokens being paid. Ignored if the token is the native token.
    /// @param beneficiary The address that will receive tokens from the payment.
    /// @param minReturnedTokens The minimum number of project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to send along to the terminal.
    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable;

    /// @notice Add to the balance of the specified project.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in. Use `JBConstants.NATIVE_TOKEN` for the native token.
    /// @param amount The amount of tokens being paid. Ignored if the token is the native token.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to send along to the terminal.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable;

    receive() external payable;
}
