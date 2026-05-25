# Risks

## Runtime Risks

### R-1: Terminal Not Found

**Severity**: Medium
**Description**: If the project has no terminal registered for the given token, `_pay` and `_addToBalanceOf` revert with `JBProjectPayer_TerminalNotFound`. ETH sent via `receive()` will also revert.
**Mitigation**: Ensure the project has a terminal set up for the expected token before deploying a project payer. Payments revert cleanly — no funds are lost.

### R-2: msg.sender Beneficiary Fallback

**Severity**: Low
**Description**: When no beneficiary is configured (`defaultBeneficiary == address(0)`) and no beneficiary is provided in `pay()`, `msg.sender` is used. For smart contract wallets, relayers, and account abstraction flows, `msg.sender` may not be the intended token recipient.
**Mitigation**: Set `defaultBeneficiary` when deploying a project payer, or pass an explicit beneficiary to `pay()`. The owner can update defaults at any time.

### R-3: Malicious Terminal via Directory

**Severity**: High (external dependency)
**Description**: The payer trusts `JBDirectory.primaryTerminalOf()` to return a legitimate terminal. If the directory is compromised or the project owner sets a malicious terminal, funds are at risk.
**Mitigation**: This is a protocol-level concern. The payer cannot independently verify terminal legitimacy. Users should verify the project's terminal configuration before sending large amounts.

### R-4: ERC-20 Residual Allowance

**Severity**: Low
**Description**: ERC-20 forwarding temporarily approves the selected terminal so it can pull funds during `pay` or `addToBalanceOf`. A terminal that returns after pulling less than the approved amount would otherwise leave a live allowance against any tokens still held by the payer.
**Mitigation**: The payer clears the terminal's allowance after successful `pay` and `addToBalanceOf` calls. If the terminal reverts, the whole transaction reverts, including the temporary approval. Direct ERC-20 transfers to the payer are still not recoverable, as covered by R-5.

### R-5: Stuck Tokens

**Severity**: Low
**Description**: ERC-20 tokens sent directly to the payer contract (not via `pay()` or `addToBalanceOf()`) cannot be recovered. There is no sweep function.
**Mitigation**: Document this limitation. The payer is designed for programmatic use, not as a general-purpose wallet.

### R-6: Original-Payer Transient Exposure

**Severity**: Low
**Description**: `JBProjectPayer` implements `IJBPayerTracker` and sets a transient `originalPayer = msg.sender` for the duration of each `_pay` / `_addToBalanceOf` forward. Downstream router-style terminals read this slot to resolve partial-fill refunds and credit cash-outs to the original caller instead of the payer contract. A misbehaving subclass that writes `originalPayer` without restoring the prior value could leak payer identity into unrelated nested calls.
**Mitigation**: Subclasses must use the save / set / restore pattern in `_pay` and `_addToBalanceOf` (the base implementation does this). The transient slot resets to zero at the end of each transaction, so the worst case is a single call frame seeing the wrong payer.

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
