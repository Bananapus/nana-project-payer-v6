// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";

contract MockAuditDirectory {
    mapping(uint256 => mapping(address => address)) internal _primaryTerminalOf;

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return IJBTerminal(_primaryTerminalOf[projectId][token]);
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, address terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }
}

contract RecordingTerminal {
    address public lastBeneficiary;
    uint256 public lastAmount;

    function pay(
        uint256,
        address,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        lastBeneficiary = beneficiary;
        lastAmount = amount;
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract TreasuryForwarder {
    function forwardViaReceive(address payable payer) external {
        (bool success,) = payer.call{value: address(this).balance}("");
        require(success, "FORWARD_FAILED");
    }

    function forwardViaPay(IJBProjectPayer payer, uint256 projectId) external {
        payer.pay{value: address(this).balance}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: address(0),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }
}

contract CodexNemesisTxOriginBeneficiaryMisrouteTest is Test {
    uint256 internal constant PROJECT_ID = 1;

    MockAuditDirectory internal directory;
    RecordingTerminal internal terminal;
    JBProjectPayerDeployer internal deployer;
    IJBProjectPayer internal payer;
    TreasuryForwarder internal treasury;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        directory = new MockAuditDirectory();
        terminal = new RecordingTerminal();
        treasury = new TreasuryForwarder();

        directory.setPrimaryTerminalOf(PROJECT_ID, JBConstants.NATIVE_TOKEN, address(terminal));

        deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
        payer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(address(0)),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });
    }

    /// @notice After L-18 fix: receive() uses msg.sender, so the funding contract gets tokens, not tx.origin.
    function test_ReceivePath_MintsToFundingContractNotTxOrigin() public {
        vm.deal(address(treasury), 1 ether);

        vm.prank(relayer, relayer);
        treasury.forwardViaReceive(payable(address(payer)));

        assertEq(terminal.lastAmount(), 1 ether);
        // After fix: beneficiary is the funding contract (msg.sender), not the relayer (tx.origin).
        assertEq(terminal.lastBeneficiary(), address(treasury));
        assertTrue(terminal.lastBeneficiary() != relayer);
    }

    /// @notice After L-18 fix: pay() uses msg.sender, so the funding contract gets tokens, not tx.origin.
    function test_PayPath_MintsToFundingContractNotTxOrigin() public {
        vm.deal(address(treasury), 2 ether);

        vm.prank(relayer, relayer);
        treasury.forwardViaPay(payer, PROJECT_ID);

        assertEq(terminal.lastAmount(), 2 ether);
        // After fix: beneficiary is the funding contract (msg.sender), not the relayer (tx.origin).
        assertEq(terminal.lastBeneficiary(), address(treasury));
        assertTrue(terminal.lastBeneficiary() != relayer);
    }

    /// @notice Safe/multisig scenario: contract caller gets tokens, not the EOA signer.
    function test_SafeMultisigScenario_ContractCallerGetsTokens() public {
        // The treasury acts like a Safe multisig wallet.
        vm.deal(address(treasury), 3 ether);

        // The relayer is the EOA signer who submits the tx.
        vm.prank(relayer, relayer);
        treasury.forwardViaReceive(payable(address(payer)));

        assertEq(terminal.lastAmount(), 3 ether);
        // The multisig (treasury) should get the tokens, not the signer (relayer).
        assertEq(terminal.lastBeneficiary(), address(treasury));
    }
}
