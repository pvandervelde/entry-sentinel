# Entry Sentinel — Specification Index

This folder contains the architectural specification for Entry Sentinel. Each document addresses a specific concern and can be read independently. Together they form the complete design contract for the system.

## Document Index

| Document | Purpose |
|---|---|
| [overview.md](overview.md) | System context, role in pipeline, high-level flow |
| [vocabulary.md](vocabulary.md) | Domain concepts and their precise definitions |
| [responsibilities.md](responsibilities.md) | Component responsibilities and collaborations (RDD-style) |
| [architecture.md](architecture.md) | Clean architecture boundaries: business logic, interfaces, infrastructure |
| [assertions.md](assertions.md) | Testable behavioural assertions (Given/When/Then) |
| [requirements.md](requirements.md) | Non-negotiable properties — what must always be true |
| [constraints.md](constraints.md) | Implementation rules and tripwires |
| [security.md](security.md) | Threat model and mitigations |
| [edge-cases.md](edge-cases.md) | Non-standard flows and failure modes |
| [testing.md](testing.md) | Testing strategy and coverage targets |
| [tradeoffs.md](tradeoffs.md) | Architectural alternatives and trade-off decisions |
| [operations.md](operations.md) | Deployment, monitoring, key management, and runbooks |
| [assumptions.md](assumptions.md) | Challenged assumptions and their resolutions |

## Workflow Context

This specification is the output of the **Software Architect** phase and feeds directly into the **Interface Designer** phase.

```
Software Architect (this spec)
    ↓ produces docs/specs/
Interface Designer
    ↓ produces docs/specs/interfaces/ + typed stubs
Task Planner
    ↓ produces implementation task list
Coder
    ↓ implements against interfaces
Verifier / Security Reviewer
    ↓ validates implementation against assertions and requirements
```

## Key Architectural Decisions

Full ADRs are in [docs/adr/](../adr/). Summary:

| ADR | Decision |
|---|---|
| [ADR-0001](../adr/ADR-0001-deterministic-first-detection.md) | Pattern matching runs before AI — predictability and non-manipulability over flexibility |
| [ADR-0002](../adr/ADR-0002-ed25519-approval-signing.md) | Ed25519 for approval signing — compact, constant-time, decentralised trust; key_id enables rotation transition window |
| [ADR-0003](../adr/ADR-0003-binary-verdict-suspect-on-ambiguity.md) | Binary verdict only, suspect on ambiguity — no scores, no partial states |
| [ADR-0004](../adr/ADR-0004-conservative-failure-handling.md) | Conservative failure handling — unlabelled ≠ clean; edit failures → quarantine |
| [ADR-0005](../adr/ADR-0005-ai-second-pass-opt-in.md) | AI second pass is opt-in and disabled by default |
| [ADR-0006](../adr/ADR-0006-versioned-external-detection-signatures.md) | Detection signatures are versioned external configuration, not hardcoded logic |
| [ADR-0007](../adr/ADR-0007-hexagonal-architecture.md) | Hexagonal architecture for credential provider abstraction |
| [ADR-0008](../adr/ADR-0008-dual-intake-webhook-and-queue.md) | Dual event intake: GitHub webhook (github-bot-sdk) and queue (queue-runtime) |
