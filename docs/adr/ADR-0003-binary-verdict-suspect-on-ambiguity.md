# ADR-0003: Binary Verdict with Suspect on Ambiguity

Status: Accepted
Date: 2026-04-15
Owners: entry-sentinel

## Context

Entry Sentinel must produce a verdict for every issue it processes. The verdict is the input to downstream routing logic: which labels to apply, whether to post an approval comment, whether to quarantine.

Possible verdict models:

- **Binary** (`clean` / `suspect`)
- **Scored** (e.g., a float in [0.0, 1.0])
- **Multi-class** (`clean` / `suspicious` / `malicious`)

The downstream services (Triage Titan, Scope-Sage, CogWorks) must each independently act on the verdict. Any ambiguity in the verdict model creates a cross-service coordination problem.

The primary failure mode to avoid is false negatives — a missed malicious issue is more damaging than a false positive requiring human review.

## Decision

Entry Sentinel produces exactly one of two verdicts: **`Clean`** or **`Suspect`**. There are no intermediate values, no confidence scores, and no multi-class variants in the verdict type itself.

**Ambiguity resolves to `Suspect`**: any case where the detection stack cannot confidently determine the issue is safe is classified as `Suspect`. When in doubt, quarantine.

## Consequences

- **Enables**: Each downstream service can implement a simple binary precondition check (approval comment present and valid = proceed; anything else = abort); no threshold negotiation between services; no risk of different services interpreting the same score differently
- **Forbids**: Emitting a confidence score or probability alongside the verdict; routing based on any state other than the binary verdict; allowing the AI pass to shift a `Suspect` verdict to `Clean`
- **Trade-offs accepted**: Some legitimate issues will be quarantined (false positives) that a scored system might route through at a lower threshold. The detection philosophy explicitly accepts a higher false positive rate in exchange for a lower false negative rate. Human review of the quarantine queue is the safety valve.

## Alternatives considered

- **Scored verdict (0.0–1.0)**: Allows threshold tuning per downstream service. Rejected — threshold becomes a shared contract across all services; changing it requires coordinated deployment; scores imply false precision (the detection stack cannot produce meaningful probabilities); downstream services would disagree on the threshold over time.
- **Multi-class (clean / suspicious / malicious)**: More routing options. Rejected — the middle class (`suspicious`) still requires a downstream policy decision; what does a downstream service do with a `suspicious` issue? The simplest safe answer is "treat it as suspect", which collapses back to binary.
- **Boolean with metadata**: A boolean verdict plus structured metadata (e.g., triggering signature). Accepted in part — the `ScanResult` type carries the triggering reason and detector name for audit purposes, but the downstream routing decision is always based on the binary `Verdict`, never on the metadata.

## Implementation notes

The `Verdict` enum must have exactly two variants in Rust:

```rust
#[non_exhaustive]
pub enum Verdict {
    Clean,
    Suspect,
}
```

The `#[non_exhaustive]` attribute prevents external code from exhaustively matching without a wildcard arm, which allows future internal variants to be added without a breaking API change — but public callers must always handle `Suspect` as the fallback.

The `ScanResult` type carries the triggering reason and detector for audit and observability purposes. It must not be used as the routing input — only `Verdict` is used for routing.

## References

- [specs/vocabulary.md — Verdict, ScanResult](../specs/vocabulary.md)
- [specs/requirements.md — R-01](../specs/requirements.md)
- [specs/assertions.md — A-09 (non-binary AI response → Suspect)](../specs/assertions.md)
