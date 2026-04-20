# Edge Cases — Entry Sentinel

Non-standard flows and failure modes that require explicit handling. Every item here must have a corresponding behavioural assertion or a referenced requirement.

---

## Lifecycle Edge Cases

### EC-01: Issue created and immediately deleted

**Scenario**: An `issues: opened` event is received, but by the time Entry Sentinel attempts to write back to the issue (post comment, apply labels), the issue has been deleted (404 from GitHub API).

**Handling**: The 404 must be treated as a benign terminal failure. The issue no longer exists, so there is nothing to quarantine. The audit log records the event with outcome `error` and detail `issue-not-found`. No alert is raised — this is expected on deleted issues.

---

### EC-02: Issue closed before processing completes

**Scenario**: An `issues: opened` event is received, but the issue is closed (not deleted) before Entry Sentinel writes back. GitHub allows writing labels and comments to closed issues.

**Handling**: Entry Sentinel continues processing normally. A closed issue that receives a clean verdict gets the approval comment and labels. The downstream pipeline will handle the closed state independently. If the issue should not be processed when closed, this is a product decision to be made by the operator via configuration (out of scope for the current version).

---

### EC-03: Issue re-opened after quarantine

**Scenario**: A quarantined (and locked) issue is unlocked and re-opened by a reviewer who resolves it as a false positive. The reviewer posts a fresh approval comment manually rather than using the automated resolution path.

**Handling**: If a subsequent `issues: edited` event arrives and an approval comment is present, Entry Sentinel's content integrity check will validate the comment's signature. A manually posted comment with an invalid signature will fail the check and trigger a re-scan. The re-scan result determines the outcome. This is the correct and safe behaviour — Entry Sentinel does not distinguish between automated and manual approval comments; it verifies cryptographically.

---

## Concurrency Edge Cases

### EC-04: Concurrent edit events for the same issue

**Scenario**: Two `issues: edited` events for the same issue arrive and are processed concurrently (e.g., rapid successive edits before the first event's processing completes).

**Handling**: Each event is processed independently. The second event's hash comparison uses the content from its own payload (which may differ from the first event's payload). The last writer wins for GitHub API state. The idempotency guard (delivery ID check) prevents the *same* delivery from being processed twice, but two distinct deliveries for two distinct edits are each processed once. Metric alerting on concurrent processing of the same issue ID may be useful for observability, but the current version does not require serialisation of events per issue.

---

### EC-05: Concurrent new issue events (stress scenario)

**Scenario**: Many `issues: opened` events arrive simultaneously (e.g., after an outage clears and a queue drains).

**Handling**: Each event is handled independently and in parallel. The GitHub App rate limit is the primary constraint. Entry Sentinel must respect GitHub's rate limit response headers and back off as required. VictoriaMetrics metrics must track in-flight webhook processing count to surface queue depth.

---

## Infrastructure Edge Cases

### EC-06: Vault unavailable during signing

**Scenario**: Entry Sentinel has produced a clean verdict but cannot retrieve the Ed25519 key from Vault (e.g., Vault is sealed, network partition, or token expired).

**Handling**:

- For a **new issue**: the clean path is aborted. No approval comment is posted, no labels are applied. The issue remains unlabelled. An alert is raised. The audit log records outcome `error` with context `vault-unavailable`. The watchdog will catch the unlabelled issue if Vault remains down long enough.
- For an **edit event**: the issue is conservatively quarantined (if the hash has changed). If the quarantine itself cannot proceed due to Vault unavailability (signing is not required for quarantine), proceed with quarantine using only GitHub API calls (labels and lock); signing is only required for the clean path.

---

### EC-07: GitHub API rate limit hit during processing

**Scenario**: Entry Sentinel is mid-operation and receives a 429 response from the GitHub API.

**Handling**: Retry with exponential backoff up to the configured maximum retry count and timeout window. If the timeout expires before a successful response, the event is treated as a terminal failure (same rules as EC-06 apply: unlabelled for new issues; conservative quarantine for edits). A metric counter for `github_rate_limit_hit` must be emitted on every 429. A sustained rate of 429 responses must trigger an alert.

