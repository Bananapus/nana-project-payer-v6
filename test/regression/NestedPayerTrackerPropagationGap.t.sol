// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";
import {IJBPayerTracker} from "../../src/interfaces/IJBPayerTracker.sol";

contract NestedTrackerToken is ERC20 {
    constructor() ERC20("Nested Tracker Token", "NTT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NestedTrackerDirectory {
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) internal _primaryTerminalOf;

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }
}

contract NestedTrackerRefundTerminal {
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
            (bool success,) = payable(refundTo).call{value: amount / 2}("");
            require(success, "NATIVE_REFUND_FAILED");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).safeTransfer(refundTo, amount / 2);
        }

        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract NestedPayerTrackerPropagationGapTest is Test {
    uint256 internal constant PROJECT_ID = 1;

    address internal user = makeAddr("user");
    address internal owner = makeAddr("owner");

    NestedTrackerDirectory internal directory;
    NestedTrackerRefundTerminal internal terminal;
    JBProjectPayerDeployer internal deployer;
    IJBProjectPayer internal payer;
    UpstreamPayerTracker internal upstream;

    function setUp() public {
        directory = new NestedTrackerDirectory();
        terminal = new NestedTrackerRefundTerminal();
        deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
        upstream = new UpstreamPayerTracker();

        directory.setPrimaryTerminalOf(PROJECT_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(terminal)));

        payer = deployer.deployProjectPayer({
            defaultProjectId: PROJECT_ID,
            defaultBeneficiary: payable(user),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: owner
        });
    }

    function test_Erc20RefundPropagatesToOriginalPayerThroughUpstreamTracker() public {
        NestedTrackerToken token = new NestedTrackerToken();
        directory.setPrimaryTerminalOf(PROJECT_ID, address(token), IJBTerminal(address(terminal)));

        uint256 amount = 100 ether;
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(upstream), amount);
        upstream.forwardErc20({
            payer: payer, projectId: PROJECT_ID, token: address(token), amount: amount, beneficiary: user
        });
        vm.stopPrank();

        // The project payer reads the upstream tracker's IJBPayerTracker.originalPayer() and
        // exposes the true caller to the downstream terminal, so the refund reaches `user`.
        assertEq(terminal.lastRefundTo(), user, "refund propagates through upstream tracker to user");
        assertEq(token.balanceOf(user), amount / 2, "original payer receives the leftover refund");
        assertEq(token.balanceOf(address(upstream)), 0, "no leftover stranded at the intermediary");
    }

    function test_NativeRefundPropagatesToOriginalPayerThroughUpstreamTracker() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        upstream.forwardNative{value: amount}({payer: payer, projectId: PROJECT_ID, beneficiary: user});

        assertEq(terminal.lastRefundTo(), user, "native refund propagates through upstream tracker to user");
        assertEq(user.balance, amount / 2, "original payer receives the native leftover refund");
        assertEq(address(upstream).balance, 0, "no native leftover stranded at the intermediary");
    }
}

contract UpstreamPayerTracker is IJBPayerTracker {
    using SafeERC20 for IERC20;

    address public override originalPayer;

    receive() external payable {}

    function forwardErc20(
        IJBProjectPayer payer,
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary
    )
        external
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(payer), amount);

        address previousPayer = originalPayer;
        originalPayer = msg.sender;

        payer.pay({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        originalPayer = previousPayer;
    }

    function forwardNative(IJBProjectPayer payer, uint256 projectId, address beneficiary) external payable {
        address previousPayer = originalPayer;
        originalPayer = msg.sender;

        payer.pay{value: msg.value}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: msg.value,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        originalPayer = previousPayer;
    }
}
