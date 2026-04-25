// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBProjectPayer} from "../../src/JBProjectPayer.sol";
import {JBProjectPayerDeployer} from "../../src/JBProjectPayerDeployer.sol";
import {IJBProjectPayer} from "../../src/interfaces/IJBProjectPayer.sol";

/// @notice Fork test: validates JBProjectPayer end-to-end against real JB core on mainnet fork.
///         Covers ETH and ERC20 payment flows, addToBalanceOf, token minting, and balance accounting.
contract ProjectPayerFork is Test {
    // Real mainnet Permit2 address.
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // Real mainnet USDC address (6 decimals).
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Pinned block for reproducibility.
    uint256 constant FORK_BLOCK = 22_000_000;

    address multisig = address(0xBEEF);
    address trustedForwarder = address(0);
    address caller = makeAddr("caller");

    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBSplits jbSplits;
    JBPrices jbPrices;
    JBFundAccessLimits jbFundAccessLimits;
    JBFeelessAddresses jbFeelessAddresses;
    JBController jbController;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;

    JBProjectPayerDeployer payerDeployer;
    IJBProjectPayer payer;
    uint256 projectId;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum", FORK_BLOCK);
        _deployJBCore();

        // Launch a project with native token terminal.
        projectId = _launchProject({weight: 1_000_000e18, cashOutTaxRate: 0});

        // Deploy project payer infrastructure.
        payerDeployer = new JBProjectPayerDeployer(jbDirectory);
        payer = payerDeployer.deployProjectPayer({
            defaultProjectId: projectId,
            defaultBeneficiary: payable(caller),
            defaultMemo: "fork test",
            defaultMetadata: "",
            defaultAddToBalance: false,
            owner: multisig
        });
    }

    /// @notice ETH sent directly to the payer's receive() is forwarded to the project terminal and mints tokens.
    function test_fork_receive_ETH_mintsTokens() public {
        uint256 amount = 1 ether;

        vm.deal(caller, amount);
        vm.prank(caller, caller);
        (bool success,) = address(payer).call{value: amount}("");
        assertTrue(success, "receive() failed");

        // Payer should have no residual balance.
        assertEq(address(payer).balance, 0, "payer has residual ETH");

        // Caller should have received project tokens (weight=1M tokens per ETH).
        uint256 tokenBalance = jbTokens.totalBalanceOf(caller, projectId);
        assertGt(tokenBalance, 0, "caller received no project tokens");
    }

    /// @notice ETH payment via pay() forwards to terminal and mints tokens to specified beneficiary.
    function test_fork_pay_ETH() public {
        uint256 amount = 2 ether;
        address payBeneficiary = makeAddr("payBeneficiary");

        vm.deal(caller, amount);
        vm.prank(caller, caller);
        payer.pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: payBeneficiary,
            minReturnedTokens: 0,
            memo: "direct pay",
            metadata: ""
        });

        // Payer forwarded all ETH.
        assertEq(address(payer).balance, 0, "payer has residual ETH");

        // Beneficiary received project tokens.
        uint256 tokenBalance = jbTokens.totalBalanceOf(payBeneficiary, projectId);
        assertGt(tokenBalance, 0, "beneficiary received no project tokens");

        // Terminal recorded the payment.
        uint256 terminalBalance = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, JBConstants.NATIVE_TOKEN);
        assertGe(terminalBalance, amount, "terminal balance too low");
    }

    /// @notice ETH addToBalanceOf via payer adds surplus without minting tokens.
    function test_fork_addToBalanceOf_ETH() public {
        uint256 amount = 3 ether;

        // Deploy payer in addToBalance mode.
        IJBProjectPayer addToBalancePayer = payerDeployer.deployProjectPayer({
            defaultProjectId: projectId,
            defaultBeneficiary: payable(caller),
            defaultMemo: "",
            defaultMetadata: "",
            defaultAddToBalance: true,
            owner: multisig
        });

        uint256 tokensBefore = jbTokens.totalBalanceOf(caller, projectId);

        vm.deal(caller, amount);
        vm.prank(caller, caller);
        (bool success,) = address(addToBalancePayer).call{value: amount}("");
        assertTrue(success, "addToBalance failed");

        // No new tokens minted (addToBalance doesn't mint).
        uint256 tokensAfter = jbTokens.totalBalanceOf(caller, projectId);
        assertEq(tokensAfter, tokensBefore, "tokens minted during addToBalance");

        // Terminal balance increased.
        uint256 terminalBalance = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, JBConstants.NATIVE_TOKEN);
        assertGe(terminalBalance, amount, "terminal balance too low");
    }

    /// @notice Multiple sequential payments through the payer all reach the terminal correctly.
    function test_fork_multiplePays_noResidualBalance() public {
        for (uint256 i = 1; i <= 5; i++) {
            uint256 amount = i * 0.5 ether;
            vm.deal(caller, amount);
            vm.prank(caller, caller);
            (bool success,) = address(payer).call{value: amount}("");
            assertTrue(success, "payment failed");
        }

        // Payer should have zero balance after all payments.
        assertEq(address(payer).balance, 0, "payer has residual balance");

        // Caller should have accumulated project tokens.
        uint256 tokenBalance = jbTokens.totalBalanceOf(caller, projectId);
        assertGt(tokenBalance, 0, "caller received no tokens across multiple pays");
    }

    /// @notice Paying a project that has no terminal registered reverts.
    function test_fork_pay_unregisteredProject_reverts() public {
        uint256 unregisteredProject = 999;

        vm.deal(caller, 1 ether);
        vm.prank(caller, caller);
        vm.expectRevert(JBProjectPayer.JBProjectPayer_TerminalNotFound.selector);
        payer.pay{value: 1 ether}({
            projectId: unregisteredProject,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: caller,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _deployJBCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, trustedForwarder);
        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        jbFeelessAddresses = new JBFeelessAddresses(multisig);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0),
            trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            PERMIT2,
            trustedForwarder
        );

        vm.deal(address(this), 10_000 ether);
    }

    function _launchProject(uint112 weight, uint16 cashOutTaxRate) internal returns (uint256 id) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: cashOutTaxRate,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = weight;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] =
            JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        id = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }
}
