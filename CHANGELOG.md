# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the
ecosystem delta.

## In-v6 changes

### `0.0.10` — `JBProjectPayer` exposes `IJBPayerTracker`

`JBProjectPayer` now implements `IJBPayerTracker` so router-style terminals (e.g.
`JBRouterTerminal._resolveOriginalPayer`) can resolve partial-fill ERC-20 refunds and credit
cash-outs to the **original caller** instead of the forwarding payer contract. Before this
change, downstream router terminals fell back to `msg.sender == JBProjectPayer` as the refund
target, and there is no sweep path on the payer — funds permanently stuck.

- New interface: `src/interfaces/IJBPayerTracker.sol` (single view, `originalPayer()`).
- New transient slot: `JBProjectPayer.originalPayer` set to `msg.sender` for the duration of
  each `_pay` / `_addToBalanceOf` forward, with save/restore so nested pay-hook reentry
  restores the outer payer.
- `JBProjectPayer.supportsInterface` now reports `type(IJBPayerTracker).interfaceId` in
  addition to `IJBProjectPayer` and `IERC165`.

Indexer impact: none — view-only addition.

Integrator impact: contracts that previously expected stuck ERC-20 leftovers on a project
payer after a router-routed partial-fill cash-out will no longer see them; the leftover is
returned to the original payer EOA or contract that called `pay` / `addToBalanceOf`.

## Current v6 Surface

- `JBProjectPayer`
- `JBProjectPayerDeployer`
- `IJBProjectPayer`
- `IJBPayerTracker`
- `IJBProjectPayerDeployer`

## Summary

- This repo introduces a v6-era project payer package for Juicebox projects.
- `JBProjectPayerDeployer` deploys EIP-1167 clones of `JBProjectPayer`.
- Each payer clone can receive ETH directly and forward it to a configured project's primary terminal.
- Explicit `pay(...)` and `addToBalanceOf(...)` calls can route ERC-20 tokens or native token payments with
  caller-provided parameters.
- Fee-on-transfer ERC-20 tokens are handled with balance-delta accounting before terminal forwarding.
- Default routing values are owner-controlled per clone: project ID, beneficiary, memo, metadata, and
  pay-vs-add-to-balance mode.

## Migration Notes

- Do not count this repo in the deployed v5-to-v6 ecosystem summary.
- Treat it as a new v6 payment-routing utility. Integrations should verify the current terminal from `JBDirectory` and
  set explicit beneficiaries for relayed or contract-based payments.
