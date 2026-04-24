// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";

contract MockForcedEthDirectory {
    mapping(uint256 => mapping(address => address)) internal _primaryTerminalOf;

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return IJBTerminal(_primaryTerminalOf[projectId][token]);
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, address terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }
}

contract RecordingNativeTerminal {
    address public lastBeneficiary;
    uint256 public lastAmount;
    uint256 public payCount;
    uint256 public addToBalanceCount;

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
        payCount++;
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256 amount, bool, string calldata, bytes calldata) external payable {
        lastAmount = amount;
        addToBalanceCount++;
    }
}

contract ForceEther {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract CodexNemesisForcedEthSweepTest is Test {
    uint256 internal constant PROJECT_ID = 1;

    MockForcedEthDirectory internal directory;
    RecordingNativeTerminal internal terminal;
    JBProjectPayerDeployer internal deployer;

    address internal owner = makeAddr("owner");
    address internal attackerBeneficiary = makeAddr("attackerBeneficiary");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        directory = new MockForcedEthDirectory();
        terminal = new RecordingNativeTerminal();
        deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));

        directory.setPrimaryTerminalOf(PROJECT_ID, JBConstants.NATIVE_TOKEN, address(terminal));
    }

    function test_Receive_ForwardsOnlyMsgValueViaPay() public {
        IJBProjectPayer payer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(attackerBeneficiary),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });

        // Force-feed 1 ether into the payer via selfdestruct.
        new ForceEther{value: 1 ether}(payable(address(payer)));
        assertEq(address(payer).balance, 1 ether);

        // Send 1 wei via receive().
        vm.deal(attacker, 1 wei);
        vm.prank(attacker, attacker);
        (bool success,) = payable(address(payer)).call{value: 1 wei}("");
        assertTrue(success);

        // Only msg.value (1 wei) is forwarded — the force-fed ETH is not swept.
        assertEq(terminal.payCount(), 1);
        assertEq(terminal.lastBeneficiary(), attackerBeneficiary);
        assertEq(terminal.lastAmount(), 1 wei);
        assertEq(address(payer).balance, 1 ether);
    }

    function test_Receive_ForwardsOnlyMsgValueViaAddToBalance() public {
        IJBProjectPayer payer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(address(0)),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: true,
            owner: owner
        });

        // Force-feed 2 ether into the payer via selfdestruct.
        new ForceEther{value: 2 ether}(payable(address(payer)));
        assertEq(address(payer).balance, 2 ether);

        // Send 1 wei via receive().
        vm.deal(attacker, 1 wei);
        vm.prank(attacker, attacker);
        (bool success,) = payable(address(payer)).call{value: 1 wei}("");
        assertTrue(success);

        // Only msg.value (1 wei) is forwarded — the force-fed ETH stays in the contract.
        assertEq(terminal.addToBalanceCount(), 1);
        assertEq(terminal.lastAmount(), 1 wei);
        assertEq(address(payer).balance, 2 ether);
    }
}
