# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. `nana-project-payer-v6` has no deployed V5 package counterpart in `../../v5/evm`; it is a new V6 contract package.

## Current V6 Surface

- `JBProjectPayer`
- `JBProjectPayerDeployer`
- `IJBProjectPayer`
- `IJBProjectPayerDeployer`
- `IJBPayerTracker`

## Summary

- V6 introduces project payer clones that receive native tokens or ERC-20s and forward them to a project's terminal through `pay(...)` or `addToBalanceOf(...)`.
- Each clone stores default project, beneficiary, memo, metadata, and add-to-balance mode values.
- The deployer creates EIP-1167 minimal proxy clones and emits deployment metadata for indexers.
- The payer integrates with the V6 terminal token model, including explicit `token` and `amount` inputs for ERC-20 payments.

## ABI, Event, and Error Changes

- No V5 ABI exists to diff against. All project-payer ABI surface is new to V6.
- New payer functions:
  - `initialize(...)`
  - `setDefaultValues(...)`
  - `pay(uint256,address,uint256,address,uint256,string,bytes)`
  - `addToBalanceOf(uint256,address,uint256,string,bytes)`
  - default-value getters
- New deployer function:
  - `deployProjectPayer(...)`
- New events:
  - `SetDefaultValues`
  - `DeployProjectPayer`

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: none; this is a new V6 runtime ABI surface.
- Own-source ABI artifacts compared: V6 `5`, V5 `0`.
- Contract/interface coverage: `5` added, `0` removed, `0` shared names with ABI changes, `0` shared names ABI-identical.
- Shared-name ABI item deltas: `0` added, `0` removed, `0` modified.

Added V6 ABI artifacts:
- `IJBPayerTracker` from `src/interfaces/IJBPayerTracker.sol`: `1` functions, `0` events, `0` errors.
- `IJBProjectPayer` from `src/interfaces/IJBProjectPayer.sol`: `12` functions, `1` events, `0` errors.
- `IJBProjectPayerDeployer` from `src/interfaces/IJBProjectPayerDeployer.sol`: `3` functions, `1` events, `0` errors.
- `JBProjectPayer` from `src/JBProjectPayer.sol`: `16` functions, `2` events, `6` errors.
- `JBProjectPayerDeployer` from `src/JBProjectPayerDeployer.sol`: `3` functions, `1` events, `2` errors.

Generated event/error name deltas:
- Event names added:
  - `DeployProjectPayer`, `OwnershipTransferred`, `SetDefaultValues`.
- Error names added:
  - `FailedDeployment`, `InsufficientBalance`, `JBProjectPayer_AlreadyInitialized`, `JBProjectPayer_NoMsgValueAllowed`, `JBProjectPayer_TerminalNotFound`, `OwnableInvalidOwner`, `OwnableUnauthorizedAccount`, `SafeERC20FailedOperation`.

## Migration Notes

- Treat project payer addresses as new V6 helper contracts, not V5 terminal replacements.
- Index `DeployProjectPayer` to discover clones and `SetDefaultValues` to keep default routing state current.
- Use the V6 terminal token conventions for native-token and ERC-20 payments.
