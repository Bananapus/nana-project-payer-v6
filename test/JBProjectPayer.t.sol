// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayer} from "../src/JBProjectPayer.sol";
import {IJBProjectPayer} from "../src/interfaces/IJBProjectPayer.sol";
import {JBProjectPayerDeployer} from "../src/JBProjectPayerDeployer.sol";

/// @notice A minimal ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A mock directory that returns configurable primary terminals.
contract MockJBDirectory {
    mapping(uint256 => mapping(address => address)) private _primaryTerminals;

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return IJBTerminal(_primaryTerminals[projectId][token]);
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, address terminal) external {
        _primaryTerminals[projectId][token] = terminal;
    }
}

/// @notice A mock terminal that records all pay and addToBalanceOf calls.
contract MockJBTerminal {
    struct PayRecord {
        uint256 projectId;
        address token;
        uint256 amount;
        address beneficiary;
        uint256 minReturnedTokens;
        string memo;
        bytes metadata;
    }

    struct AddToBalanceRecord {
        uint256 projectId;
        address token;
        uint256 amount;
        bool shouldReturnHeldFees;
        string memo;
        bytes metadata;
    }

    PayRecord[] public payRecords;
    AddToBalanceRecord[] public addToBalanceRecords;

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
        payable
        returns (uint256)
    {
        payRecords.push(PayRecord(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata));
        return 0;
    }

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
    {
        addToBalanceRecords.push(AddToBalanceRecord(projectId, token, amount, shouldReturnHeldFees, memo, metadata));
    }

    function payRecordCount() external view returns (uint256) {
        return payRecords.length;
    }

    function addToBalanceRecordCount() external view returns (uint256) {
        return addToBalanceRecords.length;
    }
}