---

### EC-08: GitHub API returns 5xx during processing

**Scenario**: GitHub returns a 500 or 503 response during a write operation.

**Handling**: Retry with exponential backoff (same policy as 429). Terminal failure handling same as EC-07.

---

## Content Edge Cases

### EC-09: Issue content exceeds configured maximum size

**Scenario**: An issue has a combined title + body length exceeding the configured maximum (default: 65 536 bytes of UTF-8 content).

**Handling**: Classify as `Suspect` immediately without running any pattern matching. The triggering reason recorded in the audit log is `content-too-large`. This is a structural heuristic — very large content is anomalous for a normal issue and is consistent with prompt injection or data exfiltration attempts. The detection signature library version is still recorded (it applies to the heuristic boundary value).

---

### EC-10: Issue with empty body

**Scenario**: An issue is opened with a non-empty title and an empty body.

**Handling**: Fully supported. The canonical hash byte sequence is `UTF-8(title) + b"\n" + b""`. The newline separator is always present. An empty body is represented as an empty byte sequence after the separator. Detection continues with just the title content.

---

### EC-11: Issue with non-UTF-8 content

**Scenario**: GitHub's API returns issue content that is not valid UTF-8 (extremely rare given GitHub's own input handling, but possible via API).

**Handling**: Classify as `Suspect` immediately. The triggering reason is `non-utf8-content`. Do not attempt to process non-UTF-8 content further (avoids encoding confusion attacks).

---

### EC-12: Issue title is empty

**Scenario**: An issue has an empty title (GitHub currently requires a title but API quirks may produce empty strings).

**Handling**: Classify as `Suspect` immediately. The triggering reason is `empty-title`. An issue without a title is structurally anomalous and cannot be meaningfully routed.

---

## Approval Comment Edge Cases

### EC-13: Approval comment deleted by a third party

**Scenario**: After an issue is approved, a human or bot deletes the approval comment (not Entry Sentinel).

**Handling**: When the next `issues: edited` event arrives, Entry Sentinel will fail to locate the approval comment and treat the issue as a new unscanned issue. The full scan runs. If the verdict is clean, a fresh approval comment is posted. If suspect, the issue is quarantined. This is the correct safe behaviour — the absence of a valid approval comment is always treated as unapproved.

---

### EC-14: Multiple approval comments present

**Scenario**: Due to a race condition or external intervention, more than one comment matching the approval comment format is present on an issue.

**Handling**: Entry Sentinel uses the most recently created approval comment (by GitHub comment ID or creation timestamp). An alert is emitted indicating a duplicate approval comment was found, as this is anomalous. Entry Sentinel then proceeds with the newest comment. During the next write (update or delete), it must remove all approval comments to restore the single-comment invariant.

---

### EC-15: Approval comment is malformed

**Scenario**: A comment that begins with `<!-- entry-sentinel` exists but is not parseable (missing fields, invalid base64, etc.).

**Handling**: The `ApprovalCommentParser` returns a `ParseError`. The issue is treated as if no approval comment exists and a full scan runs. This is the same as EC-13.

---

## AI Provider Edge Cases

### EC-16: AI provider returns non-binary output

**Scenario**: The AI returns a response that is neither `clean` nor `suspect` — for example, an explanation, an error message, or an empty string.

