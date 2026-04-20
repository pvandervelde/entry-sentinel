# ADR-0005: AI Second Pass is Opt-In and Disabled by Default

Status: Accepted
Date: 2026-04-15
Owners: entry-sentinel

## Context

An LLM second pass could improve detection coverage for novel prompt injection techniques that evade the deterministic signature library. However, integrating an LLM introduces meaningful risks:

1. **Attack surface**: The LLM itself can be targeted by prompt injection techniques embedded in issue content.
2. **Non-determinism**: LLM responses vary, making audit trails and reproducibility harder.
3. **External dependency**: A third-party AI provider introduces a latency, availability, and data-handling dependency.
4. **Data exposure**: Issue content is sent to an external service, which may retain or log it.
5. **Operational complexity**: API keys, rate limits, prompt management, and response parsing all require maintenance.

The deterministic pass is sufficient for known threat signatures. The question is whether the marginal detection benefit of the AI pass justifies the added cost and risk.

## Decision

The AI second pass is **disabled by default**. It must be explicitly enabled in the service configuration. When disabled, the service operates as deterministic-only with no code paths reaching the `AiProvider` abstraction.

When enabled, the AI pass:

- Only runs if the deterministic pass returned `Clean`
- Receives a constrained prompt instructing it to output only `clean` or `suspect`
- Has a configurable timeout; timeouts are treated as `suspect` (fail safe)
- Produces a response that is parsed to exactly one of two tokens; non-binary responses are treated as `suspect`
- Never causes issue content to be reproduced or included in any log, metric, or downstream message

## Consequences

- **Enables**: Operators can opt into AI-assisted detection when the threat environment justifies the cost and risk; the default configuration is simpler, faster, and more auditable; the AI provider can be any OpenAI-compatible API
- **Forbids**: Implicit enabling of the AI pass by configuration omission; using the AI response as anything other than a binary verdict; forwarding the AI response to any downstream system
- **Trade-offs accepted**: Novel prompt injection techniques that would be caught by an LLM but not by the deterministic library may slip through in the default (disabled) configuration. This risk is mitigated by the expectation that the signature library is regularly updated as new techniques are observed.

## Alternatives considered

- **AI always-on**: Consistent behaviour; no opt-in friction. Rejected — latency, cost, external dependency, and data exposure apply to every issue regardless of threat level. The deterministic pass alone handles the known threat landscape.
- **AI as the primary check with deterministic fallback**: AI runs first for broad coverage; deterministic catches what AI misses. Rejected — makes the AI the primary attack surface (see ADR-0001). The ordering cannot be reversed.
- **Never AI**: Purely deterministic. Valid but unnecessarily limiting for operators who have the capability and want it. Opt-in preserves this option.

## Implementation notes

The feature flag `ai_second_pass.enabled` in the service configuration controls this. When `false`, the `AiDetector` component is never instantiated and the `AiProvider` abstraction is never called.

The `IssueScanner` checks this flag after the deterministic pass completes. If disabled, it returns the deterministic `ScanResult` directly. If enabled and the deterministic result is `Clean`, it invokes `AiDetector`.

The `AiProvider` abstraction must be mockable for testing purposes. All tests must pass with the AI second pass disabled. Tests for the AI path must use a mock `AiProvider` — they must not require a real LLM API.

The constrained prompt template is a required configuration field when AI is enabled. It must include explicit instructions to output only `clean` or `suspect` and not to reproduce or reason over the issue content in the response.

## Examples

Minimal configurationwhen AI is disabled:

```toml
[ai_second_pass]
enabled = false
```

Configuration when AI is enabled:

```toml
[ai_second_pass]
enabled = true
provider_url = "https://api.openai.com/v1/chat/completions"
model = "gpt-4o"
timeout_ms = 5000
prompt_template_path = "/etc/entry-sentinel/ai-prompt.txt"
```

## References

- [ADR-0001 — Deterministic-First Detection](ADR-0001-deterministic-first-detection.md)
- [specs/security.md — T-01 Prompt Injection, T-06 LLM Exfiltration](../specs/security.md)
- [specs/requirements.md — R-10, R-12, R-13](../specs/requirements.md)
- [specs/assertions.md — A-04, A-08, A-09, A-16](../specs/assertions.md)
- [specs/assumptions.md — A-03](../specs/assumptions.md)
