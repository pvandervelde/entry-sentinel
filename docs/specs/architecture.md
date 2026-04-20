# Architecture — Entry Sentinel

This document defines the clean architecture boundaries for Entry Sentinel: what constitutes business logic, what the external system interfaces are, and how infrastructure implementations relate to both.

See [responsibilities.md](responsibilities.md) for per-component details and [vocabulary.md](vocabulary.md) for term definitions.

---

## Architectural Principle

Entry Sentinel follows a strict **dependency rule**: business logic depends on abstractions; infrastructure depends on business logic; nothing points outward from business logic to concrete infrastructure.

```
┌──────────────────────────────────────────────────────────────┐
│                      Business Logic                          │
│  (detection, hashing, signing payload, routing, quarantine)  │
│  Depends on: abstractions only. No framework imports.        │
└──────────────────────┬───────────────────────────────────────┘
                       │ uses (via abstractions)
┌──────────────────────▼───────────────────────────────────────┐
│                  External System Interfaces                   │
│  (traits: EventSource, GitHubIssueReader, VaultClient, …)    │
│  Defined in business code; implemented in infrastructure.    │
└──────────────────────┬───────────────────────────────────────┘
                       │ implemented by
┌──────────────────────▼───────────────────────────────────────┐
│                    Infrastructure                             │
│  (github-bot-sdk, queue-runtime, octocrab, Vault client, …)  │
│  Wired together only at the binary entry point (main.rs).    │
└──────────────────────────────────────────────────────────────┘
```

---

## Business Logic Layer

Business logic contains no imports from infrastructure crates (no `octocrab`, no HTTP client, no Vault SDK). It depends only on:

- The Rust standard library
- Cryptographic primitives (`ed25519-dalek`, `sha2`)
- `thiserror` for error types
- The abstract traits defined in the external system interface layer

### Detection

**Concepts:** `IssueContent`, `Verdict`, `ScanResult`, `DetectionSignature`, `DetectionSignatureLibrary`

**Operations:**

- `scan(content: &IssueContent, library: &DetectionSignatureLibrary) -> ScanResult` — deterministic scan of content against the loaded signature library
- `ai_scan(content: &IssueContent, prompt_template: &str) -> ScanResult` — AI second-pass scan via the `AiProvider` abstraction
- `combine_results(deterministic: ScanResult, ai: Option<ScanResult>) -> Verdict` — merges results; any `Suspect` wins

**Business rules:**

- Deterministic scan always runs; AI scan only runs when enabled and the deterministic result is `Clean`
- Any `Suspect` result from either detector produces a `Suspect` verdict
- An error from the AI detector produces a `Suspect` verdict (fail safe)
- A non-binary AI response produces a `Suspect` verdict (fail safe)

---

### Content Integrity

**Concepts:** `ContentHash`, `ApprovalComment`, `ApprovalPayload`, `ApprovalSignature`

**Operations:**

- `hash_content(content: &IssueContent) -> ContentHash` — pure SHA-256 over canonical bytes
- `parse_approval_comment(text: &str) -> Result<ApprovalComment, ParseError>` — strict parser
- `build_approval_comment(issue_id: IssueId, timestamp: ApprovalTimestamp, hash: &ContentHash, key_id: &KeyId, signature: &ApprovalSignature) -> String` — exact comment text
- `build_approval_payload(issue_id: IssueId, timestamp: ApprovalTimestamp, hash: &ContentHash, key_id: &KeyId) -> ApprovalPayload` — the bytes to be signed
- `compare_hashes(current: &ContentHash, stored: &ContentHash) -> HashComparison` — returns `Unchanged` or `Changed`

**Business rules:**

- The canonical byte sequence for hashing is always `UTF-8(title) + b"\n" + UTF-8(body)` with no normalisation
- An empty body is represented as an empty byte sequence (not null or whitespace)
- Parsing is strict: any deviation from the expected format returns `ParseError`

---

### Verdict Routing

**Concepts:** `Verdict`, `PipelineLabel`, `PipelineState`

**Operations:**

- `route_new_issue(issue_id: IssueId, verdict: Verdict, ...) -> RouteOutcome` — dispatches to approval or quarantine handler
- `route_edited_issue(issue_id: IssueId, hash_comparison: HashComparison, verdict: Option<Verdict>, ...) -> RouteOutcome` — dispatches based on comparison result and re-scan verdict

