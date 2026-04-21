# User Journeys

## Repo Purpose

This repo provides a way for anyone to deploy a payable address that automatically routes received funds to a Juicebox V6 project treasury. It gives projects simple deposit addresses that work with regular ETH transfers.

## Primary Actors

| Actor | Description |
|---|---|
| **Project owner** | Deploys and configures a project payer for their Juicebox project. |
| **Payer** | Sends ETH or ERC20 tokens to the project payer address. |
| **Integrator** | A contract or frontend that routes payments through the project payer. |

## Key Surfaces

| Surface | Contract |
|---|---|
| Deploy a project payer | `JBProjectPayerDeployer.deployProjectPayer()` |
| Send ETH to a project | `JBProjectPayer.receive()` (direct transfer) |
| Pay with specific parameters | `JBProjectPayer.pay()` |
| Add to balance | `JBProjectPayer.addToBalanceOf()` |
| Configure defaults | `JBProjectPayer.setDefaultValues()` |

## Journey 1: Project Owner Deploys a Payer

**Actor**: Project owner

**Intent**: Create a payable address for their Juicebox project so anyone can send ETH to fund the project.

**Preconditions**:
- A Juicebox project exists with a terminal that accepts ETH.
- The `JBProjectPayerDeployer` is deployed on the target chain.

**Main Flow**:
1. Call `deployProjectPayer()` with the project ID, desired beneficiary (who gets project tokens), memo, and whether to use `pay` or `addToBalanceOf` mode.
2. Receive the clone address.
3. Share the address with supporters — any ETH sent to it automatically funds the project.

**Failure Modes**:
- If the project has no terminal for ETH, payments will revert when someone sends ETH.
- If the beneficiary is `address(0)` and no one sets it, project tokens go to `tx.origin`.

**Postconditions**:
- A new `JBProjectPayer` clone exists with the specified defaults.
- The deploying address is recorded as the owner (unless a different owner was specified).

## Journey 2: Payer Sends ETH

**Actor**: Any address (EOA or contract)

**Intent**: Fund a Juicebox project by sending ETH to the project payer address.

**Preconditions**:
- The project payer is deployed and configured with a valid project ID.
- The project has a terminal that accepts ETH.

**Main Flow**:
1. Send ETH to the project payer address (regular transfer or `call`).
2. The payer's `receive()` function triggers automatically.
3. Funds are forwarded to the project's terminal.
4. If in `pay` mode, project tokens are minted to the configured beneficiary.
5. If in `addToBalanceOf` mode, funds are added to the project balance without minting tokens.

**Failure Modes**:
- Transaction reverts if no terminal is found for the project.
- Transaction reverts if the terminal itself reverts (e.g., paused project).

**Postconditions**:
- The project's terminal balance increases by the payment amount.
- If in `pay` mode, project tokens are minted to the beneficiary.

## Journey 3: Integrator Routes ERC20 Tokens

**Actor**: A contract or frontend routing ERC20 payments

**Intent**: Route ERC20 tokens to a Juicebox project through the project payer.

**Preconditions**:
- The caller has approved the project payer for the token amount.
- The project has a terminal that accepts the token.

**Main Flow**:
1. Call `pay()` or `addToBalanceOf()` with the token address and amount.
2. The payer transfers tokens from the caller.
3. The payer approves the terminal and forwards the tokens.

**Failure Modes**:
- Reverts if `msg.value > 0` when paying with an ERC20 token.
- Reverts if the caller hasn't approved the payer for the token amount.
- Reverts if no terminal is found for the project and token.

**Postconditions**:
- Tokens are transferred from the caller to the project's terminal.
- If using `pay()`, project tokens are minted to the specified beneficiary.

## Trust Boundaries

- The project payer trusts `JBDirectory` to return the correct terminal.
- The project payer trusts the terminal to handle funds correctly.
- The owner is trusted to configure sensible defaults.

## Hand-Offs

- Funds are handed off to the project's terminal (`IJBTerminal.pay()` or `IJBTerminal.addToBalanceOf()`).
- From there, the terminal handles recording, token minting, and hook execution per the standard Juicebox V6 flow.
