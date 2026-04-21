# Operations — Entry Sentinel

Deployment model, secrets management, detection signature updates, monitoring, and runbooks.

---

## Deployment

### Service Topology

Entry Sentinel is a single Rust binary deployed as a long-running process on internal infrastructure. It exposes one inbound HTTP endpoint (the webhook receiver, when the webhook intake path is configured). It makes outbound calls to:

- GitHub API (via `octocrab`)
- HashiCorp Vault (for secret retrieval and signing)
- The configured AI provider (when AI second pass is enabled)
- VictoriaMetrics (metric push)
- Alert target (Slack, PagerDuty, or similar)

There is no database, no message queue, and no persistent local state beyond the in-memory delivery ID deduplication window.

### Startup Sequence

1. Load configuration from the config file path passed as a CLI argument
2. Connect to Vault using the configured AppRole credentials
3. Retrieve the GitHub webhook secret from Vault
4. Retrieve the GitHub App private key from Vault (for API authentication)
5. Load and parse the detection signature library from the configured path/URL
6. If AI second pass is enabled: validate the `AiPrompt` template structure (placeholder present, binary-verdict instruction present, content delimiters correct) — see C-54
7. Publish / verify the Ed25519 public key is present in the service registry
8. Start the Vault token renewal background task — see C-53
9. Bind the HTTP server to the configured address and port
10. Begin accepting webhook events

**Any failure in steps 1–9 is a hard startup failure.** The process exits with a non-zero status code and a structured error message. It does not start accepting traffic in a degraded state.

### Health and Readiness

- `/health` — returns HTTP 200 if the process is running; no dependency checks
- `/ready` — returns HTTP 200 only if all startup checks passed (Vault reachable, signature library loaded, app credentials valid, AI prompt template valid if AI enabled, Vault token renewal task running)

Kubernetes (or equivalent) should use `/ready` for the readiness probe and `/health` for the liveness probe.

---

## Secrets Management

All secrets are stored in HashiCorp Vault. No secret appears in environment variables, config files, process arguments, or any artifact.

| Secret | Vault Path | Used By |
|---|---|---|
| Ed25519 private key | `entry-sentinel/signing/ed25519` | `ApprovalSigner` |
| GitHub App private key | `entry-sentinel/github/app-private-key` | GitHub API auth |
| GitHub webhook secret | `entry-sentinel/github/webhook-secret` | `WebhookReceiver` |
| AI provider API key | `entry-sentinel/ai/api-key` | `AiProvider` (when enabled) |

### Vault Access Policy

Entry Sentinel's Vault AppRole policy must grant:

- `read` on its own secret paths (listed above)
- `create` on `entry-sentinel/signing/ed25519` (if using Vault transit for signing — preferred; see below)

Entry Sentinel must not have `list` access to any path outside its own namespace. It must not have `write` access to any secret except the signing operation.

### Vault Transit Engine (Preferred)

The preferred signing configuration is the **Vault transit engine** for Ed25519. With transit, Vault performs the signing operation internally and returns only the signature — the raw private key bytes never leave Vault's address space. `VaultClient::sign()` wraps the transit sign endpoint in this configuration.

If the Vault KV (raw key bytes) pattern is used instead, C-16 still applies with additional strictness: the key bytes must be zeroed from memory immediately after use, not merely dropped.

### Vault Token Lifecycle

Entry Sentinel authenticates to Vault at startup using AppRole and receives a Vault token with a TTL. To prevent the token from expiring during a long-running deployment:

1. The Vault token must have a minimum TTL of 24 hours and a renewable lease.
2. A background task must call the `renew_self` endpoint proactively when the remaining TTL falls below half the original `max_lease_ttl`.
3. If three consecutive renewal attempts fail, an alert must be raised while the token is still valid (before expiry). This gives operators time to restart or re-authenticate before the service becomes unable to sign.
4. Vault token expiry mid-operation is treated as `vault-unavailable` (see EC-06). Token expiry should be caught by the renewal background task before it causes a service disruption.

