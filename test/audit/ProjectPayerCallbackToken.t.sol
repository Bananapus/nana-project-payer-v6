// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";
import {IJBPayerTracker} from "../../src/interfaces/IJBPayerTracker.sol";

contract CallbackTokenDirectory {
    IJBTerminal internal _terminal;

    function setTerminal(IJBTerminal terminal) external {
        _terminal = terminal;
    }

    function primaryTerminalOf(uint256, address) external view returns (IJBTerminal) {
        return _terminal;
    }
}

contract CallbackPullingTerminal {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;

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
        returns (uint256)
    {
        lastAmount = amount;
        IERC20(token).safeTransferFrom({from: msg.sender, to: address(this), value: amount});
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract CallbackToken is ERC20 {
    address public payer;
    address public terminal;
    address public inboundObservedOriginalPayer;
    address public outboundObservedOriginalPayer;

    constructor() ERC20("Callback Token", "CALL") {}

    function configure(address projectPayer, address pullingTerminal) external {
        payer = projectPayer;
        terminal = pullingTerminal;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update({from: from, to: to, value: value});

        // The payer has not started the terminal forward while it is receiving tokens from the caller.
        if (to == payer) inboundObservedOriginalPayer = IJBPayerTracker(payer).originalPayer();

        // During the terminal pull, the payer exposes the true caller for router-style refunds.
        if (from == payer && to == terminal) {
            outboundObservedOriginalPayer = IJBPayerTracker(payer).originalPayer();
        }
    }
}

contract ProjectPayerCallbackTokenAuditTest is Test {
    address internal _caller = makeAddr("caller");
    address internal _owner = makeAddr("owner");
    uint256 internal _projectId = 1;

    function test_callbackTokenCannotDistortForwardedAmountOrPayerTracking() public {
        CallbackTokenDirectory directory = new CallbackTokenDirectory();
        CallbackPullingTerminal terminal = new CallbackPullingTerminal();
        CallbackToken token = new CallbackToken();

        directory.setTerminal(IJBTerminal(address(terminal)));

        JBProjectPayerDeployer deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
        IJBProjectPayer payer = deployer.deployProjectPayer({
            defaultProjectId: _projectId,
            defaultBeneficiary: payable(_caller),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: _owner
        });
        token.configure({projectPayer: address(payer), pullingTerminal: address(terminal)});

        uint256 amount = 100 ether;
        token.mint({to: _caller, amount: amount});

        vm.startPrank(_caller);
        token.approve({spender: address(payer), value: amount});
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

        assertEq(terminal.lastAmount(), amount, "terminal should receive the measured inbound amount");
        assertEq(token.balanceOf(address(payer)), 0, "payer should not retain callback token dust");
        assertEq(token.balanceOf(address(terminal)), amount, "terminal should pull the forwarded tokens");
        assertEq(token.inboundObservedOriginalPayer(), address(0), "inbound transfer should not expose stale payer");
        assertEq(token.outboundObservedOriginalPayer(), _caller, "terminal pull should expose original caller");
        assertEq(IJBPayerTracker(address(payer)).originalPayer(), address(0), "payer tracker should reset");
    }
}
