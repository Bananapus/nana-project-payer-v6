# Skills

## Use This File For

- Understanding how the project payer routes funds to Juicebox projects.
- Debugging payment routing failures (terminal not found, revert on pay).
- Extending the payer with custom routing logic.
- Deploying new project payer instances.

## Read This Next

| Task | Files |
|---|---|
| Understand the payer interface | `src/interfaces/IJBProjectPayer.sol` |
| Understand the original-payer surface | `src/interfaces/IJBPayerTracker.sol` |
| Understand payment routing | `src/JBProjectPayer.sol` (`_pay`, `_addToBalanceOf`) |
| Understand clone deployment | `src/JBProjectPayerDeployer.sol` |
| Debug terminal lookup | `@bananapus/core-v6/src/interfaces/IJBDirectory.sol` |
| Debug terminal pay/addToBalance | `@bananapus/core-v6/src/interfaces/IJBTerminal.sol` |
| See edge cases | `test/JBProjectPayer_Edge.t.sol` |
| See router-refund regression | `test/audit/ProjectPayerRouterRefund.t.sol` |

## Repo Map

```
src/JBProjectPayer.sol              ← Main logic: receive, pay, addToBalance
src/JBProjectPayerDeployer.sol      ← Clone factory
src/interfaces/                     ← Interfaces
test/JBProjectPayer.t.sol           ← Core tests
test/JBProjectPayerDeployer.t.sol   ← Factory tests
test/JBProjectPayer_Edge.t.sol      ← Edge cases
```

## Purpose

This repo gives Juicebox V6 projects payable deposit addresses. Anyone deploys a clone via the factory, configures it for a project, and shares the address. ETH sent to the address is automatically routed to the project's terminal. ERC20 tokens can be routed via explicit function calls.

## Working Rules

1. All fund routing goes through `DIRECTORY.primaryTerminalOf()` — never hardcode terminal addresses.
2. The payer is stateless with respect to funds — it never holds balances across transactions.
3. Fee-on-transfer tokens must be handled by measuring actual balance changes, not trusting the nominal amount.
4. `msg.sender` is used as a last-resort beneficiary fallback. Prefer setting `defaultBeneficiary` or passing an explicit beneficiary in relayed or contract-based flows.
5. The `initialize` function is guarded by the deployer address, not by an `initialized` flag. This is safe because the deployer only calls it once per clone.
6. `originalPayer` is transient storage. Set it via the `_pay` / `_addToBalanceOf` save/restore pattern only — never write it from custom subclass logic without restoring the previous value, or you will leak payer identity into unrelated nested calls.
