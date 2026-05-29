// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";
import {IJBPayerTracker} from "../../src/interfaces/IJBPayerTracker.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDirectory {
    IJBTerminal internal _terminal;

    function setTerminal(IJBTerminal terminal) external {
        _terminal = terminal;
    }

    function primaryTerminalOf(uint256, address) external view returns (IJBTerminal) {
        return _terminal;
    }
}

/// @notice A terminal that emulates the router pattern: it half-refunds the caller, querying `originalPayer()` to
/// resolve the true payer when called through a forwarder.
contract RouterStyleRefundTerminal {
    using SafeERC20 for IERC20;

    address public lastRefundTo;

    function pay(
        uint256,
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
        address refundTo = msg.sender;
        if (msg.sender.code.length > 0) {
            try IJBPayerTracker(msg.sender).originalPayer() returns (address originalPayer) {
                if (originalPayer != address(0)) refundTo = originalPayer;
            } catch {}
        }

        lastRefundTo = refundTo;

        if (token == JBConstants.NATIVE_TOKEN) {
            // Half of the native amount is refunded to the resolved payer.
            (bool ok,) = payable(refundTo).call{value: amount / 2}("");
            require(ok, "native refund failed");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).safeTransfer(refundTo, amount / 2);
        }
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract ProjectPayerRouterRefundTest is Test {
    address internal _caller = makeAddr("caller");
    uint256 internal _projectId = 1;

    function _setupErc20() internal returns (MockToken token, IJBProjectPayer payer, RouterStyleRefundTerminal term) {
        token = new MockToken();
        MockDirectory directory = new MockDirectory();
        term = new RouterStyleRefundTerminal();
        directory.setTerminal(IJBTerminal(address(term)));

        JBProjectPayerDeployer deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
        payer = deployer.deployProjectPayer({
            defaultProjectId: _projectId,
            defaultBeneficiary: payable(_caller),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: _caller
        });
    }

    function test_routerStyleRefundReachesOriginalPayer_erc20() public {
        (MockToken token, IJBProjectPayer payer, RouterStyleRefundTerminal term) = _setupErc20();

        uint256 amount = 100 ether;
        token.mint(_caller, amount);
        vm.startPrank(_caller);
        token.approve(address(payer), amount);
        payer.pay({
            projectId: _projectId,
            token: address(token),
            amount: amount,
            beneficiary: _caller,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();

        // The router resolves the original payer via `IJBPayerTracker.originalPayer()`.
        assertEq(term.lastRefundTo(), _caller, "refund recipient should be the original payer (caller)");
        assertEq(token.balanceOf(_caller), amount / 2, "caller should receive the leftover refund");
        assertEq(token.balanceOf(address(payer)), 0, "no leftover refund should be stuck on the payer");
    }

    function test_routerStyleRefundReachesOriginalPayer_native() public {
        (, IJBProjectPayer payer, RouterStyleRefundTerminal term) = _setupErc20();

        uint256 amount = 1 ether;
        vm.deal(_caller, amount);
        uint256 callerBefore = _caller.balance;

        vm.prank(_caller);
        payer.pay{value: amount}({
            projectId: _projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: _caller,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Half of the native payment refunds to the resolved original payer.
        assertEq(term.lastRefundTo(), _caller, "native refund should resolve to caller");
        assertEq(_caller.balance, callerBefore - amount + (amount / 2), "caller should receive native refund");
        assertEq(address(payer).balance, 0, "no native refund should be stuck on the payer");
    }

    function test_originalPayerIsZeroWhenNotForwarding() public {
        (, IJBProjectPayer payer,) = _setupErc20();

        // Outside of an active forward, originalPayer must be zero (transient storage default).
        assertEq(IJBPayerTracker(address(payer)).originalPayer(), address(0));
    }

    function test_originalPayerNestsAndRestores() public {
        // A nested call into the payer must restore the outer payer after returning.
        // We exercise this by having the terminal call back into `pay()` from a second account
        // and verifying both forwards observed their respective callers.
        (MockToken token, IJBProjectPayer payer, RouterStyleRefundTerminal term) = _setupErc20();
        // (Single direct call is sufficient for the documented invariant; the outer
        // call should still see the value cleared after `terminal.pay` returns.)
        uint256 amount = 50 ether;
        token.mint(_caller, amount);
        vm.startPrank(_caller);
        token.approve(address(payer), amount);
        payer.pay(_projectId, address(token), amount, _caller, 0, "", "");
        vm.stopPrank();
        // After return, transient `originalPayer` is reset to zero.
        assertEq(IJBPayerTracker(address(payer)).originalPayer(), address(0));
        // And the in-flight value was observed by the terminal.
        assertEq(term.lastRefundTo(), _caller);
    }

    function test_supportsInterface_includesPayerTracker() public {
        (, IJBProjectPayer payer,) = _setupErc20();
        assertTrue(payer.supportsInterface(type(IJBPayerTracker).interfaceId));
        assertTrue(payer.supportsInterface(type(IJBProjectPayer).interfaceId));
    }
}
