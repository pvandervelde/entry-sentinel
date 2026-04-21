# Trade-offs — Entry Sentinel

This document records the significant architectural alternatives that were considered and the rationale for the choices made. Each decision also has a corresponding ADR in `docs/adr/`.

---

## 1. Detection Order: Deterministic-First vs AI-First vs AI-Only

**Decision**: Deterministic checks run first; AI is an optional second pass only when deterministic result is clean.

**ADR**: [ADR-0001](../adr/ADR-0001-deterministic-first-detection.md)

| Option | Pros | Cons |
|---|---|---|
| **Deterministic-first (chosen)** | Predictable, auditable, no prompt injection risk in the first pass; AI cannot be trivially manipulated into approving an issue that the deterministic pass would have caught | Requires maintaining a detection signature library; does not catch novel patterns the library hasn't seen |
| AI-first | May catch novel threats without signature updates | AI itself is the primary attack surface for prompt injection; an attacker optimises their payload against the AI first, bypassing the most effective defence |
| AI-only | Potentially broadest coverage; no signature maintenance | No auditability; AI can be manipulated; false positive rate is non-deterministic; response time for every issue depends on AI |
| Deterministic-only | Fully predictable, no external dependency | Cannot adapt to threats faster than signature updates; misses novel patterns |

**Why not AI-first**: The first-line defence against prompt injection must be resistant to prompt injection itself. An LLM-first approach means the attacker's payload reaches the LLM as the first meaningful operation. A deterministic pattern match cannot be manipulated by the content it is matching.

---

## 2. Approval Signing: Ed25519 vs HMAC vs No Signing

**Decision**: Ed25519 asymmetric signing for approval comments.

**ADR**: [ADR-0002](../adr/ADR-0002-ed25519-approval-signing.md)

| Option | Pros | Cons |
|---|---|---|
| **Ed25519 (chosen)** | Asymmetric: downstream services verify without requiring the private key; compact 64-byte signature; constant-time verification; well-established standard | Requires key distribution; key rotation invalidates prior approvals |
| HMAC-SHA256 | Simpler; no PKI | Symmetric: any downstream service holding the secret can also forge signatures; sharing the secret is a security liability |
| RSA-2048 or RSA-4096 | Widely understood | Very large signatures; slower; overkill for this use case |
| No signing | Simplest | No integrity guarantee; any comment matching the format would be trusted; trivially forgeable |

**Why not HMAC**: To verify a HMAC, you need the secret key. This means every downstream service (Triage Titan, Scope-Sage, CogWorks) needs access to the same secret — widening the attack surface significantly and creating a coordination burden.

---

## 3. Verdict Model: Binary vs Scored vs Multi-Class

**Decision**: Binary verdict only (`clean` or `suspect`); ambiguity resolves to `suspect`.

**ADR**: [ADR-0003](../adr/ADR-0003-binary-verdict-suspect-on-ambiguity.md)

| Option | Pros | Cons |
|---|---|---|
| **Binary (chosen)** | Simple; no downstream reasoning required; clear contract; ambiguity handled safely | No nuance; legitimate borderline issues require human review |
| Scored (e.g., 0.0–1.0) | Allows threshold tuning | Downstream services must agree on threshold; disagreement between services creates inconsistency; scores imply precision that doesn't exist |
| Multi-class (clean / suspicious / malicious) | More nuanced routing | More complex; downstream services must handle more states; middle states still require a policy decision |

**Why not scored**: A confidence score would need a threshold. That threshold would be a shared contract across all downstream services. Changing it would require coordinated deployment. Binary is cleaner and safer.

---

## 4. Failure Handling: Conservative vs Optimistic

**Decision**: Conservative failure handling — failed new issues remain unlabelled; failed edit events trigger quarantine.

**ADR**: [ADR-0004](../adr/ADR-0004-conservative-failure-handling.md)

| Option for new issues | Pros | Cons |
|---|---|---|
| **Unlabelled (chosen)** | Safe; watchdog catches the gap; human reviews | Requires watchdog; may delay legitimate issues |
| Auto-approve on failure | No delay | Risk of approving an issue that was not actually scanned |
| Auto-quarantine on failure | Consistent with edit failure policy | Increases quarantine queue noise; quarantine was not earned by the issue |

