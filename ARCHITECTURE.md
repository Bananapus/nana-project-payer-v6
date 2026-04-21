# Architecture

## Purpose

Give every Juicebox V6 project a simple payable address that automatically forwards received funds to the project's treasury.

## System Overview

The system has two contracts. `JBProjectPayerDeployer` is a permissionless factory that deploys EIP-1167 minimal proxy clones of `JBProjectPayer`. Each clone is configured with a default project ID, beneficiary, memo, metadata, and routing mode (`pay` vs `addToBalanceOf`). When a clone receives ETH via its `receive()` function, it looks up the project's primary terminal from `JBDirectory` and forwards the funds. ERC20 tokens can be routed via explicit `pay()` or `addToBalanceOf()` calls.

## Core Invariants

1. Every ETH sent to a project payer's `receive()` is forwarded to the terminal in the same transaction (no held funds).
2. The terminal called is always the one returned by `DIRECTORY.primaryTerminalOf()` at call time.
3. Only the owner can change default values. Anyone can call `pay()` or `addToBalanceOf()` to route funds.
4. Clones share immutables (DIRECTORY, DEPLOYER) but have independent storage (defaults, owner).
5. Fee-on-transfer tokens are handled correctly — the amount forwarded reflects actual balance change, not the nominal amount.

## Modules

| Module | Responsibility |
|---|---|
| `JBProjectPayer` | Receives and forwards funds to a project's terminal. Manages configurable defaults. |
| `JBProjectPayerDeployer` | Permissionless factory for deploying clones. |

## Trust Boundaries

- **Owner**: Can change default values (project ID, beneficiary, memo, metadata, routing mode). Cannot access funds held by the contract.
- **Anyone**: Can send ETH to the payer or call `pay()`/`addToBalanceOf()` to route funds to any project.
- **JBDirectory**: Trusted to return the correct terminal for a project. If the directory returns a malicious terminal, funds are at risk.
- **Terminal**: Trusted to correctly process payments. The payer approves the terminal for ERC20 transfers.

## Critical Flows

### ETH Payment via receive()

1. ETH arrives at the payer's `receive()` function.
2. Payer checks `defaultAddToBalance` flag.
3. If `pay` mode: calls `_pay()` with default values.
4. `_pay()` looks up the terminal via `DIRECTORY.primaryTerminalOf(defaultProjectId, NATIVE_TOKEN)`.
5. If no terminal found: reverts with `JBProjectPayer_TerminalNotFound`.
6. Calls `terminal.pay{value: amount}(...)` forwarding all accumulated ETH.

### ERC20 Payment via pay()

1. Caller calls `pay()` with token address and amount.
2. Payer transfers ERC20 from caller via `safeTransferFrom`.
3. Payer measures actual balance change (fee-on-transfer safe).
4. Payer looks up terminal and approves it for the received amount.
5. Payer calls `terminal.pay()` — terminal pulls tokens via the approval.

### Clone Deployment

1. Caller calls `JBProjectPayerDeployer.deployProjectPayer(...)`.
2. Factory clones the implementation via `Clones.clone()`.
3. Factory calls `clone.initialize(...)` to set defaults and owner.
4. Factory emits `DeployProjectPayer` event.

## Security Model

- **Reentrancy**: Not a concern. The payer does not hold state that could be exploited via reentrancy. Each receive/pay call is atomic — funds are forwarded immediately.
- **Access control**: Only the owner can modify defaults. The `initialize` function can only be called by the deployer factory.
- **ERC20 safety**: Uses OpenZeppelin `SafeERC20` for all token transfers and `forceApprove` for terminal approvals.

## Safe Change Guide

- **Adding new default fields**: Add to the interface, storage, `initialize`, and `setDefaultValues`. Update tests.
- **Changing terminal lookup**: Modify `_pay()` and `_addToBalanceOf()`. All terminal interaction is isolated there.
- **Changing clone pattern**: Modify the deployer. Consider deterministic deployment for cross-chain address consistency.
