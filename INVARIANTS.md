# Invariants of `nana-project-payer-v6`

Scope: the two production contracts in `src/` — `JBProjectPayer` and `JBProjectPayerDeployer` — plus the two interfaces in `src/interfaces/` (`IJBProjectPayer`, `IJBProjectPayerDeployer`) and `src/interfaces/IJBPayerTracker.sol`. `JBProjectPayer` is an EIP-1167 cloneable per-user payment relay that auto-forwards received ETH (via `receive()`) or explicitly routed ETH/ERC-20 (via `pay`/`addToBalanceOf`) to a configured Juicebox project's primary terminal. A transient `originalPayer` slot is exposed on `IJBPayerTracker` so downstream router-style terminals can resolve partial-fill refunds and credit cash-outs to the true upstream payer instead of the intermediary clone.

This file is the per-repo scoped invariants doc. The protocol-wide guarantees for the V6 deploy live in [`../INVARIANTS.md`](../INVARIANTS.md). The `RISKS.md` in this repo enumerates the runtime/admin/deployment/integration risk-set this invariants doc operationally implements; `ARCHITECTURE.md` is the higher-altitude system overview.

---

# Section A — Guarantees to Users (Payers)

"Users" here are anyone who sends ETH to a clone's `receive()` or calls `pay`/`addToBalanceOf` directly. There is no "holder" surface — the payer never custodies project tokens; the terminal mints directly to the beneficiary.

## A.1 Exact-amount forwarding

- **A.1.1 ETH forwarding is whole-msg.value on `receive()`.** The fallback receive path forwards exactly `msg.value` to `terminal.pay` or `terminal.addToBalanceOf` via `_pay`/`_addToBalanceOf` (`src/JBProjectPayer.sol:101–121, 333, 345, 392, 404`). No retained balance, no fee deduction at this layer, no batching — every received ETH leaves in the same transaction.
- **A.1.2 ETH forwarding on explicit `pay`/`addToBalanceOf` uses `msg.value`.** When `token == JBConstants.NATIVE_TOKEN`, the entrypoint overwrites the `amount` parameter with `msg.value` (`src/JBProjectPayer.sol:233–236, 279–282`). A caller cannot accidentally instruct the payer to forward a different number than the ETH it actually sent — the `amount` arg is ignored for native-token paths.
- **A.1.3 ERC-20 forwarding uses balance-delta accounting.** Both `pay` and `addToBalanceOf` snapshot `IERC20(token).balanceOf(address(this))` before `safeTransferFrom`, then recompute `amount = balanceAfter - balanceBefore` (`src/JBProjectPayer.sol:225–232, 271–278`). Fee-on-transfer tokens are forwarded at the actually-received amount, not the nominal pull amount — a fee-on-transfer token cannot trick the payer into approving the terminal for more than it holds. (Pre-existing token balances on the clone are NOT swept into the forwarded amount: the delta only measures THIS pull. R-5 / I-1.)
- **A.1.4 `msg.value` rejected on ERC-20 paths.** If `token != NATIVE_TOKEN` and `msg.value > 0`, both `pay` and `addToBalanceOf` revert `JBProjectPayer_NoMsgValueAllowed` BEFORE the `safeTransferFrom` pull (`src/JBProjectPayer.sol:222–223, 268–269`). A caller cannot strand ETH inside the clone by accidentally attaching it to an ERC-20 path.

## A.2 Beneficiary resolution

