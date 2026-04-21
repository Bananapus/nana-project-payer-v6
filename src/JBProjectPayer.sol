// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBProjectPayer} from "./interfaces/IJBProjectPayer.sol";

/// @notice Sends ETH or ERC20 tokens to a Juicebox project's treasury as it receives direct payments or has its
/// functions called.
/// @dev Inherit from this contract or borrow from its logic to forward ETH or ERC20 tokens to project treasuries from
/// within other contracts.
contract JBProjectPayer is Ownable, ERC165, IJBProjectPayer {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // -------------------------- custom errors -------------------------- //
    //*********************************************************************//

    /// @notice Thrown when `initialize` is called by an address that is not the deployer.
    error JBProjectPayer_AlreadyInitialized();

    /// @notice Thrown when `msg.value` is non-zero but the token being paid is not the native token.
    error JBProjectPayer_NoMsgValueAllowed();

    /// @notice Thrown when no terminal is found for the project and token.
    error JBProjectPayer_TerminalNotFound();

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for each project.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The deployer that created this contract. Only it can call `initialize`.
    address public immutable override DEPLOYER;

    //*********************************************************************//
    // ----------------------- public stored properties ------------------ //
    //*********************************************************************//

    /// @notice The ID of the project that should receive this contract's received payments.
    uint256 public override defaultProjectId;

    /// @notice The beneficiary that should receive tokens from payments made when this contract receives funds.
    address payable public override defaultBeneficiary;

    /// @notice The memo that should be forwarded with payments.
    string public override defaultMemo;

    /// @notice The metadata that should be forwarded with payments.
    bytes public override defaultMetadata;

    /// @notice Whether received payments should call `addToBalanceOf` instead of `pay` on the project's terminal.
    bool public override defaultAddToBalance;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev This is the constructor of the implementation. The directory is shared between clones and is immutable.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    constructor(IJBDirectory directory) Ownable(msg.sender) {
        DIRECTORY = directory;
        DEPLOYER = msg.sender;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Received funds are paid to the default project using the stored default properties.
    /// @dev Uses `addToBalanceOf` if there's a preference to do so. Otherwise uses `pay`.
    /// @dev This function is called automatically when the contract receives an ETH payment.
    receive() external payable virtual override {
        if (defaultAddToBalance) {
            _addToBalanceOf({
                projectId: defaultProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: address(this).balance,
                memo: defaultMemo,
                metadata: defaultMetadata
            });
        } else {
            _pay({
                projectId: defaultProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: address(this).balance,
                beneficiary: defaultBeneficiary == address(0) ? payable(tx.origin) : defaultBeneficiary,
                minReturnedTokens: 0,
                memo: defaultMemo,
                metadata: defaultMetadata
            });
        }
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Initializes the clone with default values.
    /// @dev Can only be called by the deployer, and only once per clone.
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
        external
        override
    {
        // Only the deployer can initialize clones.
        if (msg.sender != DEPLOYER) revert JBProjectPayer_AlreadyInitialized();

        // Set the default values.
        defaultProjectId = projectId;
        defaultBeneficiary = beneficiary;
        defaultMemo = memo;
        defaultMetadata = metadata;
        defaultAddToBalance = addToBalance;

        // Transfer ownership to the specified owner.
        _transferOwnership(owner);
    }

    /// @notice Updates the default values used when this contract receives direct payments.
    /// @dev Only the owner can update default values.
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
        external
        override
        onlyOwner
    {
        // Set the default values.
        defaultProjectId = projectId;
        defaultBeneficiary = beneficiary;
        defaultMemo = memo;
        defaultMetadata = metadata;
        defaultAddToBalance = addToBalance;

        emit SetDefaultValues({
            projectId: projectId,
            beneficiary: beneficiary,
            memo: memo,
            metadata: metadata,
            addToBalance: addToBalance,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

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
        public
        payable
        virtual
        override
    {
        // ETH shouldn't be sent if the token isn't the native token.
        if (token != JBConstants.NATIVE_TOKEN) {
            if (msg.value > 0) revert JBProjectPayer_NoMsgValueAllowed();

            // Get a reference to the balance before receiving tokens.
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));

            // Transfer tokens to this contract from the msg sender.
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            // The amount should reflect the change in balance.
            amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        } else {
            // If the native token is being paid, set the amount to the message value.
            amount = msg.value;
        }

        _pay({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });
    }

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
        public
        payable
        virtual
        override
    {
        // ETH shouldn't be sent if the token isn't the native token.
        if (token != JBConstants.NATIVE_TOKEN) {
            if (msg.value > 0) revert JBProjectPayer_NoMsgValueAllowed();

            // Get a reference to the balance before receiving tokens.
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));

            // Transfer tokens to this contract from the msg sender.
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            // The amount should reflect the change in balance.
            amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        } else {
            // If the native token is being paid, set the amount to the message value.
            amount = msg.value;
        }

        _addToBalanceOf({projectId: projectId, token: token, amount: amount, memo: memo, metadata: metadata});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBProjectPayer).interfaceId || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Pay the specified project.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in.
    /// @param amount The amount of tokens being paid.
    /// @param beneficiary The address that will receive tokens from the payment.
    /// @param minReturnedTokens The minimum number of project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to send along to the terminal.
    function _pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string memory memo,
        bytes memory metadata
    )
        internal
        virtual
    {
        // Find the terminal for the specified project.
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf(projectId, token);

        // There must be a terminal.
        if (terminal == IJBTerminal(address(0))) revert JBProjectPayer_TerminalNotFound();

        // Approve the terminal to spend the tokens if not the native token.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove(address(terminal), amount);

        // If the token is the native token, send it in msg.value.
        uint256 payableValue = token == JBConstants.NATIVE_TOKEN ? amount : 0;

        // Send funds to the terminal.
        terminal.pay{value: payableValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary != address(0)
                ? beneficiary
                : defaultBeneficiary != address(0) ? defaultBeneficiary : tx.origin,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Add to the balance of the specified project.
    /// @param projectId The ID of the project being paid.
    /// @param token The token being paid in.
    /// @param amount The amount of tokens being paid.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to send along to the terminal.
    function _addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        string memory memo,
        bytes memory metadata
    )
        internal
        virtual
    {
        // Find the terminal for the specified project.
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf(projectId, token);

        // There must be a terminal.
        if (terminal == IJBTerminal(address(0))) revert JBProjectPayer_TerminalNotFound();

        // Approve the terminal to spend the tokens if not the native token.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove(address(terminal), amount);

        // If the token is the native token, send it in msg.value.
        uint256 payableValue = token == JBConstants.NATIVE_TOKEN ? amount : 0;

        // Add to the project's balance without minting tokens.
        terminal.addToBalanceOf{value: payableValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: memo,
            metadata: metadata
        });
    }
}
