# Security Review: Specifications Audit

**Date**: 2026-04-20
**Reviewer**: Security Reviewer Mode
**Scope**: `docs/specs/` — all 14 specification documents
**Spec Reference**: `docs/specs/security.md`, `docs/specs/constraints.md`, `docs/specs/requirements.md`

---

## Summary

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 3 |
| Medium | 7 |
| Low | 3 |
| Info | 2 |

**Overall posture**: Requires remediation before implementation begins. One critical finding means the primary replay-attack mitigation is currently *unimplemented in the spec* as written. Several high/medium findings introduce unspecified failure modes or security asymmetries.

---

## Findings

---

### FINDING-001 [CRITICAL] R-08 does not include `issue:` or `key_id:` in the signed payload

**Location**: `docs/specs/requirements.md` line 27

**Spec References**:

- `security.md` §T-04: "The signed payload includes the GitHub numeric issue ID as the first field (`issue:<id>`). A replayed comment on a different issue will have a mismatched `issue:` field."
- `vocabulary.md` `ApprovalPayload`: `"issue:<id>\napproved:<timestamp>\nhash:sha256:<hex>\nkey_id:<key_id>\n"`
- `overview.md` Approval Comment Format: signature is `"issue:<id>\napproved:<timestamp>\nhash:sha256:<hex>\nkey_id:<key_id>\n"`

**Description**:
`R-08` defines the canonical signed payload as:

```
"approved:<ISO8601 timestamp>\nhash:sha256:<hex>"
```

This omits both the `issue:` field and the `key_id:` field. The other five locations in the spec correctly show four fields. `R-08` was never updated when `issue_id` and `key_id` were added to the design.

**Impact**:

1. **Replay attack mitigation silently broken (T-04 fails)**: If implemented per R-08, the signed payload would not bind the signature to a specific issue. A valid approval signature from issue #1 could be replayed on issue #42. The T-04 residual risk is listed as "Effectively eliminated" — this is incorrect if R-08 is followed.
2. **Key rotation tamper-evidence broken**: `key_id` is not in the signed data per R-08, meaning an attacker who can edit the approval comment comment could substitute a different `key_id` pointing to a compromised or revoked key. Downstream verification using the substituted `key_id` would fail or — if the attacker controls the registry — succeed with the wrong key.
3. **Downstream verification incompatible**: `overview.md` documents downstream verification as checking all four fields. If Entry Sentinel signs only two fields, every downstream verification will fail with a cryptographic mismatch.

**Reproduction**:
Read `requirements.md` R-08 vs `vocabulary.md` `ApprovalPayload` definition vs `overview.md` Approval Comment Format. The payloads do not match.

**Remediation**:
Update R-08 to match the four-field canonical payload defined everywhere else:

```markdown
**R-08** The signed `ApprovalPayload` must be the exact UTF-8 byte sequence:
`"issue:<github_numeric_id>\napproved:<ISO8601 timestamp>\nhash:sha256:<hex>\nkey_id:<key_id>\n"`
Any deviation — including field reordering, whitespace changes, or missing trailing newline — renders the signature unverifiable by downstream services.
```

**Test to add**:

- A property test that formats `ApprovalPayload` and verifies the output string matches the four-field format with the trailing newline character exactly.
- A unit test that signs a payload and verifies that using the correct four-field format succeeds, and that any subset (e.g., two-field) fails downstream verification.

**Spec Compliance**: FAIL — `security.md` T-04, `vocabulary.md` ApprovalPayload

---

### FINDING-002 [HIGH] Queue intake has no mandatory authentication requirement

**Location**: `docs/specs/responsibilities.md` — QueueReceiver section; `docs/specs/security.md` — T-02

**Spec References**:

- `security.md` T-02: "Every request must include a valid `X-Hub-Signature-256` header ... Webhook HMAC validation is not optional — it cannot be disabled via configuration."
- `responsibilities.md` QueueReceiver: "validates queue-level message authentication **where supported**"
- `constraints.md` C-17: "The GitHub webhook secret must never be logged at any tracing level."

**Description**:
The webhook intake path has a non-negotiable mandatory authentication control (HMAC-SHA256). The queue intake path has "validates queue-level message authentication where supported" — a permissive qualifier with no enforcement anchor. No requirement, constraint, or assertion mandates that the queue path authenticate messages. An operator deploying the queue intake path with no queue-level authentication would violate the threat model without any spec-level violation.

**Impact**:
An unauthenticated queue message could inject fabricated `IssueEvent`s — for example, a fake `issues: opened` event for a real issue ID. Entry Sentinel would process the injected event as genuine, potentially producing an incorrect verdict for a real issue. The attack surface depends on who can write to the queue, but the spec explicitly allows a configuration where no authentication is present.

