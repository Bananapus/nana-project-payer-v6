# Changelog

## 0.0.21

- Raise dependency floors to the latest published versions.
- Document NatSpec, comment, and lint conventions in `STYLE_GUIDE.md`.

## 0.0.12 — Bump nana-core-v6 to ^0.0.53

- `@bananapus/core-v6`: `^0.0.48 → ^0.0.53` ([PR #145](https://github.com/Bananapus/nana-core-v6/pull/145)).
- All `JBRulesetMetadata` test literals patched to include `pauseCrossProjectFeeFreeInflows: false`.

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the
ecosystem delta.

## In-v6 changes

### `0.0.10` — `JBProjectPayer` exposes `IJBPayerTracker`

`JBProjectPayer` implements `IJBPayerTracker` so router-style terminals (e.g.
`JBRouterTerminal._resolveOriginalPayer`) resolve partial-fill ERC-20 refunds and credit
cash-outs to the **original caller** instead of the forwarding payer contract. Without the
tracker, downstream router terminals fall back to `msg.sender == JBProjectPayer` as the refund
target, and because the payer has no sweep path, such funds are permanently stuck.

- New interface: `src/interfaces/IJBPayerTracker.sol` (single view, `originalPayer()`).
- New transient slot: `JBProjectPayer.originalPayer` set to `msg.sender` for the duration of
  each `_pay` / `_addToBalanceOf` forward, with save/restore so nested pay-hook reentry
  restores the outer payer.
- `JBProjectPayer.supportsInterface` reports `type(IJBPayerTracker).interfaceId` in
  addition to `IJBProjectPayer` and `IERC165`.

Indexer impact: none — view-only addition.

Integrator impact: a router-routed partial-fill cash-out returns the ERC-20 leftover to the
original payer EOA or contract that called `pay` / `addToBalanceOf`, rather than leaving it
stuck on the project payer.

## Current v6 surface

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

## Migration notes

- Do not count this repo in the deployed v5-to-v6 ecosystem summary.
- Treat it as a new v6 payment-routing utility. Integrations should verify the current terminal from `JBDirectory` and
  set explicit beneficiaries for relayed or contract-based payments.
