// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";
import {JBProjectPayer} from "../../src/JBProjectPayer.sol";

/// @notice Exposes ProjectPayer's internal original-payer resolver without touching production code.
contract JBProjectPayerTrackerHarness is JBProjectPayer {
    constructor() JBProjectPayer(IJBDirectory(address(1))) {}

    /// @notice Returns the payer identity that would be written before forwarding to a terminal.
    function exposedOriginalPayerOrSender() external view returns (address) {
        return _originalPayerOrSender();
    }
}

/// @notice Calls the harness from a constructor, where `address(this).code.length == 0`.
contract ConstructorCaller {
    address public observed;

    constructor(JBProjectPayerTrackerHarness harness) {
        observed = harness.exposedOriginalPayerOrSender();
    }
}

/// @notice Contract caller with no tracker interface.
contract NonTrackerCaller {
    function probe(JBProjectPayerTrackerHarness harness) external view returns (address) {
        return harness.exposedOriginalPayerOrSender();
    }
}

/// @notice Tracker-shaped caller whose getter reverts.
contract RevertingTrackerCaller {
    function originalPayer() external pure returns (address) {
        revert();
    }

    function probe(JBProjectPayerTrackerHarness harness) external view returns (address) {
        return harness.exposedOriginalPayerOrSender();
    }
}

/// @notice Well-formed tracker caller with a configurable upstream payer.
contract ConfigurableTrackerCaller is IJBPayerTracker {
    address public override originalPayer;

    function setOriginalPayer(address payer) external {
        originalPayer = payer;
    }

    function probe(JBProjectPayerTrackerHarness harness) external view returns (address) {
        return harness.exposedOriginalPayerOrSender();
    }
}

    /// @notice Halmos entrypoints for ProjectPayer's forwarded-payer identity rules.
    /// @dev Router-style terminals rely on these rules to refund partial-fill leftovers to the true payer, while
    /// malformed or zero-valued trackers must fall back to the direct caller instead of bubbling failures.
    contract JBProjectPayerHalmos {
        /// @notice Proves constructor-time callers, which have no deployed code yet, are treated as direct payers.
        function check_constructorCallerWithoutCodeFallsBackToSender() public {
            JBProjectPayerTrackerHarness harness = new JBProjectPayerTrackerHarness();
            ConstructorCaller caller = new ConstructorCaller(harness);

            assert(caller.observed() == address(caller));
        }

        /// @notice Proves callers with no tracker interface are treated as direct payers.
        function check_nonTrackerCallerFallsBackToSender() public {
            JBProjectPayerTrackerHarness harness = new JBProjectPayerTrackerHarness();
            NonTrackerCaller caller = new NonTrackerCaller();

            assert(caller.probe(harness) == address(caller));
        }

        /// @notice Proves a reverting tracker probe cannot block forwarding identity resolution.
        function check_revertingTrackerFallsBackToSender() public {
            JBProjectPayerTrackerHarness harness = new JBProjectPayerTrackerHarness();
            RevertingTrackerCaller caller = new RevertingTrackerCaller();

            assert(caller.probe(harness) == address(caller));
        }

        /// @notice Proves malformed tracker return data is ignored instead of decoded.
        function check_truncatedTrackerFallsBackToSender() public {
            JBProjectPayerTrackerHarness harness = new JBProjectPayerTrackerHarness();
            TruncatedTrackerCaller caller = new TruncatedTrackerCaller();

            assert(caller.probe(harness) == address(caller));
        }

        /// @notice Proves a zero upstream tracker value means "no upstream payer", so the direct caller is used.
        function check_zeroUpstreamTrackerFallsBackToSender() public {
            JBProjectPayerTrackerHarness harness = new JBProjectPayerTrackerHarness();
            ConfigurableTrackerCaller caller = new ConfigurableTrackerCaller();

            caller.setOriginalPayer(address(0));

            assert(caller.probe(harness) == address(caller));
        }

        /// @notice Proves a non-zero upstream tracker value is propagated through this payer.
        function check_nonZeroUpstreamTrackerIsPropagated(address upstream) public {
            if (upstream == address(0)) return;

            JBProjectPayerTrackerHarness harness = new JBProjectPayerTrackerHarness();
            ConfigurableTrackerCaller caller = new ConfigurableTrackerCaller();

            caller.setOriginalPayer(upstream);

            assert(caller.probe(harness) == upstream);
        }

        /// @notice Proves the ERC-165 surface advertises exactly the payer, tracker, and base ERC-165 interfaces.
        function check_supportsExpectedInterfaces(bytes4 interfaceId) public {
            JBProjectPayerTrackerHarness harness = new JBProjectPayerTrackerHarness();

            bool expected = interfaceId == type(IJBProjectPayer).interfaceId
                || interfaceId == type(IJBPayerTracker).interfaceId || interfaceId == type(IERC165).interfaceId;

            assert(harness.supportsInterface(interfaceId) == expected);
        }
    }

    /// @notice Caller that returns fewer than 32 bytes for the tracker selector.
    contract TruncatedTrackerCaller {
        function probe(JBProjectPayerTrackerHarness harness) external view returns (address) {
            return harness.exposedOriginalPayerOrSender();
        }

        fallback() external {
            // The payer resolver must treat malformed tracker return data the same way as a missing tracker.
            assembly {
                mstore(0, 1)
                return(0, 31)
            }
        }
    }