**Business rules:**

- `Verdict::Clean` → approval comment + `process:development` + `state:discovery`
- `Verdict::Suspect` → `process:admin` + `state:quarantine` + locked + comment + notification
- No labels are applied before the approval comment is successfully posted (for clean path)
- No partial state: all clean-path writes complete or none are committed (best-effort atomicity via ordering)

---

### Approval Signing

**Concepts:** `ApprovalPayload`, `ApprovalSignature`, `KeyId`, `VaultClient`

**Operations:**

- `sign(payload: &ApprovalPayload, vault: &dyn VaultClient) -> Result<(ApprovalSignature, KeyId), SigningError>`

**Business rules:**

- The private key must never be cached beyond the scope of a single signing operation
- The private key must never appear in any log, error message, or metric label
- The `KeyId` returned by the signing operation must match what is stored in Vault alongside the active key and must be included in the approval comment
- A signing failure is a hard failure for the clean path; the issue must not be labelled if signing fails

---

### Quarantine State Machine

**Concepts:** `IssueId`, `PipelineState`, `ApprovalComment`

**Operations:**

- `quarantine_new(issue_id: IssueId, ...) -> QuarantineOutcome` — standard quarantine for a new suspect issue
- `quarantine_mid_pipeline(issue_id: IssueId, approved_content: &IssueContent, prior_state: PipelineState, ...) -> QuarantineOutcome` — reversion + quarantine for a suspect edit

**Business rules (mid-pipeline):**

- Content reversion (title + body) must complete before label changes
- Approval comment removal must complete before quarantine labels are applied
- Issue must be locked before any notification is sent

---

## External System Interface Layer

These are the traits that the business logic depends on. They are defined in business code but implemented in infrastructure.

```rust
// Illustrative — exact signatures defined by Interface Designer

/// Abstracts over the two event intake paths: webhook and queue.
/// Implementations push normalised IssueEvents to a shared channel.
trait EventSource {
    fn start(&self, sender: mpsc::Sender<IssueEvent>) -> impl Future<Output = Result<(), IntakeError>>;
}

trait GitHubIssueReader {
    fn read_issue(&self, id: IssueId) -> impl Future<Output = Result<Issue, GitHubError>>;
    fn list_comments(&self, id: IssueId) -> impl Future<Output = Result<Vec<Comment>, GitHubError>>;
    fn list_labels(&self, id: IssueId) -> impl Future<Output = Result<Vec<Label>, GitHubError>>;
}

trait GitHubIssueWriter {
    fn update_content(&self, id: IssueId, title: &str, body: &str) -> impl Future<Output = Result<(), GitHubError>>;
    fn set_labels(&self, id: IssueId, labels: &[PipelineLabel]) -> impl Future<Output = Result<(), GitHubError>>;
    fn lock(&self, id: IssueId) -> impl Future<Output = Result<(), GitHubError>>;
}

trait GitHubCommentWriter {
    fn post_comment(&self, id: IssueId, body: &str) -> impl Future<Output = Result<CommentId, GitHubError>>;
    fn update_comment(&self, comment_id: CommentId, body: &str) -> impl Future<Output = Result<(), GitHubError>>;
    fn delete_comment(&self, comment_id: CommentId) -> impl Future<Output = Result<(), GitHubError>>;
}

trait VaultClient {
    fn sign(&self, path: &VaultPath, payload: &[u8]) -> impl Future<Output = Result<(ApprovalSignature, KeyId), VaultError>>;
    // key_id() exists for registry publication and Vault health checks only.
    // It must NOT be called to pre-build ApprovalPayload before sign() —
    // the KeyId returned by sign() is the authoritative identifier. See C-55.
    fn key_id(&self, path: &VaultPath) -> impl Future<Output = Result<KeyId, VaultError>>;
}

trait AiProvider {
    fn query(&self, prompt: &str) -> impl Future<Output = Result<String, AiError>>;
}

trait MetricsSink {
    fn increment(&self, name: &str, labels: &[(&str, &str)]);
    fn record_duration(&self, name: &str, duration: Duration, labels: &[(&str, &str)]);
}

trait AlertSink {
    fn send(&self, target: &AlertTarget, message: &str) -> impl Future<Output = Result<(), AlertError>>;
}

trait AuditLog {
    fn append(&self, event: AuditEvent) -> impl Future<Output = Result<(), AuditError>>;
}
```

