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

interface IJBPayerTrackerLike {
    function originalPayer() external view returns (address);
}

contract AuditToken is ERC20 {
    constructor() ERC20("Audit Token", "AUD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AuditDirectory {
    IJBTerminal internal _terminal;

    function setTerminal(IJBTerminal terminal) external {
        _terminal = terminal;
    }

    function primaryTerminalOf(uint256, address) external view returns (IJBTerminal) {
        return _terminal;
    }
}

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
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        address refundTo = msg.sender;
        if (msg.sender.code.length > 0) {
            try IJBPayerTrackerLike(msg.sender).originalPayer() returns (address originalPayer) {
                if (originalPayer != address(0)) refundTo = originalPayer;
            } catch {}
        }

        lastRefundTo = refundTo;
        IERC20(token).safeTransfer(refundTo, amount / 2);
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract ProjectPayerRouterRefundAuditTest is Test {
    function test_routerStyleRefundGoesToProjectPayerInsteadOfCaller() public {
        uint256 projectId = 1;
        uint256 amount = 100 ether;
        address caller = makeAddr("caller");

        AuditToken token = new AuditToken();
        AuditDirectory directory = new AuditDirectory();
        RouterStyleRefundTerminal terminal = new RouterStyleRefundTerminal();
        directory.setTerminal(IJBTerminal(address(terminal)));

        JBProjectPayerDeployer deployer = new JBProjectPayerDeployer(IJBDirectory(address(directory)));
        IJBProjectPayer payer = deployer.deployProjectPayer({
            defaultProjectId: projectId,
            defaultBeneficiary: payable(caller),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: caller
        });

        token.mint(caller, amount);
        vm.startPrank(caller);
        token.approve(address(payer), amount);
        payer.pay({
            projectId: projectId,
            token: address(token),
            amount: amount,
            beneficiary: caller,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();

        assertEq(terminal.lastRefundTo(), address(payer), "refund recipient should fall back to intermediary");
        assertEq(token.balanceOf(address(payer)), amount / 2, "leftover refund is stuck on payer");
        assertEq(token.balanceOf(caller), 0, "caller did not receive leftover refund");
    }
}