- **A.2.1 Explicit beneficiary always honored.** `_pay` uses the caller-supplied `beneficiary` when non-zero (`src/JBProjectPayer.sol:349–351`). The default beneficiary and `msg.sender` fallbacks only apply when the caller passes `address(0)`.
- **A.2.2 Zero-beneficiary falls back to `defaultBeneficiary`, then to `msg.sender`.** `_pay` evaluates `beneficiary != 0 ? beneficiary : defaultBeneficiary != 0 ? defaultBeneficiary : msg.sender` (`src/JBProjectPayer.sol:349–351`). When the clone owner has not set a default, the direct caller becomes the recipient — note R-2 in `RISKS.md`: smart-contract callers / relayers may receive tokens at an unexpected address. The `receive()` path uses the same resolution chain (`src/JBProjectPayer.sol:115`).
- **A.2.3 `addToBalanceOf` has no beneficiary.** The protocol-level semantics of `addToBalanceOf` are "donate without minting", so no beneficiary parameter exists on the entrypoint or in `_addToBalanceOf` (`src/JBProjectPayer.sol:255–285, 370–418`). Calling `receive()` with `defaultAddToBalance = true` routes through `_addToBalanceOf` and no project tokens are minted to anyone (`src/JBProjectPayer.sol:102–110`).

## A.3 `originalPayer` transient — refund routing across router-terminal hops

- **A.3.1 Set BEFORE the terminal call, restored AFTER.** Both `_pay` and `_addToBalanceOf` save the prior `originalPayer`, write the resolved upstream into the transient slot, invoke the terminal, then restore the saved value (`src/JBProjectPayer.sol:336–358, 395–414`). Restoring the prior value (rather than zeroing it) preserves correctness when a nested pay-hook calls back into a tracker that itself wraps this payer.
- **A.3.2 Resolution propagates upstream tracker chains.** `_originalPayerOrSender` returns `msg.sender` for EOAs / no-code callers, otherwise staticcalls `IJBPayerTracker.originalPayer()` on the immediate caller. On a non-zero return, that upstream payer is recorded; on revert, non-conformant payload, or zero return, the direct caller is recorded (`src/JBProjectPayer.sol:431–448`). A chain `user → trackerA → trackerB → thisPayer → terminal` results in `terminal` reading `originalPayer == user`, not `trackerB`.
- **A.3.3 Staticcall is failure-safe.** A reverting or interface-non-conformant caller does not bubble up — `_originalPayerOrSender` falls back to `msg.sender` (`src/JBProjectPayer.sol:437–442`). A hostile EOA-like contract that reverts on `originalPayer()` cannot DoS the forwarding.
- **A.3.4 Transient slot is automatically cleared at end of tx.** Solidity `transient` storage zeroes at end-of-transaction. Combined with A.3.1 (save/restore at every call boundary inside this contract), the worst case is a single call frame reading the wrong payer (R-6) — never a persistent leak between transactions.
- **A.3.5 EOAs always recorded as their own caller.** The `msg.sender.code.length == 0` short-circuit guarantees an EOA payer is never re-attributed to a "phantom upstream" via a malicious returndata (`src/JBProjectPayer.sol:433`). EOAs cannot implement `IJBPayerTracker`.

## A.4 Terminal lookup

- **A.4.1 Terminal resolved at call time, not at clone-init time.** Both `_pay` and `_addToBalanceOf` call `DIRECTORY.primaryTerminalOf({projectId, token})` immediately before forwarding (`src/JBProjectPayer.sol:322, 381`). A project that swaps its primary terminal between two payer calls routes the second call to the new terminal — the clone holds no cached terminal reference.
- **A.4.2 Missing terminal reverts cleanly with parameters.** If `DIRECTORY.primaryTerminalOf` returns `address(0)`, both `_pay` and `_addToBalanceOf` revert `JBProjectPayer_TerminalNotFound({projectId, token})` (`src/JBProjectPayer.sol:325–327, 384–386`). No funds are silently held — the ETH or ERC-20 pull either reverts atomically or never happens.

## A.5 ERC-20 allowance hygiene

- **A.5.1 `forceApprove` before terminal call, reset to 0 after.** `_pay` and `_addToBalanceOf` both call `forceApprove(terminal, amount)` before the terminal interaction and `forceApprove(terminal, 0)` after (`src/JBProjectPayer.sol:330, 361, 389, 417`). A terminal that pulls less than `amount` (partial-fill, slippage refund) cannot leave a standing allowance against subsequent tokens that later land on the clone (R-4).
- **A.5.2 Native-token path skips approval entirely.** The approval branch is gated on `token != NATIVE_TOKEN` (`src/JBProjectPayer.sol:330, 361, 389, 417`). The terminal receives ETH via `{value: payableValue}` on the `pay`/`addToBalanceOf` call, where `payableValue == amount` only for the native-token branch (`src/JBProjectPayer.sol:333, 392`).