contract JBProjectPayer_Unit is Test {
    MockJBDirectory directory;
    MockJBTerminal terminal;
    MockERC20 token;
    JBProjectPayerDeployer deployer;
    IJBProjectPayer payer;

    address owner = makeAddr("owner");
    address beneficiary = makeAddr("beneficiary");
    address caller = makeAddr("caller");

    uint256 constant PROJECT_ID = 1;
    string constant MEMO = "test memo";
    bytes constant METADATA = "";

    function setUp() public {
        // Deploy mock infrastructure.
        directory = new MockJBDirectory();
        terminal = new MockJBTerminal();
        token = new MockERC20();

        // Register the terminal as the primary terminal for project 1, native token.
        directory.setPrimaryTerminalOf(PROJECT_ID, JBConstants.NATIVE_TOKEN, address(terminal));

        // Register the terminal for the mock ERC20 too.
        directory.setPrimaryTerminalOf(PROJECT_ID, address(token), address(terminal));

        // Deploy the deployer and a project payer via the deployer.
        deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
        payer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: MEMO,
            defaultMetadata: METADATA,
            defaultAddToBalance: false,
            owner: owner
        });
    }

    //*********************************************************************//
    // ----------------------- initialization tests ---------------------- //
    //*********************************************************************//

    function test_Initialize_SetsDefaults() public view {
        assertEq(payer.defaultProjectId(), PROJECT_ID);
        assertEq(payer.defaultBeneficiary(), beneficiary);
        assertEq(keccak256(bytes(payer.defaultMemo())), keccak256(bytes(MEMO)));
        assertEq(keccak256(payer.defaultMetadata()), keccak256(METADATA));
        assertFalse(payer.defaultAddToBalance());
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(JBProjectPayer(payable(address(payer))).owner(), owner);
    }

    function test_Initialize_SetsImmutables() public view {
        assertEq(address(payer.DIRECTORY()), address(directory));
        assertEq(payer.DEPLOYER(), address(deployer));
    }

    function test_RevertWhen_Initialize_NotDeployer() public {
        // Try to call initialize directly on the payer (not from deployer).
        vm.prank(caller);
        vm.expectRevert(JBProjectPayer.JBProjectPayer_AlreadyInitialized.selector);
        payer.initialize({
            projectId: 2, beneficiary: payable(caller), memo: "", metadata: "", addToBalance: false, owner: caller
        });
    }

    //*********************************************************************//
    // ----------------------- supportsInterface ------------------------- //
    //*********************************************************************//

    function test_SupportsInterface_IJBProjectPayer() public view {
        assertTrue(payer.supportsInterface(type(IJBProjectPayer).interfaceId));
    }

    function test_SupportsInterface_IERC165() public view {
        assertTrue(payer.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterface_UnknownReturnsFalse() public view {
        assertFalse(payer.supportsInterface(0xdeadbeef));
    }

    //*********************************************************************//
    // ----------------------- receive ETH tests ------------------------- //
    //*********************************************************************//

    function test_Receive_PayMode() public {
        uint256 amount = 1 ether;

        // Send ETH directly to the payer.
        vm.deal(caller, amount);
        vm.prank(caller, caller); // set both msg.sender and tx.origin
        (bool success,) = address(payer).call{value: amount}("");
        assertTrue(success);

        // Verify the terminal received a pay call.
        assertEq(terminal.payRecordCount(), 1);

        // Verify the pay call parameters.
        (
            uint256 recordedProjectId,
            address recordedToken,
            uint256 recordedAmount,
            address recordedBeneficiary,
            uint256 recordedMinReturned,,
        ) = terminal.payRecords(0);

        assertEq(recordedProjectId, PROJECT_ID);
        assertEq(recordedToken, JBConstants.NATIVE_TOKEN);
        assertEq(recordedAmount, amount);
        assertEq(recordedBeneficiary, beneficiary);
        assertEq(recordedMinReturned, 0);
    }

    function test_Receive_AddToBalanceMode() public {
        // Redeploy with addToBalance = true.
        IJBProjectPayer addToBalancePayer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: MEMO,
            defaultMetadata: METADATA,
            defaultAddToBalance: true,
            owner: owner
        });

        uint256 amount = 1 ether;
        vm.deal(caller, amount);
        vm.prank(caller, caller);
        (bool success,) = address(addToBalancePayer).call{value: amount}("");
        assertTrue(success);

        // Verify the terminal received an addToBalanceOf call.
        assertEq(terminal.addToBalanceRecordCount(), 1);

        (uint256 recordedProjectId, address recordedToken, uint256 recordedAmount, bool recordedReturnFees,,) =
            terminal.addToBalanceRecords(0);

        assertEq(recordedProjectId, PROJECT_ID);
        assertEq(recordedToken, JBConstants.NATIVE_TOKEN);
        assertEq(recordedAmount, amount);
        assertFalse(recordedReturnFees);
    }

    function test_Receive_BeneficiaryFallbackToTxOrigin() public {
        // Deploy payer with no default beneficiary.
        IJBProjectPayer noBeneficiaryPayer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(address(0)),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });

        uint256 amount = 1 ether;
        vm.deal(caller, amount);
        vm.prank(caller, caller);
        (bool success,) = address(noBeneficiaryPayer).call{value: amount}("");
        assertTrue(success);

        // Beneficiary should be tx.origin (caller).
        (,,, address recordedBeneficiary,,,) = terminal.payRecords(0);
        assertEq(recordedBeneficiary, caller);
    }

    //*********************************************************************//
    // ----------------------- pay function tests ------------------------ //
    //*********************************************************************//

    function test_Pay_ETH() public {
        uint256 amount = 2 ether;
        address payBeneficiary = makeAddr("payBeneficiary");

        vm.deal(caller, amount);
        vm.prank(caller, caller);
        payer.pay{value: amount}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0, // Ignored for native token.
            beneficiary: payBeneficiary,
            minReturnedTokens: 100,
            memo: "custom memo",
            metadata: ""
        });

        assertEq(terminal.payRecordCount(), 1);

        (
            uint256 recordedProjectId,
            address recordedToken,
            uint256 recordedAmount,
            address recordedBeneficiary,
            uint256 recordedMinReturned,,
        ) = terminal.payRecords(0);

        assertEq(recordedProjectId, PROJECT_ID);
        assertEq(recordedToken, JBConstants.NATIVE_TOKEN);
        assertEq(recordedAmount, amount);
        assertEq(recordedBeneficiary, payBeneficiary);
        assertEq(recordedMinReturned, 100);
    }

    function test_Pay_ERC20() public {
        uint256 amount = 1000e18;
        address payBeneficiary = makeAddr("payBeneficiary");

        // Mint tokens to caller and approve the payer.
        token.mint(caller, amount);
        vm.prank(caller);
        token.approve(address(payer), amount);

        vm.prank(caller, caller);
        payer.pay({
            projectId: PROJECT_ID,
            token: address(token),
            amount: amount,
            beneficiary: payBeneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(terminal.payRecordCount(), 1);

        (uint256 recordedProjectId, address recordedToken, uint256 recordedAmount, address recordedBeneficiary,,,) =
            terminal.payRecords(0);

        assertEq(recordedProjectId, PROJECT_ID);
        assertEq(recordedToken, address(token));
        assertEq(recordedAmount, amount);
        assertEq(recordedBeneficiary, payBeneficiary);
    }

    function test_Pay_BeneficiaryFallbackChain() public {
        // When beneficiary=address(0), should use defaultBeneficiary.
        uint256 amount = 1 ether;
        vm.deal(caller, amount);
        vm.prank(caller, caller);
        payer.pay{value: amount}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: address(0),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        (,,, address recordedBeneficiary,,,) = terminal.payRecords(0);
        assertEq(recordedBeneficiary, beneficiary); // defaultBeneficiary
    }

    function test_Pay_BeneficiaryFallbackToTxOrigin() public {
        // Deploy payer with no default beneficiary, then pay with beneficiary=address(0).
        IJBProjectPayer noBeneficiaryPayer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(address(0)),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });

        uint256 amount = 1 ether;
        vm.deal(caller, amount);
        vm.prank(caller, caller);
        noBeneficiaryPayer.pay{value: amount}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: address(0),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        (,,, address recordedBeneficiary,,,) = terminal.payRecords(0);
        assertEq(recordedBeneficiary, caller); // tx.origin
    }

    //*********************************************************************//
    // ------------------- addToBalanceOf function tests ------------------ //
    //*********************************************************************//

    function test_AddToBalanceOf_ETH() public {
        uint256 amount = 3 ether;

        vm.deal(caller, amount);
        vm.prank(caller);
        payer.addToBalanceOf{value: amount}({
            projectId: PROJECT_ID, token: JBConstants.NATIVE_TOKEN, amount: 0, memo: "balance memo", metadata: ""
        });

        assertEq(terminal.addToBalanceRecordCount(), 1);

        (uint256 recordedProjectId, address recordedToken, uint256 recordedAmount, bool recordedReturnFees,,) =
            terminal.addToBalanceRecords(0);

        assertEq(recordedProjectId, PROJECT_ID);
        assertEq(recordedToken, JBConstants.NATIVE_TOKEN);
        assertEq(recordedAmount, amount);
        assertFalse(recordedReturnFees);
    }

    function test_AddToBalanceOf_ERC20() public {
        uint256 amount = 500e18;

        token.mint(caller, amount);
        vm.prank(caller);
        token.approve(address(payer), amount);

        vm.prank(caller);
        payer.addToBalanceOf({projectId: PROJECT_ID, token: address(token), amount: amount, memo: "", metadata: ""});

        assertEq(terminal.addToBalanceRecordCount(), 1);

        (uint256 recordedProjectId, address recordedToken, uint256 recordedAmount,,,) = terminal.addToBalanceRecords(0);

        assertEq(recordedProjectId, PROJECT_ID);
        assertEq(recordedToken, address(token));
        assertEq(recordedAmount, amount);
    }

    //*********************************************************************//
    // ---------------------- setDefaultValues tests ---------------------- //
    //*********************************************************************//

    function test_SetDefaultValues() public {
        address payable newBeneficiary = payable(makeAddr("newBeneficiary"));
        uint256 newProjectId = 42;
        string memory newMemo = "new memo";
        bytes memory newMetadata = hex"deadbeef";

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IJBProjectPayer.SetDefaultValues({
            projectId: newProjectId,
            beneficiary: newBeneficiary,
            memo: newMemo,
            metadata: newMetadata,
            addToBalance: true,
            caller: owner
        });
        payer.setDefaultValues({
            projectId: newProjectId,
            beneficiary: newBeneficiary,
            memo: newMemo,
            metadata: newMetadata,
            addToBalance: true
        });

        assertEq(payer.defaultProjectId(), newProjectId);
        assertEq(payer.defaultBeneficiary(), newBeneficiary);
        assertEq(keccak256(bytes(payer.defaultMemo())), keccak256(bytes(newMemo)));
        assertEq(keccak256(payer.defaultMetadata()), keccak256(newMetadata));
        assertTrue(payer.defaultAddToBalance());
    }

    function test_RevertWhen_SetDefaultValues_NotOwner() public {
        vm.prank(caller);
        vm.expectRevert();
        payer.setDefaultValues({
            projectId: 2, beneficiary: payable(caller), memo: "", metadata: "", addToBalance: false
        });
    }

    //*********************************************************************//
    // ----------------------- revert condition tests --------------------- //
    //*********************************************************************//

    function test_RevertWhen_Pay_TerminalNotFound() public {
        // Try to pay a project with no terminal registered.
        uint256 unregisteredProject = 999;

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(JBProjectPayer.JBProjectPayer_TerminalNotFound.selector);
        payer.pay{value: 1 ether}({
            projectId: unregisteredProject,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: caller,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    function test_RevertWhen_Pay_ERC20WithMsgValue() public {
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(JBProjectPayer.JBProjectPayer_NoMsgValueAllowed.selector);
        payer.pay{value: 1 ether}({
            projectId: PROJECT_ID,
            token: address(token),
            amount: 100e18,
            beneficiary: caller,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    function test_RevertWhen_AddToBalance_TerminalNotFound() public {
        uint256 unregisteredProject = 999;

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(JBProjectPayer.JBProjectPayer_TerminalNotFound.selector);
        payer.addToBalanceOf{value: 1 ether}({
            projectId: unregisteredProject, token: JBConstants.NATIVE_TOKEN, amount: 0, memo: "", metadata: ""
        });
    }

    function test_RevertWhen_AddToBalance_ERC20WithMsgValue() public {
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(JBProjectPayer.JBProjectPayer_NoMsgValueAllowed.selector);
        payer.addToBalanceOf{value: 1 ether}({
            projectId: PROJECT_ID, token: address(token), amount: 100e18, memo: "", metadata: ""
        });
    }

    //*********************************************************************//
    // ----------------------- ownership tests --------------------------- //
    //*********************************************************************//

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        JBProjectPayer(payable(address(payer))).transferOwnership(newOwner);

        assertEq(JBProjectPayer(payable(address(payer))).owner(), newOwner);

        // New owner can set defaults.
        vm.prank(newOwner);
        payer.setDefaultValues({
            projectId: 99, beneficiary: payable(newOwner), memo: "", metadata: "", addToBalance: true
        });
        assertEq(payer.defaultProjectId(), 99);
    }

    function test_RenounceOwnership() public {
        vm.prank(owner);
        JBProjectPayer(payable(address(payer))).renounceOwnership();

        assertEq(JBProjectPayer(payable(address(payer))).owner(), address(0));

        // No one can set defaults anymore.
        vm.prank(owner);
        vm.expectRevert();
        payer.setDefaultValues({projectId: 2, beneficiary: payable(owner), memo: "", metadata: "", addToBalance: false});
    }

    //*********************************************************************//
    // ----------------------- fuzz tests -------------------------------- //
    //*********************************************************************//

    function testFuzz_Pay_ETH(uint96 amount) public {
        vm.assume(amount > 0);

        vm.deal(caller, amount);
        vm.prank(caller, caller);
        payer.pay{value: amount}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        (,, uint256 recordedAmount,,,,) = terminal.payRecords(terminal.payRecordCount() - 1);
        assertEq(recordedAmount, amount);
    }

    function testFuzz_Pay_ERC20(uint96 amount) public {
        vm.assume(amount > 0);

        token.mint(caller, amount);
        vm.prank(caller);
        token.approve(address(payer), amount);

        vm.prank(caller, caller);
        payer.pay({
            projectId: PROJECT_ID,
            token: address(token),
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        (,, uint256 recordedAmount,,,,) = terminal.payRecords(terminal.payRecordCount() - 1);
        assertEq(recordedAmount, amount);
    }

    function testFuzz_Receive_ETH(uint96 amount) public {
        vm.assume(amount > 0);

        vm.deal(caller, amount);
        vm.prank(caller, caller);
        (bool success,) = address(payer).call{value: amount}("");
        assertTrue(success);

        (,, uint256 recordedAmount,,,,) = terminal.payRecords(terminal.payRecordCount() - 1);
        assertEq(recordedAmount, amount);
    }
}
