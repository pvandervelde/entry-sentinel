# Component Responsibilities — Entry Sentinel

This document describes the responsibilities, collaborators, and roles of each component using Responsibility-Driven Design (RDD). Each component is defined by **what it knows** and **what it does**, not by how it is implemented.

See [vocabulary.md](vocabulary.md) for term definitions and [architecture.md](architecture.md) for boundary placement.

---

## Event Intake Layer

Entry Sentinel can receive GitHub issue events from two sources. Both paths normalise events into the same internal `IssueEvent` type before any business logic runs.

### WebhookReceiver

**Responsibilities:**

- Knows: The GitHub webhook secret (retrieved from Vault at startup), the raw HTTP request
- Does: Validates the `X-Hub-Signature-256` HMAC-SHA256 header on every incoming request; rejects requests with invalid or missing signatures with HTTP 401; passes validated payloads to the `EventNormaliser`

**Collaborators:**

- `EventNormaliser` — receives the validated raw payload

**Roles:**

- Security boundary for the webhook path: the first and only place where untrusted HTTP input is received
- No business logic; purely validates transport-level integrity
- Backed by the `github-bot-sdk` crate

---

### QueueReceiver

**Responsibilities:**

- Knows: The queue connection configuration and queue-level authentication credentials
- Does: Consumes issue events from the configured queue; validates queue-level message authentication on every message; rejects unauthenticated messages before passing anything to the `EventNormaliser`; refuses to start if authentication credentials are absent or invalid

**Collaborators:**

- `EventNormaliser` — receives the validated raw message

**Roles:**

- Intake boundary for the queue path: the first and only place where untrusted queue messages are received
- No business logic; purely consumes and authenticates queue messages
- Authentication is mandatory, not optional; the `queue-runtime` crate must guarantee message authentication
- Backed by the `queue-runtime` crate

---

### EventNormaliser

**Responsibilities:**

- Knows: The expected payload formats for both webhook events and queue messages
- Does: Parses the raw payload into a typed `IssueEvent`; extracts the event type (`opened` or `edited`), issue ID, and issue content; routes `IssueEvent`s to `IssueOpenedHandler` or `IssueEditedHandler`; drops unsupported event types silently

**Collaborators:**

- `IssueOpenedHandler`
- `IssueEditedHandler`

**Roles:**

- Normaliser and router: decouples the intake transport from the business event handlers
- Neither path (webhook or queue) requires changes to business logic when the other path is added or modified

---

## Event Handlers

### IssueOpenedHandler

**Responsibilities:**

- Knows: The `issues: opened` webhook payload
- Does: Extracts the issue ID and content; checks the webhook delivery ID for deduplication; invokes the scanner; routes the verdict; records the audit event

**Collaborators:**

- `IssueContentExtractor`
- `DeliveryIdGuard` (idempotency check)
- `IssueScanner`
- `VerdictRouter`
- `AuditLogger`

**Roles:**

- Orchestrator: coordinates the full scan and routing flow for a new issue
- Does not make business decisions; delegates all scanning and routing

---

### IssueEditedHandler

**Responsibilities:**

- Knows: The `issues: edited` webhook payload
- Does: Extracts the issue ID and content; checks the delivery ID for deduplication; locates the existing approval comment; delegates to content integrity checking or full scan as appropriate; records the audit event

**Collaborators:**

- `IssueContentExtractor`
- `DeliveryIdGuard`
- `ApprovalCommentLocator`
- `ContentIntegrityChecker`
- `IssueScanner` (for re-scan when hash differs)
- `VerdictRouter`
- `AuditLogger`

**Roles:**

- Orchestrator: coordinates the integrity check and conditional re-scan for an edited issue

---

## Detection

### IssueScanner

**Responsibilities:**

- Knows: Detection configuration (signature library, AI enabled flag, AI provider settings)
- Does: Runs the `DeterministicDetector` first; if the result is clean and AI is enabled, runs the `AiDetector` as a second pass; combines results into a single `Verdict`; records which detector and which signature produced the result