---

# Section B — Guarantees to Clone Owners

Each clone has a single `owner` set at `initialize` time. The owner controls the default routing parameters for the `receive()` and direct-call paths.

## B.1 Default-value control

- **B.1.1 `setDefaultValues` is `onlyOwner`.** The mutator updates `defaultProjectId`, `defaultBeneficiary`, `defaultMemo`, `defaultMetadata`, `defaultAddToBalance` and emits `SetDefaultValues` (`src/JBProjectPayer.sol:167–193`). Only the address returned by `Ownable.owner()` can call it.
- **B.1.2 Initial owner set by deployer factory.** `initialize` calls `_transferOwnership(owner)` using the `owner` parameter forwarded by `JBProjectPayerDeployer.deployProjectPayer` (`src/JBProjectPayer.sol:157`, `src/JBProjectPayerDeployer.sol:51, 67`). The factory always uses the caller-supplied `owner`, so the deployer's `msg.sender` is NOT automatically the clone owner unless they pass themselves.
- **B.1.3 Owner cannot access held funds.** There is no `withdraw`, `sweep`, or `transfer` entrypoint. The owner can only redirect FUTURE inbound funds by changing defaults; ERC-20 tokens transferred directly to the clone (outside `pay`/`addToBalanceOf`) are unrecoverable (R-5 / `ARCHITECTURE.md` Security Model).
- **B.1.4 Owner can renounce.** `Ownable.renounceOwnership` is inherited and not blocked. Renouncing freezes defaults permanently (`RISKS.md` A-2) — no further `setDefaultValues` is possible.
- **B.1.5 No effect on `pay`/`addToBalanceOf` semantics.** Defaults govern the `receive()` path and the `address(0)` beneficiary fallback only (A.2.2, A.1.1). An explicit `pay(projectId, token, amount, beneficiary, ...)` ignores every default field except the `defaultBeneficiary` fallback (which is bypassed when caller passes a non-zero beneficiary).

## B.2 Initialization

- **B.2.1 `initialize` is one-shot per clone, deployer-only.** The guard `if (msg.sender != DEPLOYER) revert JBProjectPayer_AlreadyInitialized` is the SOLE re-init defense (`src/JBProjectPayer.sol:146–147`). Because the implementation's constructor sets `DEPLOYER = msg.sender` (the factory) and the factory calls `initialize` exactly once inside `deployProjectPayer` (`src/JBProjectPayerDeployer.sol:60–68`), a second `initialize` call from any other address — including the same factory in a second transaction — reverts. The implementation contract itself can never be initialized because the constructor sets `DEPLOYER = msg.sender = factoryConstructor`, and the factory's only caller of `initialize` is its own `deployProjectPayer` (which clones a fresh address each call). Re-initialization of an already-deployed clone is structurally impossible.
- **B.2.2 No "implementation lock" needed.** The above means the implementation address is benign — calling `initialize` on it would have to come from `DEPLOYER == factoryAddress`, and the factory only calls `initialize` on freshly-cloned addresses. No `_disableInitializers` (OpenZeppelin Initializable pattern) is required because re-init protection is enforced by the deployer check, not a flag.

---

# Section C — Per-Contract Operation Inventory

## C.1 `JBProjectPayer` — `src/JBProjectPayer.sol`

### Constructor (implementation only, runs once)

- **`constructor(IJBDirectory directory)`** (`src/JBProjectPayer.sol:89–92`) — sets `DIRECTORY` and `DEPLOYER = msg.sender`, calls `Ownable(msg.sender)`. Runs on the IMPLEMENTATION contract; clones do NOT re-run the constructor (EIP-1167), so they inherit the implementation's immutables via delegatecall-on-immutable-read semantics... no, wait — `DIRECTORY` and `DEPLOYER` are `immutable` so they are baked into the implementation's runtime bytecode. EIP-1167 clones delegatecall to the implementation, so every clone reads the same `DIRECTORY` and `DEPLOYER` values. This is correct and intentional: one factory per directory; one implementation per factory.