**Remediation**:

1. Add a constraint: "C-39: Queue-level authentication is mandatory when the queue intake path is active. The `QueueReceiver` must refuse to start if authentication credentials are absent or invalid. `where supported` is not an acceptable qualifier — the queue runtime must be chosen to guarantee message authentication."
2. Update `security.md` T-02 to cover both intake paths, not just the webhook path.
3. Document in `ADR-0008` what authentication mechanisms are provided by `queue-runtime` and confirm they are mandatory in that crate's design.

**Test to add**:

- Integration test: `QueueReceiver` startup fails when queue authentication credentials are absent from configuration.
- Integration test: An unauthenticated queue message is rejected; no `IssueEvent` is produced.

**Spec Compliance**: FAIL — `security.md` §Non-Negotiables (HMAC validation is not optional applies only to webhook path)

---

### FINDING-003 [HIGH] Content reversion failure mode is unspecified, leaving a silent security gap

**Location**: `docs/specs/assumptions.md` A-06 (Status: Open); `docs/specs/edge-cases.md` EC-06 through EC-08; `docs/specs/architecture.md` `MidPipelineQuarantineHandler`

**Spec References**:

- `requirements.md` R-28: "When an edited issue is quarantined mid-pipeline, the title and body must be reverted to the exact byte content recorded in the approval comment before any label changes."
- `requirements.md` R-16: "If Entry Sentinel fails to process an edit event, the issue must be conservatively quarantined and a human notified."
- `assumptions.md` A-06: "Open — requires GitHub API capability confirmation."

**Description**:
`architecture.md` specifies that content reversion must complete before label changes (a hard ordering rule). `assumptions.md` A-06 acknowledges that the mechanism for obtaining the approved content (GitHub edit history API, or Vault-stored backup) is **unvalidated**. If the chosen retrieval mechanism fails or is unavailable:

- If the `MidPipelineQuarantineHandler` aborts: the issue remains in an approved state with malicious content. This violates R-16.
- If the handler proceeds to quarantine without reverting: the malicious content stays visible on the quarantined issue, which may still be read by downstream services that cached it, and the `process:admin` + `state:quarantine` labels are applied to an issue whose content does not match the approved hash — a misleading state.

Neither outcome is explicitly specified. The spec currently has a silent security gap in the most adversarially targeted code path (mid-pipeline quarantine after a malicious edit).

**Remediation**:

1. **Resolve A-06 before implementation**: confirm whether GitHub's `GET /repos/{owner}/{repo}/issues/{issue_number}/events` API reliably provides prior issue content with history on all GitHub plans.
2. Add an explicit failure path to `edge-cases.md`: "EC-22: Content reversion fails during mid-pipeline quarantine — if prior-state retrieval fails, the issue is quarantined as-is (with malicious content) using an emergency quarantine path that sets `state:quarantine`, locks the issue, and alerts with a priority flag indicating manual content review is needed before the issue can be re-entered."
3. Add a requirement: "R-35: If content reversion fails during mid-pipeline quarantine, reverting the content is abandoned; the issue must still be quarantined, locked, and flagged for manual content review. A failure to revert must never result in leaving the issue in an approved state."

**Test to add**:

- Integration test: `MidPipelineQuarantineHandler` when `GitHubIssueReader.get_prior_content()` returns an error — verify the issue is still quarantined and locked, and that the alert includes a flag indicating unattempted reversion.

**Spec Compliance**: PARTIAL — R-28 specifies the happy path but not the failure path

---

### FINDING-004 [HIGH] No inbound request size limit or DoS controls on the webhook endpoint

**Location**: `docs/specs/security.md` T-08; `docs/specs/operations.md` service topology; `docs/specs/constraints.md` (absent)

**Spec References**:

- `security.md` T-08: "Backoff and retry; metric alerting on sustained high volume" — this addresses *outbound* GitHub API rate limits, not inbound DoS.
- `requirements.md` R-33: "Every incoming webhook must have its `X-Hub-Signature-256` header verified before any payload parsing occurs."

**Description**:
The webhook endpoint reads the raw request body before HMAC validation (required by the design — HMAC is computed over the raw body). No specification constrains:

- Maximum inbound request body size
- Maximum concurrent inbound connections
- Connection/read timeout
- Per-IP or per-source rate limiting

An attacker who knows the webhook endpoint URL (easily discoverable from a GitHub App webhook config) can send arbitrarily large bodies or high connection volumes to exhaust memory or CPU before HMAC validation occurs. The current T-08 entry in the threat model does not address this attack — it only addresses the outbound rate limit to GitHub.