**Collaborators:**

- `DeterministicDetector`
- `AiDetector` (optional)

**Roles:**

- Orchestrator: enforces the deterministic-first ordering
- Does not apply the verdict; only produces it

---

### DeterministicDetector

**Responsibilities:**

- Knows: The loaded `DetectionSignatureLibrary`
- Does: Applies each `DetectionSignature` in sequence against the `IssueContent`; returns `Clean` if no signature matches; returns `Suspect` with the ID of the first matching signature if any match

**Collaborators:**

- None — pure computation over loaded configuration

**Roles:**

- Evaluator: produces a deterministic, reproducible verdict with a traceable reason
- The first line of defence; must not call any external service

---

### AiDetector

**Responsibilities:**

- Knows: The constrained `AiPrompt` template; the AI provider configuration
- Does: Constructs a prompt from the template and the issue content; sends it to the `AiProvider`; parses the response; returns exactly `Clean` or `Suspect`; treats any non-binary or unparseable response as `Suspect`

**Collaborators:**

- `AiProvider` (external abstraction)

**Roles:**

- Evaluator: performs a second-opinion scan using the AI provider
- Must never forward AI output verbatim to any downstream system
- Must never log the AI response (to avoid leaking issue content)

---

## Content Integrity

### ContentIntegrityChecker

**Responsibilities:**

- Knows: The current `IssueContent` and the existing `ApprovalComment`
- Does: Hashes the current content; compares the result against the hash in the approval comment; returns `Unchanged` if the hashes match; returns `Changed` with the new hash if they differ

**Collaborators:**

- `ContentHasher`
- `ApprovalCommentParser`

**Roles:**

- Comparator: determines whether a meaningful content change has occurred
- No routing decisions; only compares hashes

---

### ContentHasher

**Responsibilities:**

- Knows: Nothing persistent — entirely stateless
- Does: Accepts `IssueContent`; computes SHA-256 over `UTF-8(title) + b"\n" + UTF-8(body)`; returns a `ContentHash`

**Collaborators:**

- None — pure computation

**Roles:**

- Pure function: deterministic, stateless, no side effects

---

### ApprovalCommentParser

**Responsibilities:**

- Knows: The expected format of the hidden approval comment
- Does: Locates the approval comment block within a comment body; parses the timestamp, hash, and signature fields; returns a structured `ApprovalComment` or a parse error

**Collaborators:**

- None — pure parsing

**Roles:**

- Parser: extracts structured data from the comment text
- Must be strict: any malformed comment must return an error, not a partial result

---

## Approval (Clean Path)

### ApprovalHandler

**Responsibilities:**

- Knows: The issue ID, the scan verdict (clean), the current timestamp
- Does: Invokes `ContentHasher`; constructs the `ApprovalPayload`; invokes `ApprovalSigner`; builds the `ApprovalComment` text; checks whether an approval comment already exists (idempotency); posts or replaces the comment via `GitHubCommentWriter`; applies clean-path labels via `GitHubIssueWriter`

**Collaborators:**

- `ContentHasher`
- `ApprovalSigner`
- `ApprovalCommentBuilder`
- `GitHubCommentWriter`
- `GitHubIssueWriter`

**Roles:**

- Effectful orchestrator: the only component that both signs and writes the approval comment
- Must not apply labels until the approval comment is successfully posted

---

### ApprovalSigner

**Responsibilities:**

- Knows: The Vault path for the Ed25519 private key
- Does: Signs the canonical `ApprovalPayload` bytes using Ed25519 via Vault; receives the `(ApprovalSignature, KeyId)` pair back from `VaultClient::sign()`; returns both to the caller; never caches the private key in memory beyond the scope of a single signing operation

**Collaborators:**

- `VaultClient` (external abstraction)

**Roles:**

