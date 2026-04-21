# Vocabulary — Entry Sentinel

This document defines the domain concepts used throughout the Entry Sentinel specification and implementation. All code, documentation, and discussion should use these terms consistently.

---

## Core Concepts

### Issue

A GitHub issue in the target repository. The unit of work flowing through the intake pipeline.

- Identified by a numeric GitHub issue ID (wrapped in `IssueId`)
- Has a title (UTF-8 string) and a body (UTF-8 string, may be empty)
- May carry zero or more labels
- May be locked or unlocked
- May carry one or more comments

### IssueContent

The combination of an issue's title and body at a specific point in time. This is what Entry Sentinel scans and hashes.

- Title: UTF-8 string
- Body: UTF-8 string (empty body is represented as an empty string, not null)
- The canonical byte representation for hashing is: `UTF-8(title) + b"\n" + UTF-8(body)`

### IssueId

A branded wrapper over GitHub's numeric issue ID. Never treated as a plain integer in domain code.

### Verdict

The binary output of an issue scan. Exactly one of:

- `Clean` — the issue content passed all detection checks and is safe to enter the pipeline
- `Suspect` — the issue content failed one or more detection checks, or was ambiguous

There are no intermediate values. No confidence scores. No "probably clean". Ambiguity resolves to `Suspect`.

### ScanResult

The output of a single detection pass, carrying:

- The `Verdict` (`Clean` or `Suspect`)
- The ID of the triggering detection signature (if `Suspect`)
- The name of the detector that produced the result (`Deterministic` or `Ai`)
- The version of the detection signature library used

### ContentHash

A SHA-256 digest computed over the canonical byte representation of an `IssueContent`.

- Stored as the hex-encoded digest, prefixed with `sha256:` (e.g., `sha256:a3f2...`)
- A newtype wrapping a 32-byte array — never a plain string in domain code
- Used both in the approval comment and by downstream services for integrity verification

### ApprovalPayload

The structured data that is signed by Entry Sentinel's Ed25519 private key:

```
issue:<github_numeric_id>\napproved:<ISO 8601 timestamp>\nhash:sha256:<hex>\nkey_id:<key_id>\n
```

This is the exact byte sequence passed to the signing operation. The issue ID and hash bind the signature to a specific issue and specific content. The timestamp records when the verdict was produced. The `key_id` identifies which key was used, enabling multi-key trust stores for rotation transitions.

### ApprovalSignature

An Ed25519 signature over an `ApprovalPayload`.

- A newtype wrapping 64 bytes — never a plain `Vec<u8>` or `String` in domain code
- Serialised as base64-encoded bytes for storage in the approval comment
- Verifiable by any party holding Entry Sentinel's published public key

### ApprovalComment

The hidden HTML comment posted on an issue after a clean verdict. Contains:

- `issue`: the GitHub numeric issue ID
- `approved`: ISO 8601 timestamp of the approval decision
- `hash`: the `ContentHash` at the time of approval
- `key_id`: the identifier of the Ed25519 key used to sign (see `KeyId`)
- `signature`: the base64-encoded `ApprovalSignature`

Format:

```
<!-- entry-sentinel
issue: <github numeric issue id>
approved: <timestamp>
hash: sha256:<hex>
key_id: <key_id>
signature: <base64>
-->
```

The approval comment is the **single source of truth** for whether an issue has been approved. Its absence means the issue has not been approved (or approval was revoked). Its presence plus a valid signature (verified with the key identified by `key_id`) means it was approved by Entry Sentinel.

### ApprovalTimestamp

The ISO 8601 UTC timestamp recorded at the moment the clean verdict was produced. Stored in the `ApprovalComment` and included in the signed `ApprovalPayload`.

### KeyId

An opaque string identifier for a specific Ed25519 key pair. Stored in the `ApprovalComment` and included in the signed `ApprovalPayload`.

- Allows downstream services to look up the correct public key from the service registry when verifying an approval signature
- Enables key rotation with a transition window: old approvals signed with an old `key_id` remain verifiable for as long as the corresponding public key is present in the registry
- Must be stable and unique per key pair; never reused

---

## Detection Concepts

### DetectionSignature

