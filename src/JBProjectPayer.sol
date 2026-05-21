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
import {IJBPayerTracker} from "./interfaces/IJBPayerTracker.sol";
import {IJBProjectPayer} from "./interfaces/IJBProjectPayer.sol";

/// @notice A payment relay that forwards ETH or ERC-20 tokens to a Juicebox project's treasury. Can be used as a
/// standalone address that auto-pays a project when it receives funds (via `receive()`), or called directly with
/// `pay`/`addToBalanceOf` for explicit routing. Deployed as EIP-1167 clones via `JBProjectPayerDeployer`.
/// @dev The owner can update default routing parameters (project ID, beneficiary, memo, metadata, pay-vs-addToBalance).
/// Inherit from this contract to build custom forwarding logic on top of Juicebox payments.
/// Implements `IJBPayerTracker` so router-style terminals can refund partial-fill leftovers and resolve credit
/// cash-outs against the original payer instead of this intermediary contract.
contract JBProjectPayer is Ownable, ERC165, IJBPayerTracker, IJBProjectPayer {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // -------------------------- custom errors -------------------------- //
    //*********************************************************************//

    /// @notice Thrown when `initialize` is called by an address that is not the deployer.
    /// @param caller The address that attempted to initialize the clone.
    /// @param deployer The deployer address that is allowed to initialize the clone.
    error JBProjectPayer_AlreadyInitialized(address caller, address deployer);

    /// @notice Thrown when `msg.value` is non-zero but the token to pay with is not the native token.
    /// @param msgValue The native token amount sent with the call.
    /// @param token The token that was being paid with.
    error JBProjectPayer_NoMsgValueAllowed(uint256 msgValue, address token);

    /// @notice Thrown when no terminal is found for the project and token.
    /// @param projectId The project ID whose primary terminal was requested.
    /// @param token The token whose primary terminal was requested.
    error JBProjectPayer_TerminalNotFound(uint256 projectId, address token);

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
    // -------------------- transient stored properties ------------------ //
    //*********************************************************************//

    /// @inheritdoc IJBPayerTracker
    /// @dev Set to `msg.sender` for the duration of each forwarded `pay`/`addToBalanceOf` call so downstream
    /// router-style terminals can resolve refunds and credit cash-outs against the true payer. Always cleared
    /// back to the prior value after the terminal call returns.
    address public transient override originalPayer;

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
                amount: msg.value,
                memo: defaultMemo,
                metadata: defaultMetadata
            });
        } else {
            _pay({
                projectId: defaultProjectId,
                token: JBConstants.NATIVE_TOKEN,
                amount: msg.value,
                beneficiary: defaultBeneficiary == address(0) ? payable(msg.sender) : defaultBeneficiary,
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
        if (msg.sender != DEPLOYER) revert JBProjectPayer_AlreadyInitialized({caller: msg.sender, deployer: DEPLOYER});

        // Set the default values. The deployer emits the initialized defaults in its DeployProjectPayer event.
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
        // Set the default values. A zero beneficiary intentionally falls back to msg.sender during pay routing.
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
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay with. Use `JBConstants.NATIVE_TOKEN` for the native token.
    /// @param amount The amount of tokens to pay. Ignored if the token is the native token.
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
            if (msg.value > 0) revert JBProjectPayer_NoMsgValueAllowed({msgValue: msg.value, token: token});

            // Get a reference to the balance before receiving tokens.
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));

            // Transfer tokens to this contract from the msg sender.
            IERC20(token).safeTransferFrom({from: msg.sender, to: address(this), value: amount});

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
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay with. Use `JBConstants.NATIVE_TOKEN` for the native token.
    /// @param amount The amount of tokens to pay. Ignored if the token is the native token.
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
            if (msg.value > 0) revert JBProjectPayer_NoMsgValueAllowed({msgValue: msg.value, token: token});

            // Get a reference to the balance before receiving tokens.
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));

            // Transfer tokens to this contract from the msg sender.
            IERC20(token).safeTransferFrom({from: msg.sender, to: address(this), value: amount});

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
        return interfaceId == type(IJBProjectPayer).interfaceId || interfaceId == type(IJBPayerTracker).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Pay the specified project.
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay with.
    /// @param amount The amount of tokens to pay.
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
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: token});

        // There must be a terminal.
        if (terminal == IJBTerminal(address(0))) {
            revert JBProjectPayer_TerminalNotFound({projectId: projectId, token: token});
        }

        // Approve the terminal to spend the tokens if not the native token.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove({spender: address(terminal), value: amount});

        // If the token is the native token, send it in msg.value.
        uint256 payableValue = token == JBConstants.NATIVE_TOKEN ? amount : 0;

        // Save any previous payer so nested calls (via pay hooks) restore correctly on return.
        address previousPayer = originalPayer;

        // Expose the original payer to downstream router-style terminals so partial-fill refunds and credit
        // cash-outs reach the true caller instead of this intermediary contract. When the immediate caller
        // is itself a forwarding tracker, propagate its upstream payer so a multi-hop chain doesn't strand
        // refunds at the intermediary.
        originalPayer = _originalPayerOrSender();

        // Send funds to the terminal.
        terminal.pay{value: payableValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary != address(0)
                ? beneficiary
                : defaultBeneficiary != address(0) ? defaultBeneficiary : msg.sender,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });

        // Restore the previous payer.
        originalPayer = previousPayer;

        // Clear any allowance left by terminals which pull less than `amount`.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove({spender: address(terminal), value: 0});
    }

    /// @notice Add to the balance of the specified project.
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay with.
    /// @param amount The amount of tokens to pay.
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
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: token});

        // There must be a terminal.
        if (terminal == IJBTerminal(address(0))) {
            revert JBProjectPayer_TerminalNotFound({projectId: projectId, token: token});
        }

        // Approve the terminal to spend the tokens if not the native token.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove({spender: address(terminal), value: amount});

        // If the token is the native token, send it in msg.value.
        uint256 payableValue = token == JBConstants.NATIVE_TOKEN ? amount : 0;

        // Save any previous payer so nested calls (via pay hooks) restore correctly on return.
        address previousPayer = originalPayer;

        // Expose the original payer to downstream router-style terminals so partial-fill refunds and credit
        // cash-outs reach the true caller instead of this intermediary contract. When the immediate caller
        // is itself a forwarding tracker, propagate its upstream payer so a multi-hop chain doesn't strand
        // refunds at the intermediary.
        originalPayer = _originalPayerOrSender();

        // Add to the project's balance without minting tokens.
        terminal.addToBalanceOf{value: payableValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: memo,
            metadata: metadata
        });

        // Restore the previous payer.
        originalPayer = previousPayer;

        // Clear any allowance left by terminals which pull less than `amount`.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove({spender: address(terminal), value: 0});
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Returns the original payer to record in transient storage. If `msg.sender` is a
    /// contract that exposes `IJBPayerTracker.originalPayer()` and that getter returns a non-zero
    /// value, the upstream payer is propagated so a chain (upstream tracker -> this payer ->
    /// terminal) refunds the true originator instead of the intermediary contract. Otherwise the
    /// direct caller is recorded — the common direct-call case.
    /// @return originalPayerOrSender The upstream payer if `msg.sender` is a forwarding tracker
    /// that returns a non-zero address; otherwise `msg.sender`.
    function _originalPayerOrSender() internal view returns (address originalPayerOrSender) {
        // EOAs and contracts without code can't implement IJBPayerTracker — record them directly.
        if (msg.sender.code.length == 0) return msg.sender;

        // Probe the caller for IJBPayerTracker.originalPayer() via staticcall so a reverting or
        // non-conformant caller does not bubble up — fall back to the direct caller on failure.
        (bool ok, bytes memory data) =
            msg.sender.staticcall(abi.encodeWithSelector(IJBPayerTracker.originalPayer.selector));

        // Caller doesn't implement the interface (revert) or returned a truncated payload — treat
        // it as a direct payment from the caller itself.
        if (!ok || data.length < 32) return msg.sender;

        // Decode the upstream payer the caller advertised. A zero value means "no upstream tracked",
        // which only happens when the caller is itself receiving a direct call — record the caller.
        address upstream = abi.decode(data, (address));
        return upstream == address(0) ? msg.sender : upstream;
    }
}
