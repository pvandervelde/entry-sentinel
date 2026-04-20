# ADR-0001: Deterministic Detection Runs Before AI

Status: Accepted
Date: 2026-04-15
Owners: entry-sentinel

## Context

Entry Sentinel must classify issue content as `clean` or `suspect`. Two detection mechanisms are available: deterministic pattern matching (regex, structural heuristics) and an LLM-based second pass.

The primary threat is prompt injection — an attacker crafting issue content to manipulate automated systems into treating malicious input as benign. An LLM is itself a potential target for prompt injection: if the LLM is the first thing that processes attacker-controlled content, the attacker can optimise their payload specifically against the LLM's response.

## Decision

Deterministic checks always run first. The AI second pass is invoked only when:

1. AI is explicitly enabled in configuration, and
2. The deterministic result for that issue is `Clean`

A `Suspect` result from the deterministic pass is final — the AI pass is not invoked.

## Consequences

- **Enables**: Predictable, auditable verdicts with a traceable triggering reason; the deterministic pass cannot be manipulated by the content it evaluates; AI is never the first attack surface for prompt injection
- **Forbids**: Calling the AI provider on issues that the deterministic pass already classified as suspect; using the AI result to override a deterministic `Suspect` verdict
- **Trade-offs accepted**: Novel prompt injection techniques that evade the deterministic signature library but would have been caught by an AI-first approach may pass the deterministic pass and reach the AI. This is mitigated by the constrained AI prompt and the fail-safe treatment of non-binary AI responses.

## Alternatives considered

- **AI-first**: AI processes content first; deterministic checks only on AI-pass content. Rejected — the AI is the primary attack surface for prompt injection. Attackers can optimise their payload against the LLM.
- **AI-only**: No deterministic checks. Rejected — no auditability; non-deterministic; AI can be manipulated; false positive rate is unpredictable.
- **Deterministic-only**: No AI at all. Valid for most deployments; the AI second pass is opt-in precisely because deterministic-only is sufficient for known threat patterns.

## Implementation notes

The `IssueScanner` component orchestrates the ordering. The `DeterministicDetector` is called first and its result is checked before any call to `AiDetector`. This ordering must be enforced in the scan orchestration logic, not left to the caller.

The `DeterministicDetector` is a pure function — it receives content and a loaded signature library and returns a `ScanResult` with no I/O.

## References

- [specs/architecture.md — Detection](../specs/architecture.md)
- [specs/responsibilities.md — IssueScanner](../specs/responsibilities.md)
- [specs/security.md — T-01 Prompt Injection](../specs/security.md)
