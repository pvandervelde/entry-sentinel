# Requirements — Entry Sentinel

Non-negotiable properties of the system. Every item here must be true at all times. Use this list to confirm scope before adding code and to verify implementation correctness.

---

## Pipeline Integrity

**R-01** Every issue processed by Entry Sentinel receives exactly one of: a clean verdict (with an approval comment) or a suspect verdict (with quarantine). There is no third state.

**R-02** No issue may carry the `process:development` label without a currently-valid approval comment signed by Entry Sentinel's active key.

**R-03** No issue may enter the pipeline in an unlabelled state. Unlabelled means unprocessed, not safe.

**R-04** The approval comment is the single source of truth for approval status. Any service may verify it independently without contacting Entry Sentinel.

**R-05** The Ed25519 public key must be published in the service registry before Entry Sentinel begins processing any issues in a deployment.

---

## Cryptographic Integrity

**R-06** Every approval comment must contain a timestamp, a `ContentHash`, and an `ApprovalSignature`. A comment missing any of these fields is invalid and must be treated as absent.

**R-07** The `ContentHash` must be computed as SHA-256 over `UTF-8(title) + b"\n" + UTF-8(body)` with no whitespace normalisation. This canonical form must never change without a corresponding key rotation and re-approval of all existing approved issues.

**R-08** The signed `ApprovalPayload` must be the exact UTF-8 byte sequence:
`"issue:<github_numeric_id>\napproved:<ISO8601 timestamp>\nhash:sha256:<hex>\nkey_id:<key_id>\n"`
Field order is fixed. A trailing newline after `key_id:` is required. Any deviation — including field reordering, missing fields, whitespace changes, or a missing trailing newline — renders the signature unverifiable by downstream services. This format binds the signature to a specific issue ID (preventing replay across issues) and to a specific key (enabling key rotation verification).

**R-09** The Ed25519 private key must never be logged, written to disk, included in error messages, or placed in any metric label or trace attribute.

---

## Detection

**R-10** Deterministic detection must run before any AI-assisted pass. The AI pass must only be invoked if the deterministic result is `Clean` and AI is explicitly enabled in configuration.

**R-11** Detection signatures must be versioned. The version of the signature library used must be recorded in every audit event.

**R-12** The AI second pass, when enabled, must receive a constrained prompt. The AI response must be parsed as exactly one of two tokens: `clean` or `suspect`. Any other response is treated as `suspect`.

**R-13** The AI second pass must never cause issue content to be reproduced or reasoned over in the AI's output. The constrained prompt must make this explicit.

**R-14** The maximum permissible issue content length must be configurable. Content exceeding the limit must be classified `suspect` immediately without running pattern matching.

---

## Failure Handling

**R-15** If Entry Sentinel fails to process a new issue, the issue must remain unlabelled. Partial label application (e.g., `process:development` without `state:discovery`) is not acceptable.

**R-16** If Entry Sentinel fails to process an edit event, the issue must be conservatively quarantined and a human notified. Failure must never silently allow modified content to remain approved.

**R-17** A signing failure (e.g., Vault unavailable) during the clean path must halt the entire approval sequence. No labels are applied if the approval comment cannot be posted with a valid signature.

**R-18** All failures — including transient errors, retries, and terminal failures — must be recorded in the audit log with the issue ID, event type, and error context.

---

## Idempotency

**R-19** Entry Sentinel must process each GitHub webhook delivery ID exactly once. Duplicate deliveries (GitHub retries) must be discarded after the first processing, with no side effects.

**R-20** Before posting an approval comment, Entry Sentinel must check whether one already exists. If an approval comment is present and the re-scan is clean, the comment must be updated in-place, not duplicated.

**R-21** Before applying labels, Entry Sentinel must read the current label set and only write if the set differs from the target state.

---

## Audit

**R-22** Every webhook event processed by Entry Sentinel — including no-change outcomes and error outcomes — must produce exactly one audit event.

**R-23** Audit events must be immutable and append-only. They must not be deleted or modified after being written.

**R-24** The audit event for a suspect verdict must record the triggering detection signature ID and the detector (deterministic or AI) that produced the verdict.

---

## Quarantine

**R-25** A quarantined issue must be locked before any notification is sent to the reviewer.

**R-26** The quarantine comment must not disclose the detection reason, pattern, or signature ID. It must be generic.

**R-27** False positive resolution must restore the issue to its previous pipeline state (the `state:*` label it held before quarantine), not reset it to `state:discovery`. Triage progress must not be lost.

---

## Content Reversion (Mid-Pipeline)

**R-28** When an edited issue is quarantined mid-pipeline, the title and body must be reverted to the exact byte content recorded in the approval comment before any label changes.

**R-29** The approval comment must be removed before quarantine labels are applied.

---

## Observability

**R-30** All scan events must emit metrics to VictoriaMetrics: at minimum, a counter per verdict (clean/suspect/error) tagged with the event type (opened/edited) and the detector that produced the result.

**R-31** All operations that call external systems (GitHub API, Vault, AI provider) must emit latency histograms to VictoriaMetrics.

**R-32** All log statements must use structured logging via the `tracing` crate. No `println!` or `eprintln!` in library code.

---

## Security Headers and Transport

**R-33** Every incoming webhook must have its `X-Hub-Signature-256` header verified before any payload parsing occurs. Requests with invalid or absent signatures must be rejected with HTTP 401 before any business logic runs.

**R-34** No issue content, title, or body must ever appear in log output at any level. Logs may record issue IDs and detection metadata but never content.

**R-35** If content reversion fails during mid-pipeline quarantine (for example, because the GitHub edit history API is unavailable), reverting the content is abandoned. The issue must still be quarantined, locked, and flagged for mandatory manual content review via the alert channel. A content reversion failure must never result in leaving the issue in an approved state.

**R-36** The service registry must be protected against unauthorised writes. Write access must be restricted to Entry Sentinel's deployment automation and designated operators. The access control mechanism must be documented in the deployment runbook.

**R-37** Audit log events must be forwarded to a remote, independently accessible log aggregation system (e.g., Loki, OpenSearch, or equivalent) within the configured retention window. The remote system is the authoritative audit record. The local file is a write buffer and is not considered tamper-evident on its own.
