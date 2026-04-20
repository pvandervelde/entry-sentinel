# Overview — Entry Sentinel

## System Context

Entry Sentinel is a standalone service backed by a GitHub App. It operates as the **first and only intake gate** for a GitHub issue pipeline. Every newly created GitHub issue passes through Entry Sentinel before any other automation touches it.

Entry Sentinel is deliberately narrow. It has no knowledge of priority, technical complexity, strategic alignment, or issue quality. Its sole responsibility is to determine whether an issue is **safe to process** and to durably record that determination on the issue itself.

## Position in the Pipeline

```
GitHub Issue created (unlabelled)
         │
         ▼
  ┌─────────────────┐
  │  Entry Sentinel │  ← this service
  └────────┬────────┘
           │
     ┌─────┴──────┐
     │            │
   clean        suspect
     │            │
     ▼            ▼
  signed       process:admin
  approval   + state:quarantine
  comment    + locked
     +         + quarantine comment
  process:     + reviewer notified
  development
     +
  state:
  discovery
     │
     ▼
  Triage Titan (picks up process:development issues)
     │
     ▼
  Scope-Sage
     │
     ▼
  CogWorks
```

All downstream services operate **only** on labelled issues. Entry Sentinel is what makes that labelling happen. Its signed approval comment is the cryptographic anchor that every downstream service uses to verify content integrity independently before doing any work.

## Responsibilities

Entry Sentinel has exactly two responsibilities:

1. **Scan new issues** — apply deterministic pattern matching (and optionally an AI second pass) to determine whether a newly opened issue is safe to enter the pipeline.

2. **Maintain content integrity for approved issues** — re-scan any edited issue that already carries an approval, and revoke pipeline access if the new content fails the scan.

Entry Sentinel does **not**:

- Assess issue quality, completeness, or priority
- Interact with the issue author in any way
- Access the repository codebase, ADRs, or architecture documents
- Make judgements about strategic alignment or technical feasibility

## High-Level Processing Flow

### New Issue (`issues: opened`)

```
1. Receive and validate webhook (HMAC-SHA256)
2. Extract issue content (title + body)
3. Run deterministic detection:
   a. Pattern matching against prompt injection signatures
   b. URL scanning (suspicious / encoded)
   c. Structural heuristics (length, character sets, encoding, repeated patterns)
4. If AI second pass is enabled AND deterministic result is clean:
   a. Send constrained prompt to AI provider
   b. Accept only binary output (clean / suspect)
5. Produce verdict: clean or suspect
6. Route:
   clean  → post approval comment + apply process:development + state:discovery
   suspect → apply process:admin + state:quarantine + lock + notify reviewer
7. Record to audit log
```

### Edited Issue (`issues: edited`)

```
1. Receive and validate webhook (HMAC-SHA256)
2. Locate existing approval comment on the issue
3. If no approval comment: treat as new issue (full scan from step 3 above)
4. Hash current content (SHA-256 over title + "\n" + body)
5. Compare hash with hash in approval comment
6. If hashes match: no-op (record to audit log, stop)
7. If hashes differ: re-scan (steps 3–5 above)
   clean  → replace approval comment with new hash + signature, retain labels
   suspect → revert title + body to approved content from comment
             remove approval comment
             strip process:development + state:* labels
             apply process:admin + state:quarantine + lock + notify reviewer
8. Record to audit log
```

## Approval Comment Format

On a clean verdict, Entry Sentinel posts the following as a hidden HTML comment on the issue. It is not visible in the GitHub web UI but is trivially parseable by downstream services.

```
<!-- entry-sentinel
issue: <github numeric issue id>
approved: <ISO 8601 timestamp, e.g. 2026-04-15T10:23:44Z>
hash: sha256:<lowercase hex of SHA-256 over UTF-8 title + "\n" + body>
key_id: <identifier of the Ed25519 key used to sign>
signature: <Ed25519 signature over "issue:<id>\napproved:<timestamp>\nhash:sha256:<hex>\nkey_id:<key_id>\n", base64-encoded>
-->
```

- The private key is held in HashiCorp Vault.
- Each key has a `key_id`. The public key and its `key_id` are published in the service registry so any downstream service can verify without contacting Entry Sentinel directly.
- Downstream services verify the signature independently — no coordination with Entry Sentinel required.
- During key rotation, both the old and new public keys coexist in the registry for a configurable transition window. Old approvals signed with the old `key_id` remain verifiable throughout the window.
- On re-approval after a clean edit, the existing approval comment is replaced with a new one.

## Downstream Precondition Check

Every downstream service must perform this check before acting on any issue:

1. Locate the Entry Sentinel approval comment
2. Confirm the `issue:` field in the comment matches the issue being processed
3. Look up the public key by `key_id` from the service registry; confirm the key is not past its retired-until date
4. Verify the Ed25519 signature against that public key
5. Compute SHA-256 over the current title and body
6. Compare the computed hash against the hash in the approval comment

If any step fails — comment absent, issue ID mismatch, key not found or expired, signature invalid, or hash mismatch — the downstream service **must abort**, post no output, and raise an alert. This makes every downstream service self-defending without any inter-service coordination.

## Failure Posture

Entry Sentinel fails **conservatively**:

| Scenario | Outcome |
|---|---|
| Entry Sentinel fails to process a new issue | Issue remains unlabelled; watchdog alerts on threshold breach |
| Entry Sentinel fails to process an edit event | Issue is conservatively quarantined; human is notified |
| Vault unavailable during signing | Processing halted; no partial state written; alert raised |
| GitHub API unavailable for writes | Retried with backoff; if persistent, treated as above |

**Unlabelled is never equivalent to clean.** No issue enters the pipeline without an explicit `clean` verdict.

## Quarantine Review

Human reviewers inspect quarantined issues and take one of two actions:

**False positive (issue is safe):**

- Issue is unlocked
- A fresh approval comment is posted
- Labels updated to restore the appropriate pipeline state (the *previous* pipeline state, not a reset to `state:discovery`)
- Issue re-enters the pipeline at the correct point

**True positive (issue is malicious):**

- A security event issue is created in the designated security repository
- The original issue is closed with a reference to the security event

## Deployment Context

- Rust service deployed on internal infrastructure
- Backed by a GitHub App (API client via `octocrab`)
- Receives events either via GitHub App webhook (using `github-bot-sdk`) or from a queue (using `queue-runtime`); both paths deliver normalised `IssueEvent`s to the same handlers
- All secrets stored in HashiCorp Vault
- Metrics emitted to VictoriaMetrics
- No GitHub Actions involvement
