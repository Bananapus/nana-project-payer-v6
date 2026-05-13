// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Exposes the original payer of a forwarded transaction.
/// @dev Implemented by intermediaries (e.g. `JBProjectPayer`, `JBRouterTerminalRegistry`) that forward calls on
/// behalf of a user. Downstream router terminals query this to refund partial-fill leftovers and resolve credit
/// cash-outs against the true payer instead of the intermediary contract.
interface IJBPayerTracker {
    /// @notice The original payer of the current transaction.
    /// @return payer The original payer address, or `address(0)` if no forwarding is in progress.
    function originalPayer() external view returns (address payer);
}