---

## Infrastructure Layer

Concrete implementations wired at `main.rs`. Not imported by business logic.

| Abstraction | Implementation | Crate |
|---|---|---|
| `EventSource` (webhook) | `WebhookEventSource` | `github-bot-sdk` |
| `EventSource` (queue) | `QueueEventSource` | `queue-runtime` |
| `GitHubIssueReader` | `OctocrabIssueClient` | `octocrab` |
| `GitHubIssueWriter` | `OctocrabIssueClient` | `octocrab` |
| `GitHubCommentWriter` | `OctocrabCommentClient` | `octocrab` |
| `VaultClient` | `HttpVaultClient` | `reqwest` + Vault REST API |
| `AiProvider` | `OpenAiCompatibleProvider` | `reqwest` |
| `MetricsSink` | `VictoriaMetricsClient` | `opentelemetry` |
| `AlertSink` | `HttpAlertClient` | `reqwest` |
| `AuditLog` | `StructuredFileAuditLog` | `tracing` + file sink (O_APPEND mode; entries forwarded to remote aggregation — see R-37 and operations.md §Audit Log Durability) |

---

## Data Flow Across Boundaries

### New Issue (clean path)

```
[GitHub Webhook] → WebhookEventSource (github-bot-sdk, validates HMAC)  ─┐
                                                                           ├→ EventNormaliser (IssueEvent)
[Queue]          → QueueEventSource (queue-runtime)  ─────────────────────┘
  → IssueOpenedHandler
      → DeliveryIdGuard (idempotency check)        [internal state]
      → IssueContentExtractor (parses event)       [pure]
      → IssueScanner
          → DeterministicDetector                  [pure + config]
          → AiDetector (optional)                  [AiProvider]
      → VerdictRouter (clean)
          → ApprovalHandler
              → ContentHasher                      [pure]
              → ApprovalSigner                     [VaultClient → (ApprovalSignature, KeyId)]
              → ApprovalCommentBuilder             [pure]
              → GitHubCommentWriter                [GitHub API]
              → GitHubIssueWriter (labels)         [GitHub API]
      → AuditLogger                                [AuditLog]
```

### Edited Issue (suspect re-scan — mid-pipeline quarantine)

```
[Webhook or Queue] → EventNormaliser
  → IssueEditedHandler
    → DeliveryIdGuard
    → IssueContentExtractor
    → ApprovalCommentLocator                       [GitHubIssueReader]
    → ApprovalCommentParser                        [pure]
    → ContentIntegrityChecker
        → ContentHasher                            [pure]
        → HashComparator                           [pure]
    → IssueScanner (re-scan)                       [see above]
    → VerdictRouter (suspect)
        → MidPipelineQuarantineHandler
            → GitHubIssueWriter (revert content)   [GitHub API]
            → GitHubCommentWriter (delete approval)[GitHub API]
            → GitHubIssueWriter (swap labels)      [GitHub API]
            → QuarantineHandler
                → GitHubIssueWriter (lock)         [GitHub API]
                → GitHubCommentWriter (post notice)[GitHub API]
                → AlertSink (notify reviewer)      [HTTP]
    → AuditLogger                                  [AuditLog]
```

---

## Module Organisation Guidance

The Interface Designer will determine the precise file structure. The following logical groupings reflect the architectural boundaries described above:

- **Event intake**: the two `EventSource` implementations plus the `EventNormaliser`; HMAC validation lives in the webhook implementation only
- **Detection**: deterministic detector, AI detector, scanner orchestration — no I/O; pure or async via trait
- **Content integrity**: hasher, parser, builder — all pure
- **Approval and quarantine**: the two routing outcomes — depend on GitHub and Vault abstractions
- **Audit**: `AuditEvent` construction and logging — depends on `AuditLog` abstraction
- **Infrastructure**: one module per external system; wired in `main.rs` only

Binary entry point (`main.rs`):

- Reads configuration
- Acquires Vault secrets
- Constructs all infrastructure implementations
- Injects them into the business logic handlers via their abstract interfaces
- Starts the HTTP server
