// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayer} from "../../src/JBProjectPayer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";
import {IJBPayerTracker} from "../../src/interfaces/IJBPayerTracker.sol";
import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";

/// @notice Fee-on-transfer ERC-20: every `transferFrom`/`transfer` burns `feeBps`/10000 of the moved amount, so the
/// recipient nets less than the nominal value. Used to prove balance-delta accounting forwards the realized amount.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable FEE_BPS;

    constructor(uint256 feeBps) ERC20("Fee", "FEE") {
        FEE_BPS = feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && FEE_BPS > 0) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, address(0), fee); // burn the fee
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Plain mintable ERC-20.
contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Directory returning one configurable terminal.
contract FwdMockDirectory {
    IJBTerminal internal _terminal;

    function setTerminal(IJBTerminal terminal) external {
        _terminal = terminal;
    }

    function primaryTerminalOf(uint256, address) external view returns (IJBTerminal) {
        return _terminal;
    }
}

/// @notice Terminal that records the exact amount/beneficiary forwarded, and pulls a configurable FRACTION of the
/// approved ERC-20 amount (under-pull). It also records the `originalPayer()` it observed mid-call.
contract RecordingTerminal {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    address public lastBeneficiary;
    address public lastObservedPayer;
    uint256 public pullNumerator = 1; // pull pullNumerator/pullDenominator of the amount
    uint256 public pullDenominator = 1;

    function setPullFraction(uint256 num, uint256 den) external {
        pullNumerator = num;
        pullDenominator = den;
    }

    function _observePayer() internal {
        lastObservedPayer = address(0);
        if (msg.sender.code.length > 0) {
            try IJBPayerTracker(msg.sender).originalPayer() returns (address p) {
                lastObservedPayer = p;
            } catch {}
        }
    }

    function pay(
        uint256,
        address token,
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
        _observePayer();
        lastAmount = amount;
        lastBeneficiary = beneficiary;
        if (token != JBConstants.NATIVE_TOKEN && amount > 0) {
            uint256 toPull = (amount * pullNumerator) / pullDenominator;
            if (toPull > 0) IERC20(token).safeTransferFrom(msg.sender, address(this), toPull);
        }
        return 0;
    }

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        _observePayer();
        lastAmount = amount;
        if (token != JBConstants.NATIVE_TOKEN && amount > 0) {
            uint256 toPull = (amount * pullNumerator) / pullDenominator;
            if (toPull > 0) IERC20(token).safeTransferFrom(msg.sender, address(this), toPull);
        }
    }
}

