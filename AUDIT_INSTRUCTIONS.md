# Audit Instructions

This repo wraps Juicebox terminal payments behind a simple payer contract and a clone deployer. Audit it as a forwarding layer whose mistakes show up as lost funds, wrong beneficiaries, or stuck tokens.

## Audit objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- misroute payments to the wrong terminal, project, or beneficiary
- lose ETH or ERC-20 tokens through forwarding gaps or stuck balances
- let unauthorized callers reconfigure the payer or deployer
- break clone initialization or ownership assumptions

## Scope

Review the contracts in `src/`:

- `JBProjectPayer`
- `JBProjectPayerDeployer`
- `src/interfaces/`

Tests, deployment scripts, and docs are supporting context. Fork tests in `test/fork/` exercise integration assumptions against Juicebox V6 contracts, but they are not part of the package runtime surface.

## External dependencies

- `@bananapus/core-v6` provides `IJBDirectory`, `IJBTerminal`, and `JBConstants`.
- `@openzeppelin/contracts` provides `Ownable`, `ERC165`, `Clones`, and `SafeERC20`.
- `@uniswap/permit2` is a pinned GitHub dev dependency used by fork tests because it is not published to npm.

## Review focus

- Terminal lookup and trust in `DIRECTORY.primaryTerminalOf(projectId, token)`.
- ETH forwarding through `receive()`, `pay()`, and `addToBalanceOf()`.
- ERC-20 balance-delta accounting for fee-on-transfer tokens.
- ERC-20 approval lifecycle before terminal calls.
- Clone initialization authority and ownership transfer.
- Beneficiary fallback behavior when no explicit or default beneficiary is set.
- Stuck-token posture for direct ERC-20 transfers that bypass payer functions.

## Practical commands

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

Run Slither after the build-info command:

```bash
slither . --config-file slither-ci.config.json --ignore-compile
```