| Option for edit events | Pros | Cons |
|---|---|---|
| **Conservative quarantine (chosen)** | An unvalidated edit to an approved issue must be treated with suspicion; preserves pipeline integrity | May quarantine legitimate edits; increases human review load |
| Leave untouched on failure | Simpler | Allows potentially modified content to remain in an approved state |
| Re-queue for retry | Defers the problem | Increases complexity; still needs a fallback |

**Asymmetry**: New issue failures are less dangerous (the issue simply waits) than edit failures (the edit may have introduced malicious content). Hence the policies differ.

---

## 5. Approval Channel: Comment on Issue vs Separate Database

**Decision**: Hidden HTML comment on the issue itself.

| Option | Pros | Cons |
|---|---|---|
| **Issue comment (chosen)** | Self-contained; visible to any API consumer; no additional infrastructure; survives Entry Sentinel restarts | Comment can be deleted by actors with write access; requires signature verification to trust |
| Separate database | Strong access controls; cannot be tampered with | Requires additional infrastructure; downstream services must query Entry Sentinel or the database directly; breaks the decentralised trust model |
| GitHub commit status | Structured; GitHub-native | Does not apply to issues (only PRs and commits) |

**Why issue comment**: The decentralised trust model — where each downstream service verifies independently — requires the approval data to be co-located with the issue and accessible to any API consumer. A separate database would require a coordination endpoint, which Entry Sentinel's design explicitly avoids.

---

## 6. Detection Signatures: External Config vs Hardcoded vs Code-Generated

**Decision**: Versioned external configuration; loaded at startup; not compiled into the binary.

**ADR**: [ADR-0006](../adr/ADR-0006-versioned-external-detection-signatures.md)

| Option | Pros | Cons |
|---|---|---|
| **External versioned config (chosen)** | Signatures updated without code deployment; version recorded in audit log; human-reviewable; reloadable | Requires config distribution and versioning; adds a startup dependency |
| Hardcoded in source | Simple; always present; version-controlled with code | Forces redeployment for any signature update; slower response to emerging threats |
| Code-generated from external source | Best of both | High complexity; requires code generation pipeline |

---

## 7. AI Provider Integration: Inline vs Sidecar vs Off

**Decision**: Inline optional integration; disabled by default.

| Option | Pros | Cons |
|---|---|---|
| **Inline, opt-in (chosen)** | Keeps the service self-contained; opt-in means no risk when disabled | Extra dependency; adds latency on the clean path when enabled |
| Always-on | Consistent behaviour regardless of config | Adds latency to every clean issue; requires AI provider to be available always |
| Sidecar service | Separation of concerns | Additional deployment complexity; inter-service latency; another failure point |
| Off entirely | Simplest | Reduces detection coverage for novel techniques |

---

## 8. Quarantine Reversion: Revert Content vs Lock Without Revert

**Decision**: Revert title and body to approved content before quarantining.

| Option | Pros | Cons |
|---|---|---|
| **Revert then quarantine (chosen)** | Removes the malicious content from the issue; restores the safe state that downstream services were relying on | More complex; requires the approval comment to carry sufficient content for reversion |
| Lock without reverting | Simpler | The malicious edit remains visible in the issue; downstream services that hold a cached copy of the content without re-reading post-quarantine may still act on it |

**Why revert**: The approval comment already contains the hash and — implicitly via the signature — the content contract. To restore integrity, the content must match the approval. If the content is not reverted, the approval comment hash will not match the current content, but the malicious edit is still visible. Reverting makes the issue self-consistant in its safe state.

**Implication for the approval comment**: The approval comment does **not** store the full title and body text. Only the hash is stored. This means reversion requires Entry Sentinel to have a reliable source of the last approved content. This is either:

- The content of the issue at the time the edit event arrived (i.e., the content that was hashed and found to differ) — but that is the *current* (potentially malicious) content
- The content extracted from a previous state, not available in the approval comment

**Resolution**: The approved content must be retrievable for reversion. Options:

1. Store the full approved content in the approval comment (increases comment size but keeps it self-contained)
2. Store the approved content in Vault or a database (adds infrastructure)
3. Use GitHub's issue edit history API to retrieve the prior state before the malicious edit

The current preference is option 3 (use GitHub's edit history API to retrieve the pre-edit content for reversion), since the approval comment hash can be used to verify that the retrieved prior state is the correct approved version. This is flagged for the Interface Designer to confirm via GitHub API capability check.