**Handling**: Classify as `Suspect` (fail safe). The triggering reason is `ai-non-binary-response`. The raw AI response must **not** be logged (to avoid leaking issue content that may be present in the AI's output). The audit log records only the reason.

---

### EC-17: AI provider is unreachable or times out

**Scenario**: The AI second pass cannot complete because the provider is unreachable or exceeds the configured timeout.

**Handling**: Classify as `Suspect` (fail safe). The triggering reason is `ai-provider-error`. The audit log records the error category (timeout / connection failure) but not the provider's error response body.

---

## Idempotency Edge Cases

### EC-18: Webhook delivery retry (same delivery ID)

**Scenario**: GitHub retries a webhook delivery because Entry Sentinel did not respond within the timeout window, or GitHub's delivery system marked it for retry.

**Handling**: The `DeliveryIdGuard` checks the delivery ID before any business logic runs. If the ID is in the recent-deliveries window, the handler returns HTTP 200 immediately with no side effects. The window must be large enough to cover GitHub's retry interval (GitHub retries within 72 hours; a 24-hour window is sufficient given the bounded nature of the threat).

---

### EC-19: False positive resolution requiring state restoration

**Scenario**: A reviewer manually resolves a false positive for an issue that was at `state:triage-complete` when it was quarantined mid-pipeline.

**Handling**: The reviewer's resolution process must post a fresh approval comment and restore the issue to `state:triage-complete` (not `state:discovery`). This requires the human review UI / process to have recorded the prior pipeline state. Entry Sentinel's audit log records the prior `PipelineState` at the time of quarantine, which provides the information needed for restoration.

---

## Startup Edge Cases

### EC-20: Detection signature library fails to load at startup

**Scenario**: The versioned detection signature configuration is unreachable or contains a parse error.

**Handling**: Entry Sentinel must refuse to start. It must not operate with a missing or partially-loaded signature library. The startup failure must be logged with the specific load error. This is a hard failure that requires human intervention before the service can start.

---

### EC-21: Vault unreachable at startup

**Scenario**: Entry Sentinel cannot reach Vault during startup (to retrieve the webhook secret or app credentials).

**Handling**: Entry Sentinel must refuse to start. It must not begin accepting webhook events if it cannot validate them. Startup failure is logged and a health check endpoint returns 503.

---

## Transport and Intake Edge Cases

### EC-22: Inbound webhook body exceeds maximum size

**Scenario**: An HTTP request arrives at the webhook endpoint with a body larger than 1 MB (the configured maximum, matching GitHub's documented maximum payload size).

**Handling**: The HTTP server must reject the request with HTTP 413 (Request Entity Too Large) before the body is fully read into memory. HMAC validation is not performed — the body is never buffered. The event is not processed. A metric counter for `entry_sentinel_webhook_body_too_large_total` must be incremented. If this counter increases consistently, an alert must fire (sustained over-size requests are a DoS indicator).

---

### EC-23: Content reversion fails during mid-pipeline quarantine

**Scenario**: `MidPipelineQuarantineHandler` attempts to revert the issue title and body to the approved content, but the prior-state retrieval fails (GitHub edit history API unavailable, API returns 404 for history, or the retrieved content does not match the approval hash).

**Handling**: Content reversion is abandoned. The issue must still be quarantined using the full quarantine sequence (apply `process:admin` + `state:quarantine`, lock the issue). The alert sent to the security reviewer must include a priority flag: `content-not-reverted`. This flag indicates that the malicious edit content may still be visible on the quarantined issue and requires manual inspection and content removal before the issue can be re-entered into any pipeline. The audit log records both the reversion failure reason and the quarantine outcome. See R-35.

---

## AI Circuit Breaker Edge Cases

### EC-24: AI provider sustained failure (circuit breaker)

**Scenario**: The AI provider fails (timeout or error) for N consecutive requests (configurable, default: 5). When the AI second pass is enabled and the provider is persistently unreachable, all issues that pass deterministic screening must wait for the full AI timeout before being classified `Suspect`. During a prolonged outage this fills the quarantine queue with false positives.

**Handling**: After N consecutive failures, an open circuit breaker skips AI calls and uses the deterministic-only result as the final verdict. The current circuit state (`closed` / `open` / `half-open`) must be exposed as a metric label on `entry_sentinel_ai_errors_total`. An alert fires when the circuit opens. The circuit breaker attempts a single probe request after a configurable cool-down period (default: 60 seconds). A successful probe closes the circuit; a failing probe restarts the cool-down. The audit log records whether the deterministic-only verdict was used because the circuit was open.
