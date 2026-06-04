# nana-project-payer-v6

Deploys payable addresses that automatically route received ETH or ERC-20 tokens to a Juicebox V6 project treasury, giving every project a simple payable address.

## Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) — system design and module overview.
- [INVARIANTS.md](./INVARIANTS.md) — per-repo guarantees and invariants.
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — actor-focused operational flows.
- [ADMINISTRATION.md](./ADMINISTRATION.md) — control model and privileged surfaces.
- [RISKS.md](./RISKS.md) — security and operational risks.
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — practical audit scope and commands.
- [SKILLS.md](./SKILLS.md) — AI agent guidance.
- [CHANGELOG.md](./CHANGELOG.md) - V5 to V6 migration changelog.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — coding conventions.

## Overview

Anyone can deploy a `JBProjectPayer` clone that, when sent ETH, automatically forwards it to a specified Juicebox project via `pay` (issuing tokens to a beneficiary) or `addToBalanceOf` (contributing without token issuance). ERC-20 tokens can also be routed through the explicit `pay()` and `addToBalanceOf()` functions.

## Key contracts

| Contract | Responsibility |
|---|---|
| `JBProjectPayer` | Receives funds and forwards them to a project's terminal. Configurable defaults for project ID, beneficiary, memo, metadata, and routing mode. |
| `JBProjectPayerDeployer` | Factory that deploys EIP-1167 minimal proxy clones of `JBProjectPayer`. Anyone can call `deployProjectPayer()`. |

## Mental model

Think of each `JBProjectPayer` clone as a **deposit address** for a Juicebox project. Send ETH to the address and it automatically routes to the project's treasury. The owner can configure which project receives funds, who gets the project tokens, and whether to use `pay` or `addToBalanceOf`.

## Read these files first

1. `src/interfaces/IJBProjectPayer.sol` — The interface, all public functions
2. `src/interfaces/IJBPayerTracker.sol` — Original-payer exposure for downstream router terminals
3. `src/JBProjectPayer.sol` — The implementation
4. `src/JBProjectPayerDeployer.sol` — The factory

## High-signal tests

- `test/JBProjectPayer.t.sol` — Core unit tests for pay, receive, and addToBalanceOf
- `test/JBProjectPayerDeployer.t.sol` — Factory deployment and clone isolation
- `test/JBProjectPayer_Edge.t.sol` — Fee-on-transfer tokens, zero amounts, large amounts

## Install

```bash
npm install @bananapus/project-payer-v6
```

## Development

```bash
npm install
forge test --deny notes
forge fmt --check
forge build --deny notes --sizes --skip "*/test/**" --skip "*/script/**"
npm pack --dry-run --json
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Deployment

Set the `JB_DIRECTORY` environment variable to the target chain's JBDirectory address, then:

```bash
forge script script/Deploy.s.sol --broadcast --rpc-url <RPC_URL>
```

## Repository layout

```
├── src/
│   ├── JBProjectPayer.sol              # Main contract
│   ├── JBProjectPayerDeployer.sol      # Clone factory
│   └── interfaces/
│       ├── IJBProjectPayer.sol         # Payer interface
│       ├── IJBPayerTracker.sol         # Original-payer exposure for router terminals
│       └── IJBProjectPayerDeployer.sol # Factory interface
├── test/
│   ├── JBProjectPayer.t.sol            # Unit tests
│   ├── JBProjectPayerDeployer.t.sol    # Factory tests
│   └── JBProjectPayer_Edge.t.sol       # Edge case tests
├── script/
│   └── Deploy.s.sol                    # Deployment script
└── .github/workflows/
    ├── test.yml                        # CI test pipeline
    └── lint.yml                        # CI lint pipeline
```

## Risks and notes

- **Beneficiary fallback**: When no beneficiary is configured, project tokens go to `msg.sender`. Smart contract wallets and relayers should set a `defaultBeneficiary` or pass an explicit beneficiary.
- **Fee-on-transfer tokens**: The contract measures actual balance changes, correctly handling fee-on-transfer tokens.
- **ERC-20 approval**: The payer approves the terminal for each payment. Residual allowances may remain if the terminal doesn't pull the full amount.
- **No sweep function**: Tokens accidentally sent to the payer (outside of `pay()`/`addToBalanceOf()`) may be stuck. This is intentional to keep the contract simple.

## For AI agents

See [SKILLS.md](SKILLS.md) for task-specific guidance on navigating this repo.