**Runbook: Vault token expiry** — if `entry_sentinel_vault_errors_total` increments with `status=403`, check whether the Vault token has expired. Restart Entry Sentinel to re-authenticate via AppRole.

### Secret Rotation Procedure

**Webhook secret rotation**:

1. Update the secret in Vault
2. Update the corresponding secret on the GitHub App webhook configuration
3. Restart Entry Sentinel (or trigger a config reload if supported)
4. Verify webhook events are being processed correctly

**Ed25519 key rotation** (with `key_id` transition window):

1. Generate a new Ed25519 key pair in Vault; assign it a new `key_id` (e.g., `es-<date>`)
2. Publish the new public key + `key_id` to the service registry with `effective_from: now` and no `retired_until`
3. Update `entry-sentinel/signing/ed25519` in Vault to the new key and `entry-sentinel/signing/key_id` to the new `key_id`
4. Restart Entry Sentinel — it begins signing all new approvals with the new key and `key_id`
5. Update the old `key_id` entry in the service registry: set `retired_until: now + transition_window` (default: 90 days)
6. No immediate re-approval is required — existing approvals signed with the old `key_id` remain verifiable as long as the old key is in the registry
7. After the transition window lapses: remove the old key from the registry; any issues with approvals signed by the old key must be re-approved before downstream services will accept them
8. Monitor `entry_sentinel_vault_errors_total` for 30 minutes post-rotation

**GitHub App key rotation**: Follow GitHub's documented App private key rotation procedure. Entry Sentinel requires a restart after rotation to pick up the new key from Vault.

---

## Detection Signature Updates

Detection signatures are stored as versioned configuration, not compiled into the binary. The update procedure does not require a code deployment.

### Signature Config Format

The signature library is a structured file (TOML or JSON) loaded at startup. Example structure:

```toml
version = "2026-04-15-001"

[[signatures]]
id = "pi-ignore-previous"
category = "prompt_injection"
description = "Matches 'ignore all previous instructions' variants"
pattern = "(?i)ignore\\s+(all\\s+)?previous\\s+instructions"

[[signatures]]
id = "struct-oversized"
category = "structural"
description = "Content exceeds maximum safe length"
type = "length_limit"
max_bytes = 65536
```

### Signature Update Procedure

1. Draft new or updated signature in a pull request in the signature repository
2. Review by at least one security engineer
3. Run the signature test suite against the proposed signatures (no false positives on the known-clean corpus; detects on the known-suspect corpus)
4. Tag the new version string
5. Deploy the new signature file to the configured location (e.g., internal object storage or file distribution system)
6. Trigger a config reload in Entry Sentinel (SIGHUP or rolling restart)
7. Verify the new version string appears in subsequent audit log entries

---

## Monitoring and Alerting

### Metrics (VictoriaMetrics)

All metrics use the `entry_sentinel_` prefix and include at minimum these labels: `event_type` (`opened` | `edited`), `verdict` (`clean` | `suspect` | `error` | `no_change`).

| Metric | Type | Description |
|---|---|---|
| `entry_sentinel_webhooks_received_total` | Counter | Total webhook events received (all types) |
| `entry_sentinel_webhooks_processed_total` | Counter | Events processed (labelled by event_type, verdict) |
| `entry_sentinel_webhooks_duplicate_total` | Counter | Events discarded as duplicate delivery |
| `entry_sentinel_webhook_body_too_large_total` | Counter | Webhook requests rejected for exceeding the body size limit |
| `entry_sentinel_scan_duration_seconds` | Histogram | Time from scan start to verdict |
| `entry_sentinel_github_api_duration_seconds` | Histogram | GitHub API call latency (labelled by operation) |
| `entry_sentinel_github_api_errors_total` | Counter | GitHub API errors (labelled by status code) |
| `entry_sentinel_vault_signing_duration_seconds` | Histogram | Vault signing round-trip latency |
| `entry_sentinel_vault_errors_total` | Counter | Vault errors (labelled by operation) |
| `entry_sentinel_vault_token_renewal_total` | Counter | Vault token renewal attempts (labelled by outcome: success / failure) |
| `entry_sentinel_ai_query_duration_seconds` | Histogram | AI provider query latency |
| `entry_sentinel_ai_errors_total` | Counter | AI provider errors (labelled by error type and circuit_state: closed / open / half-open) |
| `entry_sentinel_ai_circuit_state` | Gauge | AI provider circuit breaker state (0=closed, 1=open, 2=half-open) |
| `entry_sentinel_detection_signature_version` | Gauge | Currently loaded signature library version (as label) |
| `entry_sentinel_quarantine_total` | Counter | Issues quarantined (labelled by reason) |
| `entry_sentinel_in_flight_events` | Gauge | Currently processing webhook events |