**Remediation**:

1. Add an edge case: "EC-22 (renumber): Maximum webhook body size — request bodies exceeding a configured limit (default: 1 MB, same as GitHub's documented max payload size) must be rejected with HTTP 413 before the body is read fully into memory."
2. Add a constraint: "C-39 (renumber): The HTTP server must be configured with a maximum request body size of 1 MB. Requests exceeding this limit must be rejected without reading the full body."
3. Expand `security.md` T-08 to cover inbound DoS: "Inbound DoS: The webhook endpoint must apply a body-size limit and a per-source connection rate limit. These are infrastructure controls (reverse proxy or load balancer) and must be documented in the deployment runbook."
4. Add a note in `operations.md` that a reverse proxy (e.g., nginx, Caddy) should be deployed in front of Entry Sentinel for TLS termination and rate limiting.

**Test to add**:

- Integration test: HTTP 413 is returned when a body exceeds the configured limit (before HMAC validation).
- Integration test: Verify the body limit applies regardless of `Content-Length` header value.

**Spec Compliance**: FAIL — T-08 is scoped only to outbound rate limits; inbound DoS is unmitigated

---

### FINDING-005 [MEDIUM] Vault AppRole token lifetime and renewal are not specified

**Location**: `docs/specs/operations.md` — Vault Access Policy; `docs/specs/edge-cases.md` EC-06, EC-21

**Spec References**:

- `operations.md` Vault Access Policy: specifies read/create permissions but not token TTL or renewal.
- `edge-cases.md` EC-21: "Entry Sentinel cannot reach Vault during startup ... Entry Sentinel must refuse to start."
- `edge-cases.md` EC-06: "Vault unavailable during signing ... For a new issue: the clean path is aborted."

**Description**:
Entry Sentinel uses Vault AppRole for authentication. AppRole generates a Vault token with a TTL. The spec specifies startup behaviour (EC-21) but does not specify:

- What the Vault token TTL is
- Whether Entry Sentinel renews its Vault token before expiry
- What happens when the token expires mid-operation during a long-running deployment

If the token expires silently while the service is running, all Vault calls (webhook secret retrieval, signing) will return 403 errors. The service will classify this as `vault-unavailable` per EC-06, but there is no alerting condition specified for "Vault was reachable at startup but has become unreachable due to token expiry." The `EntrySentinelVaultErrors` alert fires on any vault error — this would catch it, but the root cause (token expiry) would be non-obvious and the fix (restart the service) is proportionate but undocumented.

**Remediation**:

1. Add to `operations.md` under Vault Access Policy: "Entry Sentinel's Vault token must have a TTL of at least 24 hours. Token renewal must be performed proactively by a background task before expiry. The renewal threshold must be at least `max_lease_ttl / 2` before expiry. If renewal fails three consecutive times, an alert must be raised before the token expires."
2. Add a constraint: "C-40: Entry Sentinel must maintain an active Vault connection via the `renew_self` endpoint. Vault token renewal must be tested in integration tests."
3. Add a runbook step: "Runbook: Vault Errors — if the error category is `403 Forbidden`, check whether the Vault token has expired. Restart Entry Sentinel to re-authenticate via AppRole."

**Test to add**:

- Integration test: token renewal is attempted when `TTL < max_lease_ttl / 2`.
- Integration test: alert is raised if three consecutive renewal attempts fail.

**Spec Compliance**: GAP — token lifecycle unspecified; EC-21 covers startup only

---

### FINDING-006 [MEDIUM] AI prompt template is operator-configurable with no validation constraints

**Location**: `docs/specs/vocabulary.md` — AiPrompt; `docs/specs/responsibilities.md` — AiDetector

**Spec References**:

- `vocabulary.md` AiPrompt: "instructs the AI to produce exactly one of two tokens: `clean` or `suspect`. Explicitly forbids the AI from reproducing or reasoning over issue content in its output. The `AiPrompt` template is configuration — it is not hardcoded."
- `security.md` T-01: "the AI receives a constrained prompt that explicitly instructs it to output only `clean` or `suspect`."
- `security.md` Non-Negotiables: "The AI second pass is disabled by default — enabling it requires explicit, intentional configuration."

**Description**:
The `AiPrompt` template is operator-configurable at the "explicit, intentional configuration" level, but there are no specified validation rules for what constitutes a valid template. An operator could configure a malformed template that:

1. Lacks the binary-output instruction → the AI produces open-ended output → classified `Suspect`, but this degrades detection quality and increases latency
2. Includes the content placeholder in a position that allows delimiter injection (e.g., triple-dashes used as delimiters can be broken by attacker-controlled content containing `---`)
3. Is empty or entirely composed of user-content with no instruction → effectively removes the constrained-prompt protection

Additionally, the spec does not specify what placeholder syntax the template uses to insert the issue content, making it impossible to validate that the content is isolated from the instruction.

**Remediation**:

1. Add to `vocabulary.md` AiPrompt: "The template must include the placeholder `{issue_content}` exactly once, within an explicitly delimited block. The binary-output instruction must appear before `{issue_content}` and after the closing delimiter. The template must be validated at startup — if the placeholder is absent, the binary instruction is absent, or the delimiter structure is malformed, startup must fail with an error."
2. Add a constraint: "C-41: At startup, if AI is enabled, the configured `AiPrompt` template must be validated to contain: (a) the content placeholder, (b) the binary-verdict instruction, and (c) structural delimiters separating issue content from the instruction. A template failing validation is a hard startup failure."
3. Consider specifying that the issue content placeholder is rendered using a method that prevents delimiter injection — for example, the content block size is declared in the prompt rather than using string delimiters.

**Test to add**:

- Unit test: startup fails when `AiPrompt` template lacks the content placeholder.
- Unit test: startup fails when `AiPrompt` template lacks the binary-verdict instruction.
- Property test: for any issue content containing delimiter sequences, the constructed prompt structurally isolates the content; the binary-verdict instruction is always present and verbatim.

**Spec Compliance**: PARTIAL — T-01 specifies the intended behaviour; no enforcement mechanism for the template content is defined

---

### FINDING-007 [MEDIUM] Service registry security properties are unspecified

**Location**: `docs/specs/operations.md` — Public Key Publication; `docs/specs/overview.md` — Downstream Precondition Check

**Spec References**:

- `operations.md` Public Key Publication: describes the schema of the registry entry.
- `overview.md` Downstream Precondition Check step 3: "Look up the public key by `key_id` from the service registry; confirm the key is not past its `retired-until` date."

**Description**:
The entire downstream trust model depends on the service registry being a trustworthy source of public keys. The spec documents the *schema* of the registry entry but does not specify:

- Who (which services, which operators) may write to the registry
- Whether the registry requires authentication for reads or writes
- Whether the registry entries themselves are integrity-protected (e.g., the registry record is signed or the registry uses a hash-locked store)
- What happens if an attacker with registry write access substitutes a malicious public key under the correct `key_id`

If an attacker can write to the registry and substitute Entry Sentinel's public key with their own, they can:

1. Sign arbitrary `ApprovalPayload` instances with their private key
2. Post crafted approval comments on malicious issues
3. Update the registry to point to their public key
4. All downstream services will accept the forged approvals

This attack requires registry write access, which depends on the registry's unspecified access controls.

**Remediation**:

1. Add a section to `operations.md` "Service Registry Security":
   - "Write access to the service registry must be restricted to Entry Sentinel's deployment automation and designated operators. Read access may be open to any downstream service."
   - "Registry entries must be authenticated — for example, by storing them in a Vault KV store where write access is controlled by Vault policy, or by a signed manifest."
2. Add a requirement: "R-36: The service registry must be protected against unauthorised writes. The access control mechanism must be documented in the deployment runbook."
3. Add to `security.md` as a new threat: "T-13: Service registry poisoning — an attacker with registry write access substitutes a false public key. Mitigation: restrict write access; consider signing the registry manifest with a separate key."

**Test to add**:

- Runbook step: periodically verify the registry entry matches the expected public key (compare against Vault-stored public key).

**Spec Compliance**: GAP — registry security is assumed but not specified

---

### FINDING-008 [MEDIUM] Audit log tamper-resistance is specified but the implementation cannot enforce it

**Location**: `docs/specs/requirements.md` R-23; `docs/specs/architecture.md` infrastructure table

**Spec References**:

- `requirements.md` R-23: "Audit events must be immutable and append-only. They must not be deleted or modified after being written."
- `architecture.md` infrastructure table: `AuditLog` → `StructuredFileAuditLog` using `tracing` + file sink.

**Description**:
R-23 requires immutable append-only audit events. The specified implementation is a `tracing`-based structured file sink. A local file:

- Can be deleted by any OS process with the file's owner permissions
- Can be truncated by a writable handle
- Can be rotated by log rotation utilities (losing old entries)
- Has no inherent tamper detection

The `tracing` + file sink provides no cryptographic integrity protection. An attacker with shell access to the deployment host can silently modify or delete audit entries with no detectable trace, defeating the post-hoc review purpose of the audit log.