### Initialization (deployer-only, one-shot per clone)

- **`initialize(uint256 projectId, address payable beneficiary, string memo, bytes metadata, bool addToBalance, address owner)`** (`src/JBProjectPayer.sol:135–158`) — only `DEPLOYER` (the factory). Sets the five default-* state slots and calls `_transferOwnership(owner)`. Reverts: `JBProjectPayer_AlreadyInitialized` for any non-deployer caller.
  - **Invariants:** B.2.1, B.1.2.

### Owner-only configuration

- **`setDefaultValues(uint256 projectId, address payable beneficiary, string memo, bytes metadata, bool addToBalance) onlyOwner`** (`src/JBProjectPayer.sol:167–193`) — clone owner only. Overwrites the five default-* slots, emits `SetDefaultValues`. Reverts: `OwnableUnauthorizedAccount` from OpenZeppelin's `_checkOwner`.
  - **Invariants:** B.1.1, B.1.5.

### Permissionless payment entrypoints

- **`pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata) payable`** (`src/JBProjectPayer.sol:207–247`) — anyone. ETH path: amount overwritten to `msg.value`. ERC-20 path: rejects `msg.value > 0`, pulls via `safeTransferFrom`, computes `amount = balanceAfter - balanceBefore`, calls `_pay`. Reverts: `JBProjectPayer_NoMsgValueAllowed`, plus `JBProjectPayer_TerminalNotFound` from `_pay` if the project has no primary terminal for `token`.
  - **Invariants:** A.1.2, A.1.3, A.1.4, A.2.1, A.2.2, A.4.1, A.4.2, A.5.1, A.5.2, A.3.1–A.3.5.

- **`addToBalanceOf(uint256 projectId, address token, uint256 amount, string memo, bytes metadata) payable`** (`src/JBProjectPayer.sol:255–285`) — anyone. Same input handling as `pay` (ETH/ERC-20 split, balance-delta, msg.value rejection on ERC-20). Calls `_addToBalanceOf` which passes `shouldReturnHeldFees: false`. No beneficiary, no `minReturnedTokens`.
  - **Invariants:** A.1.2, A.1.3, A.1.4, A.2.3, A.4.1, A.4.2, A.5.1, A.5.2, A.3.1–A.3.5.

- **`receive() external payable virtual`** (`src/JBProjectPayer.sol:101–121`) — anyone. Inspects `defaultAddToBalance`. If true, calls `_addToBalanceOf(defaultProjectId, NATIVE_TOKEN, msg.value, defaultMemo, defaultMetadata)`. If false, calls `_pay` with `beneficiary = defaultBeneficiary != 0 ? defaultBeneficiary : msg.sender` and `minReturnedTokens: 0`. Reverts: `JBProjectPayer_TerminalNotFound` if the project has no native-token primary terminal.
  - **Invariants:** A.1.1, A.2.2, A.2.3, A.4.1, A.4.2, A.3.1–A.3.5.

### Views

- **`originalPayer() external view → address`** (transient, `src/JBProjectPayer.sol:81`) — public transient slot getter, satisfies `IJBPayerTracker`. Returns the upstream payer for the current call frame, or zero outside `_pay`/`_addToBalanceOf`.
- **`DIRECTORY() / DEPLOYER()`** — public immutables.
- **`defaultProjectId() / defaultBeneficiary() / defaultMemo() / defaultMetadata() / defaultAddToBalance()`** — public storage getters for the five default-* slots.
- **`supportsInterface(bytes4) → bool`** (`src/JBProjectPayer.sol:292–295`) — ERC-165 for `IJBProjectPayer`, `IJBPayerTracker`, and inherited (`IERC165`).
- **`owner() / pendingOwner()` etc.** — inherited from OpenZeppelin `Ownable`.

