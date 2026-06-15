// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";

contract TrackerRedirectDirectory {
    mapping(uint256 => mapping(address => address)) internal _primaryTerminalOf;

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return IJBTerminal(_primaryTerminalOf[projectId][token]);
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, address terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }
}

contract TrackerRedirectTerminal {
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

/// @notice A tracker-aware forwarder like `JBProjects`: advertises a fixed original payer via `IJBPayerTracker` and
/// forwards received ETH into the payer's `receive()`.
contract AdvertisingForwarder is IJBPayerTracker {
    address public override originalPayer;

    function forward(address payable payer, address payerToAdvertise) external payable {
        originalPayer = payerToAdvertise;
        (bool ok,) = payer.call{value: msg.value}("");
        require(ok, "FORWARD_FAILED");
        originalPayer = address(0);
    }
}

    /// @notice A plain forwarder that does NOT implement `IJBPayerTracker` — the probe reverts and falls back to it.
    contract PlainForwarder {
        function forward(address payable payer) external payable {
            (bool ok,) = payer.call{value: msg.value}("");
            require(ok, "FORWARD_FAILED");
        }
    }

    /// @notice Option 4: when the fee receiver routes via `pay` with no default beneficiary, the beneficiary resolves
    /// to
    /// the original payer the immediate caller advertises through `IJBPayerTracker` — so a `JBProjects`-style
    /// forwarder
    /// that reports the new project's owner credits that owner. A non-tracker caller still falls back to itself,
    /// preserving the anti-`tx.origin` misroute guard (`RegressionTxOriginBeneficiaryMisroute`).
    contract TrackerBeneficiaryRedirectTest is Test {
        uint256 internal constant PROJECT_ID = 1;

        TrackerRedirectDirectory internal directory;
        TrackerRedirectTerminal internal terminal;
        IJBProjectPayer internal payer;

        function setUp() public {
            directory = new TrackerRedirectDirectory();
            terminal = new TrackerRedirectTerminal();
            directory.setPrimaryTerminalOf(PROJECT_ID, JBConstants.NATIVE_TOKEN, address(terminal));

            JBProjectPayerDeployer deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
            payer = deployer.deployProjectPayer({
                defaultProjectId: PROJECT_ID,
                defaultBeneficiary: payable(address(0)),
                defaultMemo: "",
                defaultMetadata: "",
                defaultAddToBalance: false,
                owner: makeAddr("owner")
            });
        }

        function test_TrackerCallerRedirectsBeneficiaryToAdvertisedPayer() public {
            address projectOwner = makeAddr("projectOwner");
            AdvertisingForwarder forwarder = new AdvertisingForwarder();

            vm.deal(address(this), 1 ether);
            forwarder.forward{value: 1 ether}(payable(address(payer)), projectOwner);

            assertEq(terminal.lastAmount(), 1 ether);
            // The beneficiary follows the advertised original payer, not the forwarder contract.
            assertEq(terminal.lastBeneficiary(), projectOwner, "beneficiary must follow the advertised original payer");
            assertNotEq(terminal.lastBeneficiary(), address(forwarder));
        }

        function test_NonTrackerCallerKeepsImmediateCallerAsBeneficiary() public {
            PlainForwarder forwarder = new PlainForwarder();

            vm.deal(address(this), 1 ether);
            forwarder.forward{value: 1 ether}(payable(address(payer)));

            assertEq(terminal.lastAmount(), 1 ether);
            // A non-tracker caller falls back to itself — the anti-tx.origin misroute guard is preserved.
            assertEq(terminal.lastBeneficiary(), address(forwarder), "non-tracker caller must remain the beneficiary");
        }
    }