A versioned, named pattern used by the `DeterministicDetector` to identify suspect content. May be:

- A regular expression matching known prompt injection phrases
- A structural rule (e.g., "content length exceeds N bytes")
- A URL pattern matcher (e.g., base64-encoded URLs, known suspicious domains)
- A heuristic (e.g., repeated `\n` injection patterns, unusual Unicode characters)

Detection signatures are maintained as **external versioned configuration**, not compiled into the binary. See [ADR-0006](../adr/ADR-0006-versioned-external-detection-signatures.md).

### DetectionSignatureLibrary

The complete, versioned set of `DetectionSignature` instances loaded at startup. Has an associated version string recorded in scan audit entries.

### AiPrompt

The constrained prompt sent to the AI provider during the optional second pass. The prompt:

- Presents the issue content to the AI within an explicitly delimited block, isolated from the instruction text
- Instructs the AI to produce exactly one of two tokens: `clean` or `suspect`
- Explicitly forbids the AI from reproducing or reasoning over issue content in its output

The `AiPrompt` template is configuration — it is not hardcoded. However, the template must satisfy the following structural requirements, validated at startup:

1. The template must contain the issue content placeholder (e.g., `{issue_content}`) exactly once.
2. The binary-verdict instruction (`clean` or `suspect` only) must appear in the template and must not be overridable by issue content.
3. The issue content placeholder must be surrounded by explicit delimiters (e.g., triple-backtick blocks or XML-style tags) that structurally separate attacker-controlled input from the instruction.

A template that fails any of these requirements is a hard startup failure. See C-54.

---

## Routing Concepts

### PipelineLabel

One of the known GitHub label names used to route issues through the pipeline. Known pipeline labels:

| Label | Meaning |
|---|---|
| `process:development` | Issue is in the development pipeline |
| `process:admin` | Issue is in the admin/quarantine pipeline |
| `state:discovery` | Issue is at the discovery stage (earliest clean state) |
| `state:quarantine` | Issue is quarantined |

Other `state:*` labels represent later pipeline stages (managed by downstream services).

### PipelineState

The combination of `process:*` and `state:*` labels present on an issue at a given point in time. Entry Sentinel reads the `PipelineState` when resolving false positives (to restore the correct state rather than reset to `state:discovery`).

### QuarantineRecord

Metadata written to the audit log when an issue is quarantined. Contains:

- Issue ID
- Timestamp of quarantine
- Verdict that triggered quarantine
- Triggering `DetectionSignature` ID (if deterministic)
- Detecting pass (`Deterministic` or `Ai`)
- Whether the quarantine was an initial quarantine or a mid-pipeline quarantine
- Reviewer notification target

---

## Operational Concepts

### WatchdogThreshold

The maximum age of an unlabelled issue (in minutes) before the watchdog raises an alert. An unlabelled issue older than this threshold indicates that Entry Sentinel may have failed to process the `issues: opened` event.

### AuditEvent

A structured, immutable record written to the audit log for every webhook event processed by Entry Sentinel. Contains:

- GitHub webhook delivery ID (for deduplication)
- Event type (`opened` or `edited`)
- Issue ID
- Outcome (`clean`, `suspect`, `no-change`, `error`)
- Triggering signature ID (if suspect)
- Detection pass that produced the verdict
- Detection signature library version
- Timestamp

### WebhookDeliveryId

The unique delivery identifier assigned by GitHub to each webhook event. Used by Entry Sentinel to detect and discard duplicate deliveries (idempotency guard).

---

## Security Concepts

### Ed25519KeyPair

The asymmetric signing key pair used by Entry Sentinel:

- **Private key**: stored in HashiCorp Vault; never written to disk or logged; used to sign `ApprovalPayload` instances
- **Public key**: published in the service registry; used by downstream services to verify `ApprovalSignature` instances, identified by `key_id`

### VaultPath

A reference to a secret location in HashiCorp Vault. Entry Sentinel holds Vault paths for:

- The Ed25519 private key
- The GitHub App private key (for API authentication)
- The GitHub webhook secret (for HMAC validation)

### WebhookSecret

The shared secret used to compute and verify HMAC-SHA256 signatures on incoming GitHub webhook payloads. Stored in Vault. Never logged.
