# Assumptions — Entry Sentinel

This document records the assumptions made during architecture, which assumptions were challenged, how they were resolved, and what their impact on the design is. Assumptions that are later found to be incorrect must be updated here and the affected spec files revised.

---

## Challenged Assumptions

### A-01: Detection signatures can be updated without code redeployment

**Assumption**: Detection patterns will need to update frequently as prompt injection techniques evolve. The latency between identifying a new technique and deploying a mitigation must be short.

**Challenged because**: Maintaining an external signature config pipeline has non-trivial operational overhead. It would be simpler to hardcode signatures and redeploy.

**Resolution**: Accepted as correct. Prompt injection techniques evolve fast enough that a 5–15 minute signature update cycle (config reload) is materially better than a 30–60 minute code deployment + review cycle. The operational overhead of the config pipeline is justified. See [ADR-0006](../adr/ADR-0006-versioned-external-detection-signatures.md).

**Impact**: The detection signature library must have a defined schema, validation, versioning, and distribution mechanism. This is tracked as a separate design concern outside the Entry Sentinel binary.

---

### A-02: Unlabelled issues are safe to leave pending

**Assumption**: When Entry Sentinel fails to process a new issue, leaving it unlabelled is an acceptable failure mode.

**Challenged because**: An unlabelled issue that sits in the repository for an extended period may create confusion or cause downstream systems to act on it if their precondition checks are not strict.

**Resolution**: Confirmed. Downstream services are designed to require the explicit approval label — they do not process unlabelled issues. The watchdog provides the detection mechanism. Unlabelled is the safest possible failure mode for a new issue because it is visible, auditable, and recoverable without any risk of approving unscanned content. See [ADR-0004](../adr/ADR-0004-conservative-failure-handling.md).

**Impact**: The watchdog is a required operational component, not optional. Its threshold must be configured and its alerting must be monitored.

---

### A-03: The AI second pass adds meaningful detection value

**Assumption**: An LLM-based second pass improves detection coverage for prompt injection techniques that evade deterministic patterns.

**Challenged because**: An LLM is itself a target for prompt injection. Adding an LLM to the detection path increases complexity and attack surface. The deterministic pass alone may be sufficient.

**Resolution**: Accepted with constraints. The AI second pass is opt-in and disabled by default. When enabled, it must operate on content that has already passed deterministic screening (i.e., it only sees content that is not a known-bad pattern). The constrained prompt limits the AI's output to a binary token and prevents reasoning over content. The risk-benefit is acceptable as an optional capability. See [ADR-0005](../adr/ADR-0005-ai-second-pass-opt-in.md).

**Impact**: The AI second pass is an optional feature. All tests must pass with it disabled. The `AiProvider` abstraction must be mockable for testing without a real AI provider.

---

### A-04: Ed25519 key rotation invalidates all prior approvals

**Assumption**: Rotating the Ed25519 key is a low-friction operational procedure.

**Challenged because**: After rotation, all previously issued approval comments are signed with the old key. Downstream services that have removed the old public key from their trust store will reject all prior approvals. This means every approved issue needs to be re-approved — a potentially large operation.

**Resolution**: Revised. This assumption was originally accepted as a known trade-off favouring the clean break model (rotation immediately invalidates all prior approvals). This decision was subsequently revised. The current design uses a `key_id` transition window: after key rotation, the old key remains in the service registry with a `retired_until` date (default: 90 days). All approvals issued with the old `key_id` remain verifiable throughout the window. No immediate re-approval is required. See [ADR-0002](../adr/ADR-0002-ed25519-approval-signing.md) and [operations.md](operations.md).

**Impact**: A re-approval script is still maintained as a runbook tool, but it is only required when the transition window lapses — not immediately after rotation. The transition window makes rotation low-friction while preserving backward compatibility for downstream services.

---

### A-05: GitHub's hidden HTML comment is the correct approval channel

**Assumption**: Posting the approval data as a hidden HTML comment on the issue is a reliable and sufficient channel for downstream services.

**Challenged because**: HTML comments on GitHub issues can be deleted by anyone with write access to the issue. A human or bot with write access could remove the approval comment, causing downstream services to abort unnecessarily. Additionally, the comment is not formally structured — it is freeform text within an HTML comment.

**Resolution**: Accepted. The approval comment is cryptographically signed, so it cannot be forged. Its absence is treated as a missing approval, causing downstream services to abort and alert — which is the safe outcome. The comment format is strict and machine-parseable. This is a deliberate design choice that maximises decentralisation: no external store is needed. See [tradeoffs.md](tradeoffs.md#5-approval-channel-comment-on-issue-vs-separate-database).

**Impact**: The parse-on-absence behaviour must be explicitly tested. The `ApprovalCommentLocator` must distinguish between "no comment" and "malformed comment" and handle both safely.

---

### A-06: Content stored in approval comment is sufficient for edit reversion

**Assumption**: The approval comment stores enough information to revert an issue's title and body to the approved state.

**Challenged because**: The approval comment stores only the `ContentHash` (a SHA-256 digest), the timestamp, and the signature. It does **not** store the full title and body text. Reverting content requires access to the actual text, not just its hash.

**Resolution**: The approved title and body must be recoverable from a source other than the approval comment hash alone. The preferred approach is to use GitHub's issue edit history API to retrieve the version of the issue content immediately prior to the suspect edit. The approval comment hash is then used to verify that the retrieved prior content matches the approved state. If the GitHub edit history is insufficient or unavailable, a fallback option is to store the approved content (encrypted) in Vault alongside the private key.

**Impact**: The `MidPipelineQuarantineHandler` has a dependency on the GitHub edit history API (or the Vault-stored content backup). The Interface Designer must research the availability and reliability of `GET /repos/{owner}/{repo}/issues/{issue_number}/events` and related APIs for retrieving prior issue content. This must be validated before implementation of the reversion feature.

**Status**: Open — requires GitHub API capability confirmation.

---

### A-07: A 24-hour delivery ID window is sufficient for idempotency

**Assumption**: Storing processed webhook delivery IDs in a bounded in-memory window of 24 hours is sufficient to prevent duplicate processing.

**Challenged because**: GitHub may retry webhook delivery up to 72 hours after the original attempt. If Entry Sentinel restarts within that window (losing its in-memory cache), duplicate deliveries could slip through.

**Resolution**: Accepted for the current version. The consequence of a duplicate delivery is a redundant write (e.g., a label applied twice, or an audit event duplicated). These are not catastrophic consequences. If stricter idempotency is required, a persistent store (e.g., a Redis cache or a simple SQLite database) could be added. For now, the in-memory window is sufficient and keeps the operational footprint minimal.

**Impact**: The `DeliveryIdGuard` implementation note: the in-memory window must be bounded (e.g., by time and by count) to prevent unbounded memory growth. A restart clears it — this is a documented and accepted limitation.

---

## Unresolved Assumptions

| ID | Assumption | Status |
|---|---|---|
| A-06 | GitHub edit history API is sufficient for content reversion | Open — needs API capability validation |

Open assumptions must be resolved before the corresponding feature is implemented. If an assumption cannot be confirmed, the design must be updated to reflect the correct approach before the Interface Designer phase begins.