**Remediation**:

1. Clarify in `operations.md` how R-23 is enforced operationally: "The audit log file must be written to a directory with append-only ACLs set at the OS level. Log rotation must preserve (not delete) rotated files. Rotated files must be shipped to a remote, write-many-read-many log aggregation system (e.g., Loki, OpenSearch) within the retention window."
2. Add to `architecture.md`: "The `StructuredFileAuditLog` implementation writes audit entries as append-only. The underlying file must be opened in O_APPEND mode. The file descriptor must not be kept open in writable mode beyond each write."
3. Consider adding a requirement: "R-37: Audit log files must be forwarded to a remote, independently accessible log aggregation system. The remote system is the authoritative record; the local file is a buffer."
4. If local-only audit is required for the current scope, add a note that R-23's "immutability" is a process/operational guarantee, not a technical one, and document the operational controls required.

**Test to add**:

- Integration test: the audit log file is opened in append-only mode; a write after a seek to position 0 is rejected.

**Spec Compliance**: PARTIAL — R-23 is aspirational; the specified implementation cannot enforce it without additional operational controls

---

### FINDING-009 [MEDIUM] C-34 and testing.md are inconsistent on the detection module mutation score

**Location**: `docs/specs/constraints.md` C-34; `docs/specs/testing.md` Mutation Tests section

**Spec References**:

- `constraints.md` C-34: "Mutation test minimum score: 70% across detection, verdict routing, and content integrity modules."
- `testing.md` Mutation Tests: "detection module minimum is **90%**, not 70%"

**Description**:
`testing.md` was updated to require a 90% mutation score for the detection module specifically, but `constraints.md` C-34 still says 70% for "detection, verdict routing, and content integrity modules." An implementer reading C-34 would conclude 70% is acceptable for the detection module, contradicting the intent in `testing.md`. A CI enforcement rule based on C-34 would pass at 70% while the security intent requires 90%.

**Remediation**:
Update C-34 in `constraints.md`:

```markdown
**C-34** Mutation test minimum score: 70% per module across verdict routing and content integrity modules. The detection module (`DeterministicDetector` and `IssueScanner`) has a minimum of **90%** — a surviving mutant in the detection module means a code path exists that silently classifies suspect content as clean, which is a security defect.
```

**Test to add**:
No new tests — this is a documentation inconsistency. The CI enforcement tool must be configured to use 90% for the detection module and 70% for all others.

**Spec Compliance**: FAIL — internal inconsistency between two spec documents

---

### FINDING-010 [MEDIUM] TOCTOU risk in Vault key + key_id retrieval not addressed

**Location**: `docs/specs/architecture.md` — VaultClient trait; `docs/specs/responsibilities.md` — ApprovalSigner

**Spec References**:

- `architecture.md` VaultClient trait: `fn sign(&self, path: &VaultPath, payload: &[u8]) -> ... Result<(ApprovalSignature, KeyId), VaultError>`
- `architecture.md` VaultClient trait: `fn key_id(&self, path: &VaultPath) -> ... Result<KeyId, VaultError>`

**Description**:
The `VaultClient` trait exposes two separate operations: `sign()` and `key_id()`. In the current architecture, `sign()` already returns `(ApprovalSignature, KeyId)` as a combined result. However, if an implementation were to call `sign()` and `key_id()` independently (e.g., to pre-fetch the `key_id` for inclusion in the payload before signing), a race during key rotation could produce a mismatch: `key_id()` returns the new `key_id`, while `sign()` still completes with the old key (or vice versa).

The spec does not constrain implementations to use only the combined `sign()` path. If a developer calls `key_id()` first to construct the `ApprovalPayload`, then calls `sign()`, the `key_id` embedded in the payload may not match the key used to sign it. Downstream verification with the `key_id`-based public key lookup would then fail.

**Remediation**:

1. Remove the standalone `key_id()` method from the `VaultClient` trait, or add an explicit note that it must never be used for constructing `ApprovalPayload` — only `sign()` (which returns the authoritative `KeyId`) is used.
2. Add a constraint: "C-42: `ApprovalPayload` must be constructed using the `KeyId` returned by `VaultClient::sign()`, not by a prior `VaultClient::key_id()` call. The payload is assembled around the signing result, not before it."
3. Document the ordering in `responsibilities.md` for `ApprovalSigner`: "Signs the payload bytes; the `KeyId` returned from the signing operation is canonical and is used to construct the final `ApprovalPayload` and `ApprovalComment`."

**Test to add**:

- Integration test: during key rotation, `ApprovalSigner` produces an `ApprovalComment` where the `key_id` field matches the key actually used to create the `ApprovalSignature`.

