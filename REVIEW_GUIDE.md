# Review Guide

## Scope

Review the contracts in `src/`:

- `JBProjectPayer`
- `JBProjectPayerDeployer`
- `src/interfaces/`

Tests, deployment scripts, and docs are supporting context. Fork tests in `test/fork/` exercise integration assumptions against Juicebox V6 contracts, but they are not part of the package runtime surface.

## External Dependencies

- `@bananapus/core-v6` provides `IJBDirectory`, `IJBTerminal`, and `JBConstants`.
- `@openzeppelin/contracts` provides `Ownable`, `ERC165`, `Clones`, and `SafeERC20`.
- `@uniswap/permit2` is a pinned GitHub dev dependency used by fork tests because it is not published to npm.

## Review Focus

- Terminal lookup and trust in `DIRECTORY.primaryTerminalOf(projectId, token)`.
- ETH forwarding through `receive()`, `pay()`, and `addToBalanceOf()`.
- ERC20 balance-delta accounting for fee-on-transfer tokens.
- ERC20 approval lifecycle before terminal calls.
- Clone initialization authority and ownership transfer.
- Beneficiary fallback behavior when no explicit or default beneficiary is set.
- Stuck-token posture for direct ERC20 transfers that bypass payer functions.

## Practical Commands

```bash
npm install
forge fmt --check
forge test --deny notes --skip "*/fork/**"
forge build --deny notes --sizes --skip "*/test/**" --skip "*/script/**"
forge build --deny notes --build-info --skip "*/test/**" --skip "*/script/**"
npm pack --dry-run --json
```

Run fork tests only when `RPC_ETHEREUM_MAINNET` is configured:

```bash
forge test --deny notes --match-path "test/fork/*.sol"
```

Run Static review after the build-info command:

```bash
static review . --config-file static-review.config.json --ignore-compile
```
