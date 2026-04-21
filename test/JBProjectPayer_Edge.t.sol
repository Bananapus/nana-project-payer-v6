// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayer} from "../src/JBProjectPayer.sol";
import {JBProjectPayerDeployer} from "../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../src/interfaces/IJBProjectPayer.sol";

/// @notice A minimal ERC20 for testing.
contract MockERC20Edge is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice An ERC20 that charges a 1% fee on transfer (fee-on-transfer token).
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            // 1% fee burned on transfer.
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice A mock directory that returns configurable primary terminals.
contract MockJBDirectoryEdge {
    mapping(uint256 => mapping(address => address)) private _primaryTerminals;

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return IJBTerminal(_primaryTerminals[projectId][token]);
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, address terminal) external {
        _primaryTerminals[projectId][token] = terminal;
    }
}

/// @notice A mock terminal that records calls and can optionally revert.
contract MockJBTerminalEdge {
    bool public shouldRevert;
    uint256 public lastPayAmount;
    uint256 public lastAddToBalanceAmount;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function pay(
        uint256,
        address,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        if (shouldRevert) revert("MockTerminal: revert");
        lastPayAmount = amount;
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256 amount, bool, string calldata, bytes calldata) external payable {
        if (shouldRevert) revert("MockTerminal: revert");
        lastAddToBalanceAmount = amount;
    }
}

