// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayer} from "../src/JBProjectPayer.sol";
import {JBProjectPayerDeployer} from "../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../src/interfaces/IJBProjectPayer.sol";
import {IJBProjectPayerDeployer} from "../src/interfaces/IJBProjectPayerDeployer.sol";

/// @notice A mock directory that returns configurable primary terminals.
contract MockJBDirectory2 {
    mapping(uint256 => mapping(address => address)) private _primaryTerminals;

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return IJBTerminal(_primaryTerminals[projectId][token]);
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, address terminal) external {
        _primaryTerminals[projectId][token] = terminal;
    }
}

/// @notice A mock terminal that accepts payments.
contract MockJBTerminal2 {
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract JBProjectPayerDeployer_Unit is Test {
    MockJBDirectory2 directory;
    MockJBTerminal2 terminal;
    JBProjectPayerDeployer deployer;

    address owner = makeAddr("owner");
    address beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = new MockJBDirectory2();
        terminal = new MockJBTerminal2();
        directory.setPrimaryTerminalOf(1, JBConstants.NATIVE_TOKEN, address(terminal));
        deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
    }

    //*********************************************************************//
    // ----------------------- constructor tests ------------------------- //
    //*********************************************************************//

    function test_Constructor_SetsImplementation() public view {
        assertTrue(deployer.IMPLEMENTATION() != address(0));
        assertTrue(deployer.IMPLEMENTATION().code.length > 0);
    }

    function test_Constructor_SetsDirectory() public view {
        assertEq(address(deployer.DIRECTORY()), address(directory));
    }

    //*********************************************************************//
    // -------------------- deployProjectPayer tests ---------------------- //
    //*********************************************************************//

    function test_DeployProjectPayer_ReturnsInitializedPayer() public {
        IJBProjectPayer projectPayer = deployer.deployProjectPayer({
            defaultProjectId: 1,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: "hello",
            defaultMetadata: hex"cafe",
            defaultAddToBalance: false,
            owner: owner
        });

        assertTrue(address(projectPayer) != address(0));
        assertEq(projectPayer.defaultProjectId(), 1);
        assertEq(projectPayer.defaultBeneficiary(), beneficiary);
        assertEq(keccak256(bytes(projectPayer.defaultMemo())), keccak256("hello"));
        assertEq(keccak256(projectPayer.defaultMetadata()), keccak256(hex"cafe"));
        assertFalse(projectPayer.defaultAddToBalance());
        assertEq(JBProjectPayer(payable(address(projectPayer))).owner(), owner);
    }

    function test_DeployProjectPayer_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IJBProjectPayerDeployer.DeployProjectPayer({
            projectPayer: IJBProjectPayer(payable(address(0))), // Can't predict address.
            defaultProjectId: 1,
            defaultBeneficiary: beneficiary,
            defaultMemo: "hello",
            defaultMetadata: hex"cafe",
            defaultAddToBalance: false,
            directory: IJBDirectory(address(directory)),
            owner: owner,
            caller: address(this)
        });

        deployer.deployProjectPayer({
            defaultProjectId: 1,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: "hello",
            defaultMetadata: hex"cafe",
            defaultAddToBalance: false,
            owner: owner
        });
    }

    function test_DeployProjectPayer_SharesImmutables() public {
        IJBProjectPayer projectPayer = deployer.deployProjectPayer({
            defaultProjectId: 1,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });

        // All clones share the same directory and deployer.
        assertEq(address(projectPayer.DIRECTORY()), address(directory));
        assertEq(projectPayer.DEPLOYER(), address(deployer));
    }

    function test_DeployMultiple_Independent() public {
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");
        address beneficiary1 = makeAddr("beneficiary1");
        address beneficiary2 = makeAddr("beneficiary2");

        IJBProjectPayer payer1 = deployer.deployProjectPayer({
            defaultProjectId: 1,
            defaultBeneficiary: payable(beneficiary1),
            defaultMemo: "payer1",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner1
        });

        IJBProjectPayer payer2 = deployer.deployProjectPayer({
            defaultProjectId: 2,
            defaultBeneficiary: payable(beneficiary2),
            defaultMemo: "payer2",
            defaultMetadata: "",
            defaultAddToBalance: true,
            owner: owner2
        });

        // Different addresses.
        assertTrue(address(payer1) != address(payer2));

        // Different defaults.
        assertEq(payer1.defaultProjectId(), 1);
        assertEq(payer2.defaultProjectId(), 2);
        assertEq(payer1.defaultBeneficiary(), beneficiary1);
        assertEq(payer2.defaultBeneficiary(), beneficiary2);
        assertFalse(payer1.defaultAddToBalance());
        assertTrue(payer2.defaultAddToBalance());

        // Different owners.
        assertEq(JBProjectPayer(payable(address(payer1))).owner(), owner1);
        assertEq(JBProjectPayer(payable(address(payer2))).owner(), owner2);
    }

    function test_DeployProjectPayer_ClonesArePayable() public {
        IJBProjectPayer projectPayer = deployer.deployProjectPayer({
            defaultProjectId: 1,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });

        // The clone should accept ETH.
        vm.deal(address(this), 1 ether);
        (bool success,) = address(projectPayer).call{value: 1 ether}("");
        assertTrue(success);
    }

    function test_DeployProjectPayer_WithZeroBeneficiary() public {
        IJBProjectPayer projectPayer = deployer.deployProjectPayer({
            defaultProjectId: 1,
            defaultBeneficiary: payable(address(0)),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });

        assertEq(projectPayer.defaultBeneficiary(), address(0));
    }

    function test_DeployProjectPayer_WithAddToBalance() public {
        IJBProjectPayer projectPayer = deployer.deployProjectPayer({
            defaultProjectId: 1,
            defaultBeneficiary: payable(beneficiary),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: true,
            owner: owner
        });

        assertTrue(projectPayer.defaultAddToBalance());
    }
}