/// @notice Terminal that re-enters the payer with a SECOND distinct payer call from a fresh sender, so we can prove
/// the transient `originalPayer` of the OUTER frame is restored after the inner forward returns (invariant A.3.1/D.4).
contract ReentrantTerminal {
    JBProjectPayer public payer;
    bool public reentered;
    address public innerObserved;
    address public outerObservedAfterReturn;

    function setPayer(JBProjectPayer p) external {
        payer = p;
    }

    function pay(
        uint256 projectId,
        address token,
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
        // First (outer) entry: read the originalPayer the payer set for us.
        address outerObserved = payer.originalPayer();

        if (!reentered) {
            reentered = true;
            // Re-enter the payer from THIS terminal as a new sender. The payer will set originalPayer to
            // _originalPayerOrSender() for the inner frame, then restore the outer value on return.
            payer.pay{value: token == JBConstants.NATIVE_TOKEN ? amount / 2 : 0}(
                projectId, token, token == JBConstants.NATIVE_TOKEN ? amount / 2 : amount, address(0xBEEF), 0, "", ""
            );
            // After the inner forward returns, the OUTER frame's originalPayer must be restored.
            outerObservedAfterReturn = payer.originalPayer();
            // Sanity: the outer value we saw at entry equals the restored value.
            require(outerObserved == outerObservedAfterReturn, "outer payer not restored");
        } else {
            // Inner entry: record what the payer advertised for the inner frame.
            innerObserved = payer.originalPayer();
        }
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract JBProjectPayerForwarding is Test {
    using SafeERC20 for IERC20;

    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("caller");
    address internal defaultBen = makeAddr("defaultBen");
    uint256 internal constant PROJECT = 1;

    function _deploy(
        IJBTerminal terminal,
        address defaultBeneficiary,
        bool addToBalance
    )
        internal
        returns (IJBProjectPayer payer, FwdMockDirectory dir)
    {
        dir = new FwdMockDirectory();
        dir.setTerminal(terminal);
        JBProjectPayerDeployer deployer = new JBProjectPayerDeployer(IJBDirectory(address(dir)));
        payer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT,
            defaultBeneficiary: payable(defaultBeneficiary),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: addToBalance,
            owner: owner
        });
    }

    // ------------------------------------------------------------------ //
    // A.1.3 / D.2 — balance-delta accounting forwards the REALIZED amount //
    // ------------------------------------------------------------------ //

    /// @notice For any fee-on-transfer rate, the amount forwarded to (and approved for) the terminal equals exactly
    /// what landed on the clone — never the nominal pull amount. Proves the payer cannot over-approve the terminal.
    function testFuzz_balanceDeltaForwardsRealizedAmount(uint96 nominal, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 9999));
        vm.assume(nominal > 0);

        FeeOnTransferToken token = new FeeOnTransferToken(feeBps);
        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);

        token.mint(caller, nominal);
        vm.startPrank(caller);
        token.approve(address(payer), nominal);
        payer.pay(PROJECT, address(token), nominal, caller, 0, "", "");
        vm.stopPrank();

        uint256 expectedRealized = nominal - (uint256(nominal) * feeBps) / 10_000;
        assertEq(term.lastAmount(), expectedRealized, "forwarded amount must equal realized (post-fee) amount");
        // No residual token stuck on the payer (terminal pulled the full realized amount at fraction 1/1).
        assertEq(token.balanceOf(address(payer)), 0, "no token residual on payer");
    }

    // ----------------------------------------------------------- //
    // A.5.1 / D.5 — allowance reset to 0 after every ERC-20 pull   //
    // ----------------------------------------------------------- //

    /// @notice After a forward where the terminal under-pulls any fraction of the approved amount, the residual
    /// allowance granted to the terminal is reset to zero. Defense against an under-pulling terminal.
    function testFuzz_allowanceResetAfterUnderPull(uint96 amount, uint8 pullPct) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        pullPct = uint8(bound(pullPct, 0, 100));

        PlainToken token = new PlainToken();
        RecordingTerminal term = new RecordingTerminal();
        term.setPullFraction(pullPct, 100);
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);

        token.mint(caller, amount);
        vm.startPrank(caller);
        token.approve(address(payer), amount);
        payer.pay(PROJECT, address(token), amount, caller, 0, "", "");
        vm.stopPrank();

        assertEq(token.allowance(address(payer), address(term)), 0, "terminal allowance must be reset to 0");
    }

    /// @notice Same allowance-reset guarantee on the addToBalanceOf path.
    function testFuzz_allowanceResetAfterUnderPull_addToBalance(uint96 amount, uint8 pullPct) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        pullPct = uint8(bound(pullPct, 0, 100));

        PlainToken token = new PlainToken();
        RecordingTerminal term = new RecordingTerminal();
        term.setPullFraction(pullPct, 100);
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);

        token.mint(caller, amount);
        vm.startPrank(caller);
        token.approve(address(payer), amount);
        payer.addToBalanceOf(PROJECT, address(token), amount, "", "");
        vm.stopPrank();

        assertEq(token.allowance(address(payer), address(term)), 0, "terminal allowance must be reset to 0");
    }

    // ------------------------------------------------------------- //
    // A.2.1 / A.2.2 — beneficiary resolution against the real _pay   //
    // ------------------------------------------------------------- //

    /// @notice Drives the production `pay` (native path) over the full beneficiary input space and asserts the
    /// terminal received exactly the spec-resolved beneficiary. Cross-checks the halmos pure-spec mirror.
    function testFuzz_beneficiaryResolution(
        address explicitBeneficiary,
        address defaultBeneficiary,
        uint96 amount
    )
        public
    {
        amount = uint96(bound(amount, 1, type(uint96).max));

        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBeneficiary, false);

        vm.deal(caller, amount);
        vm.prank(caller);
        payer.pay{value: amount}(PROJECT, JBConstants.NATIVE_TOKEN, 0, explicitBeneficiary, 0, "", "");

        address expected = explicitBeneficiary != address(0)
            ? explicitBeneficiary
            : defaultBeneficiary != address(0) ? defaultBeneficiary : caller;

        assertEq(term.lastBeneficiary(), expected, "beneficiary must follow explicit->default->sender chain");
    }

    // ------------------------------------------------------- //
    // A.1.2 / A.1.4 — native amount = msg.value; ERC-20 rejects msg.value //
    // ------------------------------------------------------- //

    /// @notice On the native path, the forwarded amount equals msg.value regardless of the `amount` arg passed.
    function testFuzz_nativeAmountIgnoresAmountArg(uint96 msgValue, uint96 amountArg) public {
        vm.assume(msgValue > 0);

        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);

        vm.deal(caller, msgValue);
        vm.prank(caller);
        payer.pay{value: msgValue}(PROJECT, JBConstants.NATIVE_TOKEN, amountArg, caller, 0, "", "");

        assertEq(term.lastAmount(), msgValue, "native path must forward msg.value, ignoring the amount arg");
    }

    /// @notice ERC-20 path reverts whenever any msg.value is attached, before pulling tokens.
    function testFuzz_erc20RejectsMsgValue(uint96 msgValue, uint96 amount) public {
        vm.assume(msgValue > 0);
        amount = uint96(bound(amount, 1, type(uint96).max));

        PlainToken token = new PlainToken();
        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);

        token.mint(caller, amount);
        vm.deal(caller, msgValue);
        vm.startPrank(caller);
        token.approve(address(payer), amount);
        vm.expectRevert(
            abi.encodeWithSelector(JBProjectPayer.JBProjectPayer_NoMsgValueAllowed.selector, msgValue, address(token))
        );
        payer.pay{value: msgValue}(PROJECT, address(token), amount, caller, 0, "", "");
        vm.stopPrank();
    }

    // -------------------------------------------------- //
    // A.3.1 / D.4 — transient originalPayer save/restore  //
    // -------------------------------------------------- //

    /// @notice A genuinely re-entrant terminal that calls back into the payer must see the OUTER frame's
    /// originalPayer restored after the inner forward returns (not left as the inner value, not zeroed mid-flight).
    /// The terminal's internal `require` asserts the restore; this test proves the inner frame saw a fresh value
    /// and the outer frame's value survived. Closes the gap the existing single-level nest test could not reach.
    function testFuzz_transientPayerRestoredAfterReentrancy(uint96 amount) public {
        amount = uint96(bound(amount, 2, type(uint96).max));

        ReentrantTerminal term = new ReentrantTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);
        term.setPayer(JBProjectPayer(payable(address(payer))));

        vm.deal(caller, amount);
        vm.prank(caller);
        // Outer call: caller is the EOA, so outer originalPayer == caller.
        payer.pay{value: amount}(PROJECT, JBConstants.NATIVE_TOKEN, 0, address(0xCAFE), 0, "", "");

        // Inner frame: msg.sender was the terminal (a contract). The terminal does not implement a non-zero tracker,
        // so the inner originalPayer falls back to msg.sender == the terminal address.
        assertEq(term.innerObserved(), address(term), "inner frame records its direct caller (the terminal)");
        // Outer frame restored: the terminal's `require` already enforced restore; assert the recorded value.
        assertEq(term.outerObservedAfterReturn(), caller, "outer originalPayer restored to the EOA caller");

        // After the whole tx unwinds, the transient slot is zero again.
        assertEq(IJBPayerTracker(address(payer)).originalPayer(), address(0), "transient cleared at tx end");
    }

    /// @notice Outside any forward, originalPayer is always the zero address (transient default + restore).
    function test_originalPayerZeroOutsideForward() public {
        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);
        assertEq(IJBPayerTracker(address(payer)).originalPayer(), address(0));
    }

    // ------------------------------------------------ //
    // B.2.1 / D.7 — initialize is one-shot, deployer-only //
    // ------------------------------------------------ //

    /// @notice No address other than the deployer factory can (re-)initialize a clone — for any caller and any args.
    function testFuzz_initializeRejectsNonDeployer(address attacker, uint256 projectId, address newOwner) public {
        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer, FwdMockDirectory dir) = _deploy(IJBTerminal(address(term)), defaultBen, false);
        address deployer = payer.DEPLOYER();
        vm.assume(attacker != deployer);
        dir; // silence

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(JBProjectPayer.JBProjectPayer_AlreadyInitialized.selector, attacker, deployer)
        );
        payer.initialize(projectId, payable(newOwner), "", "", false, newOwner);

        // State unchanged: defaults still the deploy-time values, owner still `owner`.
        assertEq(payer.defaultProjectId(), PROJECT, "projectId unchanged");
        assertEq(JBProjectPayer(payable(address(payer))).owner(), owner, "owner unchanged");
    }

    // ------------------------------------------------ //
    // B.1.1 — setDefaultValues onlyOwner + full state set //
    // ------------------------------------------------ //

    /// @notice Only the owner can mutate defaults; a non-owner is rejected and state is untouched.
    function testFuzz_setDefaultValuesOnlyOwner(address notOwner, uint256 newProject) public {
        vm.assume(notOwner != owner);

        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);

        vm.prank(notOwner);
        vm.expectRevert();
        payer.setDefaultValues(newProject, payable(notOwner), "", "", true);

        assertEq(payer.defaultProjectId(), PROJECT, "non-owner must not mutate defaults");
    }

    /// @notice Owner mutation sets all five default fields exactly.
    function testFuzz_setDefaultValuesSetsAllFields(uint256 newProject, address newBen, bool addToBalance) public {
        RecordingTerminal term = new RecordingTerminal();
        (IJBProjectPayer payer,) = _deploy(IJBTerminal(address(term)), defaultBen, false);

        vm.prank(owner);
        payer.setDefaultValues(newProject, payable(newBen), "m", hex"01", addToBalance);

        assertEq(payer.defaultProjectId(), newProject);
        assertEq(payer.defaultBeneficiary(), newBen);
        assertEq(payer.defaultAddToBalance(), addToBalance);
        assertEq(keccak256(bytes(payer.defaultMemo())), keccak256(bytes("m")));
        assertEq(keccak256(payer.defaultMetadata()), keccak256(hex"01"));
    }
}
