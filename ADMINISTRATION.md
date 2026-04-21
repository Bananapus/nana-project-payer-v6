# Administration

## Scope

This document describes the control model for `nana-project-payer-v6`.

## Control Posture

**Minimal admin surface.** The deployer factory is permissionless and immutable. Each project payer clone has an owner who can only change default routing parameters — they cannot access, redirect, or freeze funds in transit.

## Roles

| Role | Address | Capabilities |
|---|---|---|
| **Deployer Factory** | `JBProjectPayerDeployer` (immutable) | Deploys new clones and initializes them. |
| **Payer Owner** | Set during deployment | Can update default values (project ID, beneficiary, memo, metadata, routing mode). Can transfer or renounce ownership. |
| **Anyone** | Any address | Can send ETH via `receive()`, call `pay()`, or call `addToBalanceOf()`. |

## Privileged Surfaces

| Function | Who | What It Does |
|---|---|---|
| `setDefaultValues()` | Owner | Changes the default project ID, beneficiary, memo, metadata, and routing mode. |
| `transferOwnership()` | Owner | Transfers ownership to a new address. |
| `renounceOwnership()` | Owner | Permanently removes ownership. Defaults become immutable. |

## Immutable and One-Way Operations

| Operation | Reversibility |
|---|---|
| `renounceOwnership()` | **Irreversible.** Once ownership is renounced, defaults can never be changed. |
| Clone deployment | **Irreversible.** Clones cannot be destroyed or upgraded. A new clone must be deployed to change immutable parameters. |
| `DIRECTORY` reference | **Immutable.** Set at implementation construction time. All clones share the same directory. A new deployer must be deployed for a different directory. |

## Operational Notes

- **Owner ≠ project owner.** The payer owner is independent of the Juicebox project owner. They may or may not be the same address.
- **Defaults only affect `receive()`.** The `pay()` and `addToBalanceOf()` functions accept explicit parameters, bypassing defaults entirely.
- **No pause mechanism.** The payer cannot be paused. If the terminal reverts, payments will also revert.

## Recovery Posture

- **Stuck ERC20 tokens**: If ERC20 tokens are sent directly to the payer (not via `pay()`/`addToBalanceOf()`), they cannot be recovered. The payer has no sweep function.
- **Wrong defaults**: The owner can update defaults at any time via `setDefaultValues()`.
- **Compromised owner**: Ownership can be transferred or renounced. If the owner is compromised, they can only change routing defaults — they cannot steal funds.
- **Malicious terminal**: If the directory returns a malicious terminal, funds sent to the payer will be routed to that terminal. This is a directory-level concern, not specific to the payer.

## Admin Boundaries

The payer owner controls **where** funds go (default project ID and beneficiary), not **whether** they go. Funds are always forwarded in the same transaction — the owner cannot hold or redirect funds after they arrive.
