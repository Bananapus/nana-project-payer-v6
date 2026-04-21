# Risks

## Runtime Risks

### R-1: Terminal Not Found

**Severity**: Medium
**Description**: If the project has no terminal registered for the given token, `_pay` and `_addToBalanceOf` revert with `JBProjectPayer_TerminalNotFound`. ETH sent via `receive()` will also revert.
**Mitigation**: Ensure the project has a terminal set up for the expected token before deploying a project payer. Payments revert cleanly — no funds are lost.

### R-2: tx.origin Beneficiary Fallback

**Severity**: Low
**Description**: When no beneficiary is configured (`defaultBeneficiary == address(0)`) and no beneficiary is provided in `pay()`, `tx.origin` is used. For smart contract wallets (multisigs, account abstraction), `tx.origin` may not be the intended recipient.
**Mitigation**: Always set `defaultBeneficiary` when deploying a project payer. The owner can update this at any time.

### R-3: Malicious Terminal via Directory

**Severity**: High (external dependency)
**Description**: The payer trusts `JBDirectory.primaryTerminalOf()` to return a legitimate terminal. If the directory is compromised or the project owner sets a malicious terminal, funds are at risk.
**Mitigation**: This is a protocol-level concern. The payer cannot independently verify terminal legitimacy. Users should verify the project's terminal configuration before sending large amounts.

### R-4: ERC20 Residual Allowance

**Severity**: Low
**Description**: After `forceApprove`, if the terminal does not pull the full approved amount (e.g., terminal reverts after approval), the terminal retains an allowance on the payer's tokens.
**Mitigation**: `forceApprove` resets the allowance each time, so stale allowances from previous calls don't accumulate. The terminal is already trusted to process funds.

### R-5: Stuck Tokens

**Severity**: Low
**Description**: ERC20 tokens sent directly to the payer contract (not via `pay()` or `addToBalanceOf()`) cannot be recovered. There is no sweep function.
**Mitigation**: Document this limitation. The payer is designed for programmatic use, not as a general-purpose wallet.

## Admin Risks

### A-1: Owner Changes Defaults

**Severity**: Low
**Description**: The owner can change `defaultProjectId` and `defaultBeneficiary`, redirecting future `receive()` payments to a different project or beneficiary.
**Mitigation**: This is by design. Users who don't trust the owner should verify defaults before sending funds, or use the explicit `pay()` function with explicit parameters.

### A-2: Renounced Ownership

**Severity**: Low
**Description**: If ownership is renounced, defaults become permanently immutable. If the project migrates or the beneficiary changes, a new payer must be deployed.
**Mitigation**: Only renounce ownership when defaults are known to be final.

## Deployment Risks

### D-1: Wrong Directory

**Severity**: High
**Description**: The directory is immutable — set at the implementation constructor. If the wrong directory is used, all clones from this deployer will look up terminals incorrectly.
**Mitigation**: Verify the directory address before deploying the factory. Deploy a new factory if needed.

## Integration Risks

### I-1: Fee-on-Transfer Tokens

**Severity**: Low
**Description**: Fee-on-transfer tokens are supported. The actual amount received (after fee) is forwarded, which may be less than the caller expected.
**Mitigation**: The payer correctly measures balance changes. Callers should account for the fee when specifying `minReturnedTokens`.

### I-2: Rebasing Tokens

**Severity**: Medium
**Description**: Rebasing tokens (whose balances change over time) may behave unexpectedly. The balance measurement happens atomically, so positive rebases between calls won't be captured, and negative rebases could reduce the forwarded amount.
**Mitigation**: Rebasing tokens are not recommended for use with the project payer. Use wrapped versions instead.