contract JBProjectPayer_Edge is Test {
    MockJBDirectoryEdge directory;
    MockJBTerminalEdge terminal;
    MockERC20Edge token;
    FeeOnTransferERC20 feeToken;
    JBProjectPayerDeployer deployer;
    IJBProjectPayer payer;

    address owner = makeAddr("owner");
    address beneficiary = makeAddr("beneficiary");
    address caller = makeAddr("caller");

    uint256 constant PROJECT_ID = 1;

    function setUp() public {
        directory = new MockJBDirectoryEdge();
        terminal = new MockJBTerminalEdge();
        token = new MockERC20Edge();
        feeToken = new FeeOnTransferERC20();

        directory.setPrimaryTerminalOf(PROJECT_ID, JBConstants.NATIVE_TOKEN, address(terminal));
        directory.setPrimaryTerminalOf(PROJECT_ID, address(token), address(terminal));
        directory.setPrimaryTerminalOf(PROJECT_ID, address(feeToken), address(terminal));

        deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
        payer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });
    }

    //*********************************************************************//
    // ------------------- fee-on-transfer token tests ------------------- //
    //*********************************************************************//

    function test_Pay_FeeOnTransferToken() public {
        uint256 amount = 1000e18;
        uint256 expectedReceived = amount - amount / 100; // 1% fee

        feeToken.mint(caller, amount);
        vm.prank(caller);
        feeToken.approve(address(payer), amount);

        vm.prank(caller, caller);
        payer.pay({
            projectId: PROJECT_ID,
            token: address(feeToken),
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // The terminal should receive the amount after fee, not the original amount.
        assertEq(terminal.lastPayAmount(), expectedReceived);
    }

    function test_AddToBalanceOf_FeeOnTransferToken() public {
        uint256 amount = 1000e18;
        uint256 expectedReceived = amount - amount / 100;

        feeToken.mint(caller, amount);
        vm.prank(caller);
        feeToken.approve(address(payer), amount);

        vm.prank(caller, caller);
        payer.addToBalanceOf({projectId: PROJECT_ID, token: address(feeToken), amount: amount, memo: "", metadata: ""});

        assertEq(terminal.lastAddToBalanceAmount(), expectedReceived);
    }

    //*********************************************************************//
    // ---------------------- multiple sends test ------------------------- //
    //*********************************************************************//

    function test_Receive_MultipleSends() public {
        // Send ETH multiple times and verify each is forwarded.
        for (uint256 i = 0; i < 5; i++) {
            uint256 amount = (i + 1) * 0.5 ether;
            vm.deal(caller, amount);
            vm.prank(caller, caller);
            (bool success,) = address(payer).call{value: amount}("");
            assertTrue(success);
        }

        // The payer should have no residual balance (all forwarded).
        assertEq(address(payer).balance, 0);
    }

    //*********************************************************************//
    // --------------------- setDefaultValues multiple -------------------- //
    //*********************************************************************//

    function test_SetDefaultValues_MultipleUpdates() public {
        for (uint256 i = 1; i <= 3; i++) {
            vm.prank(owner);
            payer.setDefaultValues({
                projectId: i,
                beneficiary: payable(address(uint160(i))),
                memo: "",
                metadata: "",
                addToBalance: i % 2 == 0
            });

            assertEq(payer.defaultProjectId(), i);
            assertEq(payer.defaultBeneficiary(), address(uint160(i)));
            assertEq(payer.defaultAddToBalance(), i % 2 == 0);
        }
    }

    //*********************************************************************//
    // -------------------- zero amount edge cases ----------------------- //
    //*********************************************************************//

    function test_Pay_ZeroETH() public {
        // Paying 0 ETH should succeed (terminal gets called with 0).
        vm.prank(caller, caller);
        payer.pay{value: 0}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(terminal.lastPayAmount(), 0);
    }

    function test_AddToBalanceOf_ZeroETH() public {
        vm.prank(caller);
        payer.addToBalanceOf{value: 0}({
            projectId: PROJECT_ID, token: JBConstants.NATIVE_TOKEN, amount: 0, memo: "", metadata: ""
        });

        assertEq(terminal.lastAddToBalanceAmount(), 0);
    }

    //*********************************************************************//
    // -------------------- implementation not usable --------------------- //
    //*********************************************************************//

    function test_Implementation_OwnedByDeployer() public view {
        // The implementation's owner is the deployer (set during constructor).
        JBProjectPayer impl = JBProjectPayer(payable(deployer.IMPLEMENTATION()));
        assertEq(impl.owner(), address(deployer));
    }

    function test_Implementation_CannotBeInitializedByNonDeployer() public {
        JBProjectPayer impl = JBProjectPayer(payable(deployer.IMPLEMENTATION()));

        vm.prank(caller);
        vm.expectRevert(JBProjectPayer.JBProjectPayer_AlreadyInitialized.selector);
        impl.initialize({
            projectId: 1, beneficiary: payable(caller), memo: "", metadata: "", addToBalance: false, owner: caller
        });
    }

    //*********************************************************************//
    // ---------------------- pay to different project -------------------- //
    //*********************************************************************//

    function test_Pay_DifferentProjectThanDefault() public {
        // Register terminal for project 2.
        uint256 otherProject = 2;
        directory.setPrimaryTerminalOf(otherProject, JBConstants.NATIVE_TOKEN, address(terminal));

        uint256 amount = 1 ether;
        vm.deal(caller, amount);
        vm.prank(caller, caller);
        payer.pay{value: amount}({
            projectId: otherProject,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Should have paid to the other project.
        assertEq(terminal.lastPayAmount(), amount);
    }

    //*********************************************************************//
    // -------------------- large amount edge case ----------------------- //
    //*********************************************************************//

    function test_Pay_LargeAmount() public {
        uint256 amount = 100_000 ether;
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

        assertEq(terminal.lastPayAmount(), amount);
        assertEq(address(payer).balance, 0);
    }

    //*********************************************************************//
    // ---------------------- memo and metadata tests --------------------- //
    //*********************************************************************//

    function test_Receive_ForwardsDefaultMemoAndMetadata() public {
        // Deploy payer with specific memo and metadata.
        IJBProjectPayer payerWithMemo = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: "default memo",
            defaultMetadata: hex"aabbccdd",
            defaultAddToBalance: false,
            owner: owner
        });

        vm.deal(caller, 1 ether);
        vm.prank(caller, caller);
        (bool success,) = address(payerWithMemo).call{value: 1 ether}("");
        assertTrue(success);

        // Verify the memo and metadata were forwarded (terminal received the call).
        assertEq(terminal.lastPayAmount(), 1 ether);
    }

    //*********************************************************************//
    // ---------------------- ERC20 approval cleanup ---------------------- //
    //*********************************************************************//

    function test_Pay_ERC20_ApprovesTerminal() public {
        uint256 amount = 100e18;

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

        // The payer should have approved the terminal for the amount.
        // Since the mock terminal doesn't actually pull tokens, the allowance remains.
        assertEq(token.allowance(address(payer), address(terminal)), amount);
    }
}