### Alert Rules

| Alert | Condition | Severity |
|---|---|---|
| `EntrySentinelDown` | `entry_sentinel_webhooks_received_total` not increasing for 5 minutes AND GitHub has delivered events | Critical |
| `EntrySentinelHighErrorRate` | >10% of events result in `error` verdict in 5-minute window | Warning |
| `EntrySentinelVaultErrors` | Any `entry_sentinel_vault_errors_total` increment | Warning |
| `EntrySentinelVaultTokenRenewalFailing` | Three consecutive `entry_sentinel_vault_token_renewal_total{outcome="failure"}` increments | Critical |
| `EntrySentinelGitHubRateLimit` | `entry_sentinel_github_api_errors_total{status="429"}` > 5 in 1 minute | Warning |
| `EntrySentinelScanSlow` | p95 `entry_sentinel_scan_duration_seconds` > 1.5s | Warning |
| `EntrySentinelWebhookBodyTooLarge` | `entry_sentinel_webhook_body_too_large_total` > 10 in 1 minute | Warning |
| `EntrySentinelAiCircuitOpen` | `entry_sentinel_ai_circuit_state` == 1 for > 5 minutes | Warning |
| `AuditLogForwardingGap` | No new records forwarded to the remote aggregation system for > forwarding window duration | Warning |

### Watchdog for Unlabelled Issues

A separate watchdog process (or cron job) queries the GitHub API for issues in the target repositories that:

- Have no `process:*` label
- Are older than the configured `WatchdogThreshold` (default: 15 minutes)

Any such issue is reported to the alert channel. This provides a safety net for events that were missed, dropped, or failed to process.

---

## Audit Log Durability

Entry Sentinel's `StructuredFileAuditLog` writes to a local file. The file alone does not satisfy R-23's tamper-resistance intent. The following operational controls are required:

1. **O_APPEND mode**: the audit log file must be opened in `O_APPEND` mode. Any implementation that opens the file with a writable seek position must be rejected in code review.
2. **OS-level append-only ACL**: where the operating system supports it (e.g., `chattr +a` on Linux), set the append-only attribute on the audit log directory. This prevents truncation even by the Entry Sentinel process itself.
3. **Log forwarding**: audit log entries must be forwarded to a remote log aggregation system (e.g., Loki, OpenSearch, or equivalent) within a configurable retention window (default: 5 minutes). The remote system is the authoritative audit record. See R-37.
4. **Log rotation**: log rotation must use copy-then-truncate or equivalent strategies that preserve the full rotated file. Rotated files must not be deleted until after successful forwarding to the remote aggregation system is confirmed.
5. **Alert on forwarding gap**: if the forwarding agent has not shipped new records for more than the configured forwarding window, a `AuditLogForwardingGap` alert must fire.

---

## Service Topology and Transport Security

Entry Sentinel must be deployed behind a reverse proxy (nginx, Caddy, or equivalent) that provides:

1. **TLS termination** — the webhook endpoint must be exposed over HTTPS only; plain HTTP must be rejected or redirected. The reverse proxy must be configured with TLS 1.2 as the minimum acceptable protocol version.
2. **Request body size enforcement** — the reverse proxy must enforce a maximum inbound body size of 1 MB (matching the HTTP server's own limit in C-52) so that over-size payloads are rejected before reaching the Entry Sentinel process.
3. **Per-source connection rate limiting** — the reverse proxy must limit the number of concurrent connections and request rate from any single source IP. The specific limits must be documented in the deployment runbook and reviewed after any sustained `EntrySentinelDown` or `EntrySentinelHighErrorRate` alert.

All outbound connections (Vault, GitHub API, AI provider, VictoriaMetrics, alert targets) must use TLS with full certificate chain validation. Certificate validation bypass flags must not be used (see C-50).

---

## Public Key Publication

Entry Sentinel's Ed25519 public key must be published in the service registry before the service begins processing issues. The registry entry must include:

- Service name: `entry-sentinel`
- Key type: `ed25519`
- `key_id`: a stable, unique identifier for this key pair
- Public key: base64-encoded 32 bytes
- `effective_from`: ISO 8601 date this key became active
- `retired_until`: ISO 8601 date after which this key is no longer trusted (null until rotation sets it)

Downstream services use the `key_id` from the approval comment to look up the corresponding public key in the registry. A key past its `retired_until` date is rejected without verification.

### Service Registry Security

The service registry is a security-critical component — a registry write that substitutes a false public key enables an attacker to forge valid approval signatures accepted by all downstream services (see T-13).

**Access controls:**

- Write access must be restricted to Entry Sentinel's deployment automation (CI/CD pipeline service account) and a small set of designated operators.
- The Vault access policy for the registry path must be reviewed and reconfirmed as part of every Ed25519 key rotation.
- No other service (GitHub App, downstream pipeline services) may have write access to the registry path.

**Storing the registry in Vault:**

The recommended implementation is a Vault KV store at `entry-sentinel/registry/<key_id>`. Vault policies enforce the write restriction, and Vault audit logs capture all write attempts. An alert rule must fire on any write to a `registry/` path by a principal other than the approved deployment service account.

**Periodic verification:**

As a scheduled runbook step (minimum: weekly), verify that the public key in the registry matches the public key derived from the private key in Vault. If they differ, raise an immediate security incident.

---

## Runbooks

### Runbook: Processing Outage

**Symptoms**: `EntrySentinelDown` fires; issues accumulating without labels.

1. Check the service health endpoint: `curl https://entry-sentinel.internal/ready`
2. If 503: check startup logs for Vault connectivity or signature library load errors
3. If 200 (healthy but not processing): check the GitHub App webhook delivery log for failures or timeouts
4. If the service is crashed: check the process supervisor logs; restart the service
5. After service recovery, verify events are being processed by watching `entry_sentinel_webhooks_processed_total`
6. Check for unlabelled issues older than the watchdog threshold and manually triage if needed

---

### Runbook: High False Positive Rate

**Symptoms**: Quarantine queue growing; reviewers reporting legitimate issues being quarantined.

1. Check the audit log for the triggering signature IDs on recent false positives
2. Identify the detection signature responsible
3. If the signature is too broad: update the signature configuration (see Detection Signature Updates procedure above)
4. Clear the false positive queue by following the false positive resolution process in [overview.md](overview.md)
5. If the false positive rate is >5% of processed issues, consider temporarily disabling the offending signature while a better version is prepared

---

### Runbook: Ed25519 Key Rotation

1. Follow the Secret Rotation Procedure above for Ed25519 key rotation
2. Verify downstream services are picking up the new public key from the service registry
3. Monitor `entry_sentinel_vault_errors_total` for a 30-minute window post-rotation to confirm no signing failures
4. Confirm audit log entries show the new `key_id` appearing in fresh approval comments
5. After the transition window lapses (default: 90 days), remove the old key from the registry; issues approved with the old key must be re-approved before downstream services will accept them

---

### Runbook: Verify Service Registry Integrity

1. Retrieve the active `key_id` from `entry-sentinel/signing/key_id` in Vault
2. Parse the public key from the private key at `entry-sentinel/signing/ed25519` in Vault (or from the transit key export if using Vault transit)
3. Retrieve the registry entry for that `key_id` from `entry-sentinel/registry/<key_id>`
4. Compare the public key bytes byte-for-byte
5. If they differ: raise an immediate security incident; pause all downstream pipeline processing until the registry is restored