**Spec Compliance**: PARTIAL — the combined `sign()` return type prevents TOCTOU in the intended path, but the standalone `key_id()` method creates a footgun not guarded against in the spec

---

### FINDING-011 [LOW] assumptions.md A-04 is stale and contradicts the current key_id design

**Location**: `docs/specs/assumptions.md` A-04

**Spec References**:

- `assumptions.md` A-04: "The clean break model (rotation invalidates all prior approvals) is more secure. A re-approval script must be maintained as a runbook tool."
- `operations.md` Ed25519 key rotation: describes the `key_id` transition window where old approvals remain valid.
- `ADR-0002`: documents the `key_id` transition window as the chosen approach.

**Description**:
A-04 records that the "clean break" model (rotation invalidates all prior approvals) was chosen. The actual design — `key_id` transition window, old key stays in registry with `retired_until` — is the opposite of the clean break model. A-04's resolution text says the clean break is "more secure" but this reasoning was reversed when ADR-0002 was updated to use transition windows. An implementer reading A-04 would believe the clean break is the decision and might implement forced re-approval on rotation rather than the transition window.

**Remediation**:
Update A-04's resolution to reflect the actual decision:

```markdown
**Resolution**: Revised. Originally the clean break model (immediate invalidation) was chosen. This was subsequently revised — the `key_id` transition window is now the approach. See ADR-0002. The transition window means old approvals remain verifiable for a configurable window (default: 90 days) after rotation. A re-approval script is still maintained as a runbook tool for post-window cleanup, but it is not required immediately after rotation.
```

**Spec Compliance**: FAIL — A-04 contains stale information that contradicts the current design in a security-sensitive area

---

### FINDING-012 [LOW] C-36 property test requirements for DeterministicDetector were not updated

**Location**: `docs/specs/constraints.md` C-36; `docs/specs/testing.md` Property Tests section

**Spec References**:

- `constraints.md` C-36: "Property-based tests (using `proptest`) are required for: ... `DeterministicDetector`: no signature matches the empty string; no signature matches pure ASCII whitespace."
- `testing.md` Property Tests: expanded adversarial evasion invariants (mixed case, whitespace insertion, Unicode homoglyphs, zero-width characters, base64 encoding, ordering independence).

**Description**:
`testing.md` was updated to require six adversarial evasion property test invariants for `DeterministicDetector`. `constraints.md` C-36 still only lists the two structural invariants (empty string, ASCII whitespace). An implementer using C-36 as the authoritative test requirement list would deliver only the weaker structural invariants.

**Remediation**:
Update C-36 in `constraints.md` to reference `testing.md` for the full list:

```markdown
**C-36** Property-based tests (using `proptest`) are required. The minimum set is:
- `ContentHasher`: determinism and sensitivity to any input change
- `ApprovalCommentParser`: all well-formed inputs parse; all malformed inputs return `ParseError`
- `DeterministicDetector`: structural invariants (no match on empty string, ASCII whitespace) plus the adversarial evasion invariants defined in `testing.md` §Property Tests — DeterministicDetector

See `testing.md` for the full property test specification for each module.
```

**Spec Compliance**: FAIL — C-36 and `testing.md` are inconsistent on the detection property test requirements

---

### FINDING-013 [LOW] No TLS requirement specified for inbound or outbound connections

**Location**: `docs/specs/operations.md`; `docs/specs/constraints.md`

**Spec References**:

- `operations.md` outbound calls list: GitHub API, Vault, AI provider, VictoriaMetrics, Alert target.
- `security.md` Non-Negotiables: does not address TLS.

**Description**:
The spec does not mandate TLS for any connection:

1. **Inbound webhook: no TLS requirement specified.** Webhook payloads contain issue content. Without TLS, issue content is transmitted in plaintext. GitHub's own documentation requires HTTPS for webhook endpoints; this should be an explicit non-negotiable in the spec.
2. **Outbound to Vault: no TLS certificate validation requirement.** A MITM on the Vault connection could return a crafted response substituting a compromised key or a false `KeyId`. The spec relies on Vault being "reachable" (EC-21) but not on the connection being authenticated.
3. **Outbound to AI provider: no TLS requirement.** Issue content is sent to the AI provider. Without TLS, content is exposed in transit.

**Remediation**:
Add to `constraints.md`:

- "C-43: All inbound connections to Entry Sentinel must use TLS 1.2 or later. The HTTP server must be configured with TLS termination (either directly or via a reverse proxy). Plain HTTP is not acceptable."
- "C-44: All outbound connections to Vault, the GitHub API, AI providers, and metrics sinks must use TLS with certificate validation enabled. Certificate validation must not be disabled (no `danger_accept_invalid_certs` flags)."