### Internal helpers

- **`_pay(uint256 projectId, address token, uint256 amount, address beneficiary, uint256 minReturnedTokens, string memo, bytes metadata) internal virtual`** (`src/JBProjectPayer.sol:309–362`) — looks up terminal via `DIRECTORY.primaryTerminalOf`, force-approves (ERC-20 only), saves prior `originalPayer`, writes new transient `originalPayer = _originalPayerOrSender()`, calls `terminal.pay{value: payableValue}`, restores prior `originalPayer`, resets allowance to zero (ERC-20 only).
- **`_addToBalanceOf(uint256 projectId, address token, uint256 amount, string memo, bytes metadata) internal virtual`** (`src/JBProjectPayer.sol:370–418`) — same shape as `_pay`, calling `terminal.addToBalanceOf{value: payableValue}({ ..., shouldReturnHeldFees: false, ... })`.
- **`_originalPayerOrSender() internal view → address`** (`src/JBProjectPayer.sol:431–448`) — short-circuits to `msg.sender` for EOAs (`code.length == 0`); otherwise staticcalls `IJBPayerTracker.originalPayer()` and propagates the non-zero upstream, else falls back to `msg.sender`. Failure-safe (revert, short payload, zero return all fall back to caller).

## C.2 `JBProjectPayerDeployer` — `src/JBProjectPayerDeployer.sol`

### Constructor (one-shot at factory deployment)

