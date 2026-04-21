# nana-project-payer-v6

Deploys payable addresses that automatically route received ETH or ERC20 tokens to a Juicebox V6 project treasury, giving every project a simple payable address.

| Document | Purpose |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, invariants, and module overview |
| [USER_JOURNEYS.md](USER_JOURNEYS.md) | Actor-focused operational flows |
| [ADMINISTRATION.md](ADMINISTRATION.md) | Control model and privileged surfaces |
| [SKILLS.md](SKILLS.md) | AI agent guidance |
| [RISKS.md](RISKS.md) | Security and operational risks |

## Overview

Anyone can deploy a `JBProjectPayer` clone that, when sent ETH, automatically forwards it to a specified Juicebox project via `pay` (issuing tokens to a beneficiary) or `addToBalanceOf` (contributing without token issuance). ERC20 tokens can also be routed through the explicit `pay()` and `addToBalanceOf()` functions.

## Key Contracts

| Contract | Responsibility |
|---|---|
| `JBProjectPayer` | Receives funds and forwards them to a project's terminal. Configurable defaults for project ID, beneficiary, memo, metadata, and routing mode. |
| `JBProjectPayerDeployer` | Factory that deploys EIP-1167 minimal proxy clones of `JBProjectPayer`. Anyone can call `deployProjectPayer()`. |

## Mental Model

Think of each `JBProjectPayer` clone as a **deposit address** for a Juicebox project. Send ETH to the address and it automatically routes to the project's treasury. The owner can configure which project receives funds, who gets the project tokens, and whether to use `pay` or `addToBalanceOf`.

## Read These Files First

1. `src/interfaces/IJBProjectPayer.sol` — The interface, all public functions
2. `src/JBProjectPayer.sol` — The implementation
3. `src/JBProjectPayerDeployer.sol` — The factory

## High-Signal Tests

- `test/JBProjectPayer.t.sol` — Core unit tests for pay, receive, and addToBalanceOf
- `test/JBProjectPayerDeployer.t.sol` — Factory deployment and clone isolation
- `test/JBProjectPayer_Edge.t.sol` — Fee-on-transfer tokens, zero amounts, large amounts

## Install

```bash
npm install
```

## Development

```bash
forge test          # Run tests
forge fmt           # Format code
forge coverage      # Coverage report
```

## Deployment

Set the `JB_DIRECTORY` environment variable to the target chain's JBDirectory address, then:

```bash
forge script script/Deploy.s.sol --broadcast --rpc-url <RPC_URL>
```

## Repository Layout

```
├── src/
│   ├── JBProjectPayer.sol              # Main contract
│   ├── JBProjectPayerDeployer.sol      # Clone factory
│   └── interfaces/
│       ├── IJBProjectPayer.sol         # Payer interface
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

## Risks and Notes

- **`tx.origin` fallback**: When no beneficiary is configured, project tokens go to `tx.origin`. Smart contract wallets (multisigs) should always set a `defaultBeneficiary`.
- **Fee-on-transfer tokens**: The contract measures actual balance changes, correctly handling fee-on-transfer tokens.
- **ERC20 approval**: The payer approves the terminal for each payment. Residual allowances may remain if the terminal doesn't pull the full amount.
- **No sweep function**: Tokens accidentally sent to the payer (outside of `pay()`/`addToBalanceOf()`) may be stuck. This is intentional to keep the contract simple.

## For AI Agents

See [SKILLS.md](SKILLS.md) for task-specific guidance on navigating this repo.
