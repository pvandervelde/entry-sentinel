# ADR-0008: Dual Event Intake — Webhook and Queue

Status: Accepted
Date: 2026-04-20
Owners: entry-sentinel

## Context

Entry Sentinel must receive GitHub issue events (`issues: opened`, `issues: edited`) to function. There are two viable transport mechanisms:

1. **GitHub App webhook** (`github-bot-sdk`): GitHub delivers events by making an HTTPS POST to a configured endpoint. Entry Sentinel validates the `X-Hub-Signature-256` HMAC-SHA256 header and processes the event in-process. This is the standard GitHub App pattern.

2. **Queue** (`queue-runtime`): A separate component receives the GitHub webhook and places the event on a queue. Entry Sentinel consumes from the queue. This pattern is common in multi-tenant or high-throughput deployments where a queue provides buffering, replay, and back-pressure.

Both patterns deliver the same logical events. The business logic (scanning, routing, approval, quarantine) is identical regardless of how the event arrived. Forcing a single intake path would either exclude valid deployment topologies or require separate service binaries.

## Decision

Entry Sentinel supports both intake paths via a common `EventSource` abstraction. Both paths normalise events to the same `IssueEvent` type before any business logic runs.

- The **webhook path** is implemented by `WebhookEventSource`, backed by `github-bot-sdk`. It handles HMAC-SHA256 validation, HTTP response acknowledgement (HTTP 200 to GitHub), and delivery ID extraction for idempotency.
- The **queue path** is implemented by `QueueEventSource`, backed by `queue-runtime`. It handles queue connection, message consumption, and queue-level authentication where supported.

The `EventNormaliser` receives raw events from either source and parses them into typed `IssueEvent`s before routing to `IssueOpenedHandler` or `IssueEditedHandler`.

Configuration determines which source(s) are active. Both can be active simultaneously (e.g., webhook as primary, queue as secondary for missed events), or only one may be enabled.

## Consequences

- **Enables**: Deployment in environments where a reverse proxy or gateway places events on a queue before delivery to Entry Sentinel; supports high-throughput deployments with buffering; supports environments where Entry Sentinel is not directly internet-accessible; both paths share the same business logic, detection, and approval machinery
- **Forbids**: Business logic that differentiates behaviour based on the event source; HMAC validation in business logic (it belongs only to `WebhookEventSource`); hard dependency on a running HTTP server when only the queue path is configured
- **Trade-offs accepted**: HMAC validation is only available on the webhook path. The queue path relies on the queue's own authentication and the assumption that only trusted components can write to the queue. This is an accepted trust delegation — the queue boundary is the security perimeter for the queue path.

## Alternatives considered

- **Webhook-only**: Simpler; GitHub App webhook is the canonical pattern. Rejected — excludes valid deployment topologies where a gateway or fan-out queue sits between GitHub and Entry Sentinel; forces direct internet exposure.
- **Queue-only**: Decouples Entry Sentinel from direct GitHub delivery. Rejected — requires additional infrastructure for simple deployments; GitHub delivers webhooks reliably for low-volume use cases; webhook-first is the path of least resistance.
- **Two separate binaries** (one per intake): Clean separation. Rejected — doubles operational surface; both binaries contain identical business logic; configuration and deployment coordination is more complex.
- **Plugin/extension model**: Runtime-loadable intake plugins. Rejected — adds significant architectural complexity for two well-defined, stable intake patterns.

## Implementation notes

The `EventSource` trait is defined in the business logic layer to keep the dependency rule intact. Infrastructure implementations (`WebhookEventSource`, `QueueEventSource`) depend on the trait, not the reverse.

Both implementations push `IssueEvent`s to a shared async channel (`tokio::sync::mpsc`). The `EventNormaliser` consumes from this channel and dispatches to the appropriate handler. This fan-in model means the `IssueOpenedHandler` and `IssueEditedHandler` are unaware of the source.

The delivery ID used by `DeliveryIdGuard` for webhook events is the `X-GitHub-Delivery` header value. For queue events, a stable delivery ID should be derived from the queue message ID or a field embedded in the event payload by the enqueuing component. If no stable ID is available, idempotency for the queue path is best-effort.

The `github-bot-sdk` crate handles the HTTP server lifecycle, HMAC validation, and acknowledgement. Entry Sentinel does not need to manage a raw HTTP server when using this path.

The `queue-runtime` crate provides the queue consumer lifecycle, reconnection, and message acknowledgement. Entry Sentinel does not need to manage queue protocol details when using this path.

## Configuration

```toml
[intake]
# At least one source must be enabled.

[intake.webhook]
enabled = true
# Webhook secret retrieved from Vault at the path configured in [vault]
bind_address = "0.0.0.0:8080"

[intake.queue]
enabled = false
# Queue connection details — exact schema defined by queue-runtime
connection_string_vault_path = "entry-sentinel/queue/connection-string"
queue_name = "github-issue-events"
```

## References

- [specs/responsibilities.md — Event Intake Layer](../specs/responsibilities.md)
- [specs/architecture.md — EventSource abstraction](../specs/architecture.md)
- [specs/security.md — T-02 Webhook Spoofing](../specs/security.md)