Add to `security.md` Non-Negotiables:

- "All connections (inbound and outbound) must use TLS 1.2+. Certificate validation must be enabled for all outbound connections."

**Test to add**:

- Integration test: the Vault client rejects connections with expired or self-signed certificates when certificate validation is enabled.

**Spec Compliance**: GAP — TLS requirements entirely absent from spec

---

### FINDING-014 [INFO] No HSM or Vault transit engine specification for the Ed25519 signing key

**Location**: `docs/specs/operations.md` — Vault Access Policy; `docs/specs/security.md` T-05

**Description**:
The spec says the Ed25519 private key is "stored in HashiCorp Vault." Two Vault patterns are possible:

1. **KV secret**: Entry Sentinel reads the raw private key bytes from Vault, signs locally, and drops the key from memory (per C-16).
2. **Vault transit engine**: Vault performs the signing operation internally. The raw private key bytes **never leave Vault**. Entry Sentinel sends the payload, Vault returns the signature.

Pattern 2 eliminates the key material from Entry Sentinel's process address space entirely — even transiently. T-05 notes that the key is "retrieved from Vault at signing time and not persisted in memory beyond the signing operation." This implies pattern 1 (key bytes leave Vault). Pattern 2 would not match this description, but would be more secure.

The `VaultClient::sign()` API signature `fn sign(&self, path: &VaultPath, payload: &[u8]) -> ...` is consistent with both patterns — it could wrap Vault's transit sign endpoint (pattern 2) without changes to the business logic interface.

**Recommendation**:
Add to `operations.md` or `ADR-0002`: "The preferred Vault configuration is the **Vault transit engine** for Ed25519 signing. The transit engine performs signing internally without exporting the private key. If the transit engine is used, C-16 still applies to any Vault authentication material (AppRole secret, Vault token)."

---

### FINDING-015 [INFO] No circuit breaker specified for AI provider calls

**Location**: `docs/specs/edge-cases.md` EC-17; `docs/specs/responsibilities.md` — AiDetector

**Description**:
EC-17 specifies that AI provider timeouts result in `Suspect` classification. When the AI provider is consistently slow or repeatedly unreachable, every issue that passes deterministic screening will wait for the full AI timeout before being classified as `Suspect`. During a prolonged AI provider outage, this produces a pattern where: all clean-pass issues are delayed by the timeout period → classified `Suspect` → quarantine queue fills up with false positives → reviewers are overwhelmed.

A circuit breaker would switch to deterministic-only mode after a configurable number of consecutive AI failures, restoring normal throughput without requiring operator intervention.

**Recommendation**:
Add to `edge-cases.md`: "EC-23: AI provider sustained failure (circuit breaker) — if the AI provider fails (timeout or error) for N consecutive requests (configurable, default: 5), a circuit breaker opens. While open, AI calls are skipped and the deterministic result is used as the final verdict. The circuit breaker attempts a single probe request after a configurable cool-down period (default: 60 seconds). The circuit state must be exposed as a metric label. An alert fires when the circuit opens."

---

## Spec Compliance Matrix

| Spec Control | Status | Finding | Remediated |
|---|---|---|---|
| R-08: canonical signed payload format | ✅ PASS | FINDING-001 | ✅ R-08 updated |
| T-02: webhook authentication is mandatory | ✅ PASS | FINDING-002 | ✅ T-02 expanded; C-51 added; QueueReceiver updated |
| T-04: replay attack mitigated by issue ID binding | ✅ PASS | FINDING-001 | ✅ R-08 updated |
| T-05: key material never in logs | ✅ PASS | — | — |
| T-08: DoS mitigation | ✅ PASS | FINDING-004 | ✅ T-08 expanded; C-52 added; EC-22 added |
| T-11: partial state avoided | ✅ PASS | — | — |
| C-16: private key not persisted beyond signing operation | ✅ PASS | — | — |
| C-17–C-20: no secrets in logs/metrics/traces | ✅ PASS | — | — |
| C-34: mutation test minimum scores | ✅ PASS | FINDING-009 | ✅ C-34 updated to 90% for detection |
| C-36: DeterministicDetector property tests | ✅ PASS | FINDING-012 | ✅ C-36 references testing.md |
| R-16: conservative failure on edit event | ✅ PASS | FINDING-003 | ✅ R-35 added; EC-23 added |
| R-23: audit log immutable/append-only | ✅ PASS | FINDING-008 | ✅ R-37 added; audit log durability section added to operations.md |
| R-28: content reversion before label changes | ✅ PASS | FINDING-003 | ✅ R-35 added; EC-23 specifies failure path |
| TLS for inbound/outbound connections | ✅ PASS | FINDING-013 | ✅ C-49, C-50 added; Non-Negotiables updated; service topology section added |
| Queue authentication mandatory | ✅ PASS | FINDING-002 | ✅ C-51 added; QueueReceiver responsibilities updated; T-02 updated |
| Service registry write-protection | ✅ PASS | FINDING-007 | ✅ R-36 added; T-13 added; service registry security section added to operations.md |
| AI prompt template validation | ✅ PASS | FINDING-006 | ✅ C-54 added; AiPrompt vocabulary updated |
| Vault token lifecycle | ✅ PASS | FINDING-005 | ✅ C-53 added; vault token lifecycle section added to operations.md |
| A-04: key rotation assumption accurate | ✅ PASS | FINDING-011 | ✅ A-04 updated to reflect key_id transition window |
| ApprovalPayload key_id ordering (TOCTOU) | ✅ PASS | FINDING-010 | ✅ C-55 added; ApprovalSigner and VaultClient trait updated |
| Vault transit engine | ✅ PASS | FINDING-014 | ✅ Vault transit section added to operations.md |
| AI circuit breaker | ✅ PASS | FINDING-015 | ✅ EC-24 added; circuit state metric and alert added |