- Security-critical: the only component that handles the private signing key
- Key material must never appear in logs, error messages, or debug output
- The `KeyId` returned by `VaultClient::sign()` is the canonical, authoritative key identifier for the approval. It must not be pre-fetched via a separate `VaultClient::key_id()` call, as that introduces a TOCTOU race during key rotation. See C-55.

---

### ApprovalCommentBuilder

**Responsibilities:**

- Knows: The expected comment format
- Does: Produces the exact approval comment text from a timestamp, `ContentHash`, and `ApprovalSignature`

**Collaborators:**

- None — pure construction

**Roles:**

- Builder: deterministic text formatter; no side effects

---

## Quarantine (Suspect Path)

### QuarantineHandler

**Responsibilities:**

- Knows: The issue ID, the quarantine configuration (reviewer target, security repository)
- Does: Applies `process:admin` and `state:quarantine` labels; locks the issue; posts the generic quarantine comment; notifies the designated security reviewer via `AlertSink`

**Collaborators:**

- `GitHubIssueWriter`
- `GitHubCommentWriter`
- `AlertSink` (external abstraction)

**Roles:**

- Effectful orchestrator: executes the full quarantine sequence atomically from the caller's perspective
- Must lock the issue before sending any notification
- The quarantine comment must not disclose the detection reason

---

### MidPipelineQuarantineHandler

**Responsibilities:**

- Knows: The `ApprovalComment` (which contains the approved title and body), the current pipeline state (labels)
- Does: Reverts the issue title and body to the approved content; removes the approval comment; strips all `process:*` and `state:*` labels; delegates to `QuarantineHandler` for the standard quarantine sequence

**Collaborators:**

- `GitHubIssueWriter`
- `GitHubCommentWriter`
- `QuarantineHandler`

**Roles:**

- Orchestrator: specialises quarantine for the mid-pipeline case where content reversion is required first

---

## Audit

### AuditLogger

**Responsibilities:**

- Knows: The event type, issue ID, delivery ID, verdict, triggering signature, detector used, signature library version, and timestamp
- Does: Appends a structured `AuditEvent` to the audit log for every processed webhook event, including no-change and error outcomes

**Collaborators:**

- `AuditLog` (external abstraction)

**Roles:**

- Observer: records every decision for post-hoc review; never influences the outcome of a scan

---

### DeliveryIdGuard

**Responsibilities:**

- Knows: The set of recently processed webhook delivery IDs (bounded window)
- Does: Returns `AlreadySeen` if the delivery ID has been processed within the window; returns `New` and records the ID otherwise

**Collaborators:**

- None (internal state, bounded cache)

**Roles:**

- Idempotency guard: prevents re-processing of retried webhook deliveries

---

## External System Abstractions

The following are **abstractions** (traits/interfaces) — not implementations. They define the contract that infrastructure must satisfy.

### GitHubIssueReader

- Knows: Nothing persistent
- Does: Reads issue content (title, body), metadata, labels, and comment list from the GitHub API

### GitHubIssueWriter

- Knows: Nothing persistent
- Does: Updates issue title, body, labels, and lock state via the GitHub API

### GitHubCommentWriter

- Knows: Nothing persistent
- Does: Creates, replaces, and deletes issue comments via the GitHub API

### VaultClient

- Knows: Nothing persistent (Vault token acquired at startup per Vault's AppRole flow)
- Does: Retrieves secrets by path; performs Ed25519 signing operations (if Vault transit is used) or returns raw key bytes for local signing

### AiProvider

- Knows: API endpoint and credentials for the configured LLM
- Does: Sends a prompt and receives a response; applies a timeout; returns the raw response text

### MetricsSink

- Knows: Nothing persistent
- Does: Emits named counters and timing histograms to VictoriaMetrics; never blocks the caller (fire-and-forget with internal buffering)

### AlertSink

- Knows: Notification targets (reviewer handle, on-call channel)
- Does: Sends structured notifications to the configured target(s)

### AuditLog

- Knows: Nothing persistent
- Does: Appends immutable `AuditEvent` records; guarantees at-least-once delivery; never truncates