- **`constructor(IJBDirectory directory)`** (`src/JBProjectPayerDeployer.sol:28–31`) — deploys a fresh `JBProjectPayer` implementation (`new JBProjectPayer(directory)`), captures its address as `IMPLEMENTATION`, stores `DIRECTORY = directory`. The implementation's `DEPLOYER` immutable becomes the factory's own address (since the factory's constructor is `msg.sender` to `new JBProjectPayer`).

### Permissionless clone deployment

- **`deployProjectPayer(uint256 defaultProjectId, address payable defaultBeneficiary, string defaultMemo, bytes defaultMetadata, bool defaultAddToBalance, address owner) external → IJBProjectPayer projectPayer`** (`src/JBProjectPayerDeployer.sol:45–81`) — anyone. Clones the implementation via `Clones.clone(IMPLEMENTATION)`, calls `projectPayer.initialize(...)` with the supplied defaults and owner, emits `DeployProjectPayer`. Reverts: any propagated revert from the clone's `initialize` (none expected on the happy path because the factory is `DEPLOYER`).
  - **Invariants:** B.1.2 (caller chooses arbitrary owner), B.2.1 (single init per clone, factory-only).

### Views

- **`IMPLEMENTATION() / DIRECTORY()`** — public immutables.

---

# Section D — Cross-Cutting Invariants

- **D.1 Atomic forwarding — no held balances by design.** Every entrypoint that accepts funds (`receive`, `pay`, `addToBalanceOf`) forwards them in the same transaction via `_pay` / `_addToBalanceOf`. The clone has no escrow state, no buffered queue, no scheduled-send. `ARCHITECTURE.md` Core Invariant 1 codifies this.
- **D.2 Balance-delta accounting on every ERC-20 pull.** A.1.3 applies to both `pay` and `addToBalanceOf`. Fee-on-transfer tokens (I-1) are forwarded at the realized amount, not the nominal one — the `forceApprove(terminal, amount)` immediately following uses the delta, so the terminal can pull exactly what landed, not more.
- **D.3 `msg.value` rejected on every ERC-20 path.** A.1.4 applies symmetrically. The only entry surface where `msg.value` is legitimately non-zero is the native-token branch of `pay`/`addToBalanceOf` and `receive()`. A caller that attaches ETH to an ERC-20 call gets `JBProjectPayer_NoMsgValueAllowed` BEFORE any state change.
- **D.4 `originalPayer` save-set-restore on every forward.** Both `_pay` (`src/JBProjectPayer.sol:336, 342, 358`) and `_addToBalanceOf` (`395, 401, 414`) follow the save-prior / set-new / restore-prior pattern. R-6 notes that subclasses overriding `_pay` / `_addToBalanceOf` MUST preserve this pattern; the base impl does. Transient storage clears at end of tx, so cross-transaction leakage is impossible.
- **D.5 Allowance reset to 0 after every ERC-20 forward.** A.5.1 applies to both `_pay` and `_addToBalanceOf`. Defense-in-depth against an underpulling terminal.
- **D.6 Terminal looked up fresh per call.** A.4.1 applies on every forward. The clone never caches a terminal address. Project terminal swaps take effect on the very next forward.
- **D.7 Re-init structurally impossible after clone deployment.** B.2.1 — `DEPLOYER` is the factory immutable; the factory only calls `initialize` on a freshly-cloned address within its `deployProjectPayer` transaction. No second caller can pass the `msg.sender == DEPLOYER` check.
- **D.8 Owner has no fund-access surface.** B.1.3 — there is no withdrawal, sweep, or rescue function. The owner's authority is bounded to redirecting future inbound flow via `setDefaultValues`. Tokens transferred directly to the clone (not through `pay`/`addToBalanceOf`) cannot be recovered (R-5).
- **D.9 ERC-165 declares `IJBProjectPayer` and `IJBPayerTracker`.** `supportsInterface` returns true for both `type(IJBProjectPayer).interfaceId` and `type(IJBPayerTracker).interfaceId` (`src/JBProjectPayer.sol:292–295`). Downstream router terminals can sniff the tracker interface before staticcalling `originalPayer()`.
- **D.10 EOA short-circuit prevents tracker spoofing.** A.3.5 — `_originalPayerOrSender` checks `code.length == 0` before any external probe (`src/JBProjectPayer.sol:433`). An EOA cannot return a fabricated upstream; only contract callers can declare themselves trackers.

---

# Section E — Centralization Caveats

**Per-clone centralization:** each clone has a single `owner`, set freely at deploy time by whoever calls `deployProjectPayer` (B.1.2). The owner can:

- Change which project receives `receive()`-forwarded funds (`defaultProjectId`).
- Change the default beneficiary, memo, metadata, and `pay`-vs-`addToBalanceOf` routing mode.
- Renounce ownership, freezing defaults permanently (A-2 in `RISKS.md`).

The owner CANNOT:

- Access funds held by the clone (no withdraw surface, D.8 / B.1.3).
- Override the `pay` / `addToBalanceOf` semantics for callers who pass explicit parameters (B.1.5).
- Re-initialize the clone (D.7).
- Replace the `DIRECTORY` or `DEPLOYER` (immutable per implementation, baked into bytecode).

**Factory-level centralization:** the factory itself has NO owner, NO admin, NO pause. Its only state is the immutable `IMPLEMENTATION` and `DIRECTORY`. A misconfigured `directory` at constructor time produces a permanently mis-routed factory (D-1 in `RISKS.md`); recovery is "deploy a new factory". The factory does not deduplicate clones — calling `deployProjectPayer` twice with identical args produces two independent clones (Clones.clone uses CREATE, not CREATE2, in this codebase).

**Implementation-level centralization:** the implementation is the address returned by `new JBProjectPayer(directory)` in the factory's constructor. It is itself uninitialized (no `setDefaultValues` was called against it). Calling `initialize` on the implementation reverts because `msg.sender` is not the factory (B.2.1). The implementation is benign.

**Upstream-protocol centralization affecting this repo:**

- **`JBDirectory`** is trusted to return the correct primary terminal per project/token. If the directory is compromised or the project owner sets a malicious terminal, funds are at risk (R-3). The payer cannot independently verify terminal legitimacy — this is the project owner's surface, not this contract's. See `nana-core-v6/INVARIANTS.md` for `JBDirectory`'s own invariants.
- **`JBPermissions` / `Ownable`** is the only access-control primitive in this repo. The clone uses OpenZeppelin `Ownable` (not JB permission IDs) — owner privilege is per-clone, not protocol-wide.

---

# Section F — Key Code References

| Invariant | File:lines |
|---|---|
| A.1.1 (whole-msg.value forwarding on `receive`) | `src/JBProjectPayer.sol:101–121` |
| A.1.2, D.3 (msg.value overrides `amount` for native, rejected on ERC-20) | `src/JBProjectPayer.sol:222–236, 268–282` |
| A.1.3, D.2 (balance-delta on ERC-20 pull) | `src/JBProjectPayer.sol:225–232, 271–278` |
| A.1.4, D.3 (`NoMsgValueAllowed` on ERC-20 path) | `src/JBProjectPayer.sol:222–223, 268–269` |
| A.2.1, A.2.2 (beneficiary resolution chain in `_pay`) | `src/JBProjectPayer.sol:349–351` |
| A.2.2 (receive() beneficiary fallback) | `src/JBProjectPayer.sol:115` |
| A.2.3 (`shouldReturnHeldFees: false` in addToBalanceOf) | `src/JBProjectPayer.sol:408` |
| A.3.1, D.4 (save-set-restore `originalPayer` in `_pay`) | `src/JBProjectPayer.sol:336–358` |
| A.3.1, D.4 (save-set-restore `originalPayer` in `_addToBalanceOf`) | `src/JBProjectPayer.sol:395–414` |
| A.3.2 (upstream tracker propagation) | `src/JBProjectPayer.sol:431–448` |
| A.3.3 (failure-safe staticcall fallback) | `src/JBProjectPayer.sol:437–442` |
| A.3.4 (transient slot declaration) | `src/JBProjectPayer.sol:81` |
| A.3.5, D.10 (EOA short-circuit) | `src/JBProjectPayer.sol:433` |
| A.4.1, D.6 (terminal looked up at call time) | `src/JBProjectPayer.sol:322, 381` |
| A.4.2 (`TerminalNotFound` revert) | `src/JBProjectPayer.sol:325–327, 384–386` |
| A.5.1, D.5 (`forceApprove` set + reset) | `src/JBProjectPayer.sol:330, 361, 389, 417` |
| A.5.2 (approval gated on non-native token) | `src/JBProjectPayer.sol:330, 361, 389, 417` |
| B.1.1 (`setDefaultValues` onlyOwner + emit) | `src/JBProjectPayer.sol:167–193` |
| B.1.2 (owner passed through from factory) | `src/JBProjectPayer.sol:157`, `src/JBProjectPayerDeployer.sol:51, 67` |
| B.2.1, D.7 (deployer-only one-shot `initialize`) | `src/JBProjectPayer.sol:146–147` |
| C.1 implementation constructor (immutables) | `src/JBProjectPayer.sol:89–92` |
| C.1 ERC-165 (`IJBProjectPayer`, `IJBPayerTracker`) | `src/JBProjectPayer.sol:292–295` |
| C.2 factory constructor (impl deploy + dir capture) | `src/JBProjectPayerDeployer.sol:28–31` |
| C.2 `deployProjectPayer` (clone + initialize + event) | `src/JBProjectPayerDeployer.sol:45–81` |

---

# Doc audit notes

Pass over the existing top-level docs:

- **README.md** — current; the cloneable-payer-relay mental model matches the source. No edits.
- **ARCHITECTURE.md** — current; the "Core Invariants" (5 bullets) overlap with sections A/D here at higher altitude and remain a useful quick-reference. No edits.
- **RISKS.md** — current; R-1 through R-6, A-1, A-2, D-1, I-1, I-2 each map to one or more invariants here (most explicitly cited inline above). The R-6 / D.4 cross-reference on subclass override safety is intentional.
- **USER_JOURNEYS.md** — current.
- **ADMINISTRATION.md** — current; the "no fund-access surface for owner" posture matches B.1.3 / D.8.
- **AUDIT_INSTRUCTIONS.md** — current.
- **SKILLS.md** — current.
- **CHANGELOG.md** — current.
- **STYLE_GUIDE.md** — repo-internal style ref, unaffected.

No staleness corrections, no contradictions found.
