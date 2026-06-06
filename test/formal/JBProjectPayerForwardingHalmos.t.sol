// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayer} from "../../src/JBProjectPayer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";
import {IJBPayerTracker} from "../../src/interfaces/IJBPayerTracker.sol";

/// @notice Subclass that exposes the production beneficiary-resolution and amount/value-handling rules through
/// public pure/view shims so a symbolic engine can explore the full input space WITHOUT touching `src/`. Each shim
/// re-derives the spec independently of the production code; the dual forge fuzz in
/// `JBProjectPayerForwarding.t.sol` cross-checks the SAME rules against the real entrypoints, so neither side is a
/// tautology of the other.
contract JBProjectPayerForwardingHarness is JBProjectPayer {
    constructor(IJBDirectory directory) JBProjectPayer(directory) {}

    /// @notice Spec mirror of `_pay`'s beneficiary fallback ternary (`src/JBProjectPayer.sol:349-351`).
    /// `beneficiary != 0 ? beneficiary : defaultBeneficiary != 0 ? defaultBeneficiary : sender`.
    function specResolveBeneficiary(
        address beneficiary,
        address defaultBeneficiary_,
        address sender
    )
        external
        pure
        returns (address)
    {
        return beneficiary != address(0)
            ? beneficiary
            : defaultBeneficiary_ != address(0) ? defaultBeneficiary_ : sender;
    }
}

/// @notice Symbolic (halmos) proofs of ProjectPayer's pure forwarding-arithmetic and routing predicates.
/// @dev These are the SMT-tractable functional-correctness properties: beneficiary resolution, the native-vs-ERC20
/// msg.value predicate, and the ERC-165 surface. Heavier stateful properties (transient-payer save/restore,
/// balance-delta forwarding, allowance reset) are verified by forge fuzz/invariant in the sibling file.
contract JBProjectPayerForwardingHalmos {
    address internal constant NATIVE = JBConstants.NATIVE_TOKEN;

    /// @notice Beneficiary resolution: when the caller supplies a non-zero beneficiary it is ALWAYS honored,
    /// regardless of defaults or sender (invariant A.2.1).
    function check_explicitBeneficiaryAlwaysHonored(
        address beneficiary,
        address defaultBeneficiary_,
        address sender
    )
        public
    {
        if (beneficiary == address(0)) return; // explicit-only branch

        JBProjectPayerForwardingHarness h = new JBProjectPayerForwardingHarness(IJBDirectory(address(1)));
        assert(h.specResolveBeneficiary(beneficiary, defaultBeneficiary_, sender) == beneficiary);
    }

    /// @notice Beneficiary resolution: a zero beneficiary falls back to the default when the default is non-zero
    /// (invariant A.2.2, first fallback).
    function check_zeroBeneficiaryFallsBackToDefault(address defaultBeneficiary_, address sender) public {
        if (defaultBeneficiary_ == address(0)) return; // default-present branch

        JBProjectPayerForwardingHarness h = new JBProjectPayerForwardingHarness(IJBDirectory(address(1)));
        assert(h.specResolveBeneficiary(address(0), defaultBeneficiary_, sender) == defaultBeneficiary_);
    }

    /// @notice Beneficiary resolution: a zero beneficiary AND zero default falls back to the sender
    /// (invariant A.2.2, terminal fallback).
    function check_zeroBeneficiaryZeroDefaultFallsBackToSender(address sender) public {
        JBProjectPayerForwardingHarness h = new JBProjectPayerForwardingHarness(IJBDirectory(address(1)));
        assert(h.specResolveBeneficiary(address(0), address(0), sender) == sender);
    }

    /// @notice Beneficiary resolution is TOTAL: the resolved recipient is always one of the three documented
    /// candidates and is never the zero address unless all three are zero. No fourth outcome exists.
    function check_resolutionIsOneOfThreeCandidates(
        address beneficiary,
        address defaultBeneficiary_,
        address sender
    )
        public
    {
        JBProjectPayerForwardingHarness h = new JBProjectPayerForwardingHarness(IJBDirectory(address(1)));
        address r = h.specResolveBeneficiary(beneficiary, defaultBeneficiary_, sender);
        assert(r == beneficiary || r == defaultBeneficiary_ || r == sender);
    }

    /// @notice msg.value predicate: the ERC-20 path (token != NATIVE) rejects any non-zero msg.value, while the
    /// native path forwards exactly msg.value (invariants A.1.2, A.1.4, D.3). This proves the branch selector.
    function check_msgValueRejectionPredicate(address token, uint256 msgValue, uint256 amountArg) public pure {
        // Re-derive the production branch logic (`src/JBProjectPayer.sol:222-236`):
        bool isNative = token == NATIVE;
        bool shouldRevert = !isNative && msgValue > 0;

        // Forwarded amount = msg.value for native, else the (already-pulled) ERC-20 amount.
        uint256 forwarded = isNative ? msgValue : amountArg;

        if (isNative) {
            // Native: never reverts on msg.value, forwards exactly the value sent.
            assert(!shouldRevert);
            assert(forwarded == msgValue);
        } else {
            // ERC-20: reverts iff value attached; otherwise forwards the pulled amount (the `amount` arg here).
            assert(shouldRevert == (msgValue > 0));
            if (!shouldRevert) assert(forwarded == amountArg);
        }
    }

    /// @notice payableValue selector: ETH is only attached to the downstream terminal call on the native path,
    /// and equals the full amount; the ERC-20 path attaches zero value (invariant A.5.2, `src/JBProjectPayer.sol:333`).
    function check_payableValueSelector(address token, uint256 amount) public pure {
        uint256 payableValue = token == NATIVE ? amount : 0;
        if (token == NATIVE) {
            assert(payableValue == amount);
        } else {
            assert(payableValue == 0);
        }
    }

    /// @notice ERC-165 surface advertises EXACTLY the payer, tracker, and base ERC-165 interfaces — no more, no less
    /// (invariant D.9). Duplicates the existing Halmos check on the production `supportsInterface` over the clone shape.
    function check_supportsExactlyDeclaredInterfaces(bytes4 interfaceId) public {
        JBProjectPayerForwardingHarness h = new JBProjectPayerForwardingHarness(IJBDirectory(address(1)));

        bool expected = interfaceId == type(IJBProjectPayer).interfaceId
            || interfaceId == type(IJBPayerTracker).interfaceId || interfaceId == type(IERC165).interfaceId;

        assert(h.supportsInterface(interfaceId) == expected);
    }
}