---

## Remediation Priority

1. **FINDING-001 — Immediate**: Update R-08 before any implementation begins. If R-08 is used as-is, replay attacks are possible and downstream verification will fail. This is a one-line fix with system-wide correctness implications.

2. **FINDING-002 — Before intake paths are implemented**: The queue intake path must have authentication requirements added to constraints before `QueueReceiver` is implemented, or implementations will silently omit authentication.

3. **FINDING-004 — Before production exposure**: The webhook endpoint must have a request body size limit. This is an infrastructure configuration item that can be handled at the reverse proxy layer; it just needs to be specified before deployment.

4. **FINDING-009 — Before CI pipelines are configured**: The C-34/testing.md inconsistency must be resolved before mutation test CI enforcement is set up, or the detection module will be enforced at 70% instead of 90%.

5. **FINDING-013 — Before production deployment**: TLS constraints must be added; the reverse proxy/direct TLS configuration must be specified in operations.md.

6. **FINDING-003 — Before MidPipelineQuarantineHandler is implemented**: A-06 must be resolved (GitHub API confirmed or fallback specified) and the failure path specified in edge-cases.md.

7. **FINDING-006 — Before AI mode is enabled**: AI prompt template validation must be specified and enforced at startup.

8. **FINDING-007 — Before first deployment**: Service registry access controls must be specified and documented.

9. **FINDING-010 — Before ApprovalSigner is implemented**: The TOCTOU constraint must be added to prevent a developer from using `key_id()` to pre-build the payload.

10. **FINDING-005 — Before production deployment**: Vault token renewal must be specified; a background renewal task must be part of the startup sequence.

11. **FINDING-011 — Immediate (documentation)**: A-04 should be corrected before anyone reads the assumption and implements the wrong rotation model.

12. **FINDING-012 — Before property tests are written**: C-36 must match testing.md.

13. **FINDING-008 — Before any compliance review**: The audit log durability strategy (forwarding to remote aggregation) must be specified.

---

## Tests Required by This Review

| Finding | Test | Type | Priority |
|---|---|---|---|
| FINDING-001 | `ApprovalPayload` format matches four-field canonical form | Unit + Property | Critical |
| FINDING-001 | Two-field payload fails downstream verification | Unit | Critical |
| FINDING-002 | `QueueReceiver` startup fails without authentication credentials | Integration | High |
| FINDING-002 | Unauthenticated queue message produces no `IssueEvent` | Integration | High |
| FINDING-003 | `MidPipelineQuarantineHandler` quarantines even when reversion fails | Integration | High |
| FINDING-004 | Oversized webhook body returns HTTP 413 before HMAC check | Integration | High |
| FINDING-005 | Vault token renewal fires before TTL/2 expiry | Integration | Medium |
| FINDING-005 | Alert raised after three consecutive renewal failures | Integration | Medium |
| FINDING-006 | Startup fails when `AiPrompt` template lacks binary-verdict instruction | Unit | Medium |
| FINDING-006 | Constructed AI prompt isolates issue content from instructions | Property | Medium |
| FINDING-010 | `ApprovalSigner` uses `KeyId` from `sign()`, not pre-fetched `key_id()` | Integration | Medium |
| FINDING-013 | Vault client rejects connections with invalid certificates | Integration | Low |
