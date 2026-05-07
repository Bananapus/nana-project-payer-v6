# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the
ecosystem delta.

## Current v6 Surface

- `JBProjectPayer`
- `JBProjectPayerDeployer`
- `IJBProjectPayer`
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
