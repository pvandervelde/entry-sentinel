# ADR-0004: Conservative Failure Handling

Status: Accepted
Date: 2026-04-15
Owners: entry-sentinel

## Context

Entry Sentinel may fail to complete processing of a webhook event for a variety of reasons: Vault unavailability, GitHub API errors, network timeouts, panics, or bugs. The system must define a policy for each failure scenario.

The two event types have asymmetric consequences:

**New issue** (`issues: opened`): The issue has not been approved. A failure means it stays unapproved. The risk of a failed new-issue event is an unlabelled issue sitting in the repository — a recoverable human problem.

**Edit event** (`issues: edited`): The issue has already been approved. A failure during edit processing means the approval state may be stale — the current content may differ from the approved content with no action taken. This is a pipeline integrity risk: downstream services could act on an issue whose content has changed since approval.

## Decision

**New issue failures**: The issue remains unlabelled. No labels are applied. No approval comment is posted. An alert is raised. A watchdog monitors for unlabelled issues older than the configured threshold and surfaces them for human review.

**Edit event failures** (when hash has changed): The issue is conservatively quarantined. Entry Sentinel applies `process:admin` + `state:quarantine`, locks the issue, and notifies a human reviewer. The quarantine is based on the inability to verify the new content, not on a confirmed suspect verdict.

**Unlabelled is never equivalent to clean.** This invariant must hold at all times.

## Consequences

- **Enables**: Pipeline integrity is preserved even under partial failure; no issue can enter the pipeline without an explicit clean verdict; the failure mode for new issues is safe and visible; the watchdog provides a detection mechanism for missed events
- **Forbids**: Auto-approval of a new issue on processing failure; leaving an edited issue in an approved state when the edit could not be verified; treating unlabelled as safe
- **Trade-offs accepted**: A legitimate new issue may be delayed if Entry Sentinel is unavailable — the watchdog threshold controls the maximum delay. A legitimate edit may trigger a false-positive quarantine if Entry Sentinel fails mid-processing — reviewers must handle this as a routine operational event.

## Alternatives considered

**For new issues:**

- **Auto-approve on failure**: No delay; simplest. Rejected — approves content that was never scanned. This is an unacceptable security regression.
- **Auto-quarantine on failure**: Consistent with edit policy; safe. Rejected — quarantine for a new issue that was never even scanned is unnecessarily noise-generating; the issue earned neither a clean nor a suspect verdict.
- **Unlabelled (chosen)**: Safe; visible; human-reviewable; consistent with the watchdog model.

**For edit events:**

- **Leave untouched (fail-open)**: Simplest. Rejected — leaves potentially modified content in an approved state; downstream services may act on content that should have been re-verified.
- **Silently retry indefinitely**: Defers the problem; adds complexity; still needs a fallback after exhausting retries.
- **Conservative quarantine (chosen)**: Treats unverifiable edits as suspect. Consistent with the detection philosophy: when in doubt, quarantine. False-positive quarantines from failures are recoverable; missed malicious edits are not.

## Implementation notes

The failure handling boundaries:

For a new issue: any error that occurs after the webhook is received but before the approval comment is successfully posted results in the issue remaining unlabelled. If the approval comment was posted but label application failed, the watchdog will detect the missing `state:*` label and alert. A partial clean state (comment without labels) is an anomaly requiring human triage.

For an edit event: if the hash comparison detects a change and any subsequent step fails (re-scan, signing, label change, content reversion), the default action is to attempt quarantine. If quarantine itself fails (e.g., GitHub API is down), the failure is recorded and alerted. The issue may be left in an inconsistent state — this is flagged for immediate human review.

All failures, including partial failures, must be recorded in the audit log with the issue ID, event type, and the specific operation that failed.

## References

- [specs/edge-cases.md — EC-06 (Vault unavailable), EC-17 (Processing failure on edit)](../specs/edge-cases.md)
- [specs/requirements.md — R-15, R-16, R-17](../specs/requirements.md)
- [specs/operations.md — Watchdog for Unlabelled Issues](../specs/operations.md)
- [specs/assertions.md — A-10, A-17](../specs/assertions.md)
