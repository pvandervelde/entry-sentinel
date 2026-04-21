# ADR-0006: Detection Signatures Are Versioned External Configuration

Status: Accepted
Date: 2026-04-15
Owners: entry-sentinel

## Context

Prompt injection techniques evolve continuously. New patterns are identified in the wild, existing patterns are refined, and false-positive-inducing patterns must be corrected. If detection signatures are hardcoded in the service binary, every signature change requires a code change, review, build, and deployment — a cycle of 30–60 minutes or more.

The detection signature library is the primary mechanism for keeping Entry Sentinel current with emerging threats. Slow updates mean a longer window during which novel techniques go undetected.

In addition, the version of signatures used for a given scan must be recorded in the audit log to enable post-hoc analysis (e.g., "this issue was scanned with version 2026-04-10-003; the pattern that would have caught it was added in version 2026-04-12-001").

## Decision

Detection signatures are maintained as **versioned, structured external configuration** (TOML or JSON). The signature file is loaded at startup and is not compiled into the binary.

The signature library has a version string. The version string of the library in use at the time of any scan is recorded in the `AuditEvent`.

Signature updates do not require a code deployment. A configuration reload (via SIGHUP or rolling restart) picks up a new signature file.

## Consequences

- **Enables**: Signature updates in minutes rather than hours; independent versioning of signatures and service code; audit trail records exactly which signatures were active for each scan; signature development can be done by security engineers without touching Rust code
- **Forbids**: Hardcoding any detection rule in the Rust source; using a signature set that has not been assigned a version string; deploying a signature update by editing source code
- **Trade-offs accepted**: The signature config file is a startup dependency — if it cannot be loaded, the service refuses to start (see EC-20 in edge-cases.md). A config distribution and versioning pipeline must be maintained as operational infrastructure. The signature file schema must be stable or versioned to avoid parse failures on format changes.

## Alternatives considered

- **Hardcoded in source**: Simple; version-controlled with code; always present. Rejected — forces redeployment for every signature update; security response latency is unacceptable for an actively evolving threat landscape.
- **Database-backed**: Signatures stored in a database; dynamically updatable without restart. Rejected — adds a persistent-store infrastructure dependency; introduces runtime schema management; the startup-loaded model is simpler and safer (no mid-run signature changes that affect in-flight scans).
- **Code-generated from external source**: Signatures defined in a DSL, compiled to Rust code at build time. Rejected — combines the worst properties of both: still requires a rebuild for updates, and adds a code generation pipeline.
- **Hybrid (common signatures hardcoded + external overrides)**: Simpler operational story for the baseline. Rejected — creates two places where signatures live and a merge policy that must be understood and maintained; any hardcoded signature is still a deployment for updates.

## Implementation notes

The signature library is loaded once at startup by the `DeterministicDetector` initialisation path. It is not reloaded mid-run (to ensure that all scans during a given process lifetime use a consistent library version). A rolling restart is the mechanism for picking up new signatures in a running deployment.

The signature file schema must include:

- A `version` field (string) at the top level
- A list of signatures, each with: `id`, `category`, `description`, and the matching rule (`pattern`, `type`, or `max_bytes` as appropriate)

The `DeterministicDetector` must validate the schema at load time and refuse to start if any signature entry is malformed.

The signature library version must appear as a structured field (`signature_library_version`) in every `AuditEvent`, not just in log output.

## Examples

Signature file fragment (TOML):

```toml
version = "2026-04-15-001"

[[signatures]]
id = "pi-ignore-previous"
category = "prompt_injection"
description = "Matches 'ignore all previous instructions' variants"
pattern = "(?i)ignore\\s+(all\\s+)?previous\\s+instructions"

[[signatures]]
id = "pi-system-prompt"
category = "prompt_injection"
description = "Matches attempts to invoke a new system prompt"
pattern = "(?i)(system\\s+prompt|new\\s+instructions?)\\s*:"

[[signatures]]
id = "struct-oversized"
category = "structural"
description = "Content exceeds maximum safe length"
type = "length_limit"
max_bytes = 65536

[[signatures]]
id = "url-base64-encoded"
category = "url"
description = "Detects base64-encoded URLs (potential obfuscation)"
pattern = "(?i)https?://[a-zA-Z0-9+/]{20,}={0,2}"
```

## References

- [specs/vocabulary.md — DetectionSignature, DetectionSignatureLibrary](../specs/vocabulary.md)
- [specs/requirements.md — R-11](../specs/requirements.md)
- [specs/edge-cases.md — EC-20 (Signature library fails to load)](../specs/edge-cases.md)
- [specs/operations.md — Detection Signature Updates](../specs/operations.md)
- [specs/assumptions.md — A-01](../specs/assumptions.md)
