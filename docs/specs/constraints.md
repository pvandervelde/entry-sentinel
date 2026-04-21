# Implementation Constraints — Entry Sentinel

Hard rules that must be enforced during implementation. Violations are blocking — they prevent merge. These constraints are derived from `.tech-decisions.yml` plus domain-specific security and correctness requirements.

---

## Type System

**C-01** `IssueId` must be a newtype/branded wrapper over GitHub's numeric issue ID. It must never be treated as a plain integer in domain code.

**C-02** `ContentHash` must be a newtype wrapping a 32-byte array. It must never be a plain `String` or `Vec<u8>` in domain code. Its `Display` implementation produces the `sha256:<hex>` serialised form.

**C-03** `ApprovalSignature` must be a newtype wrapping a 64-byte array. It must never be a plain `Vec<u8>` or `String` in domain code.

**C-04** `Verdict` must be a non-exhaustive enum with exactly two variants: `Clean` and `Suspect`. It must not be represented as a string, integer, or boolean in domain logic.

**C-05** `ApprovalTimestamp` must be a newtype over a UTC `DateTime`. It must not be a plain string. Serialisation to ISO 8601 happens only at comment-building time.

**C-06** All domain operations must return `Result<T, E>` or `impl Future<Output = Result<T, E>>`. No domain function may panic on expected error conditions.

**C-07** Error types for library crates must use `thiserror`. Error types for the binary entry point may use `anyhow` for propagation convenience but must not paper over domain error variants.

---

## Module Boundaries

**C-08** Business logic crates must not depend on `octocrab`, any HTTP client, or any Vault SDK. They may only depend on the abstract traits defined in the external system interface layer.

**C-09** Infrastructure implementations must be instantiated and wired together only in `main.rs`. No business logic module may construct a concrete infrastructure type.

**C-10** Detection logic must not import GitHub API response types. Issue content is extracted from webhook payloads into internal types before being passed to the scanner.

**C-11** Approval signing logic must not import detection types. The signing module receives only an `ApprovalPayload` and returns an `ApprovalSignature`.

---

## Error Handling

**C-12** All `Result` values must be explicitly handled. `let _ = result` is forbidden. Unused results must be either propagated or deliberately discarded with a justified comment.

**C-13** `unwrap()` and `expect()` are forbidden in library code. They are permitted only in `main.rs` and in tests.

**C-14** Error variants must carry sufficient context to identify at minimum: the issue ID, the event type (opened/edited), and the failing operation. Errors that propagate past a module boundary must include this context.

**C-15** Vault errors must not include key material in their `Display` or `Debug` representations. Key-related error messages must be generic (e.g., "signing failed" rather than including key bytes or Vault responses).

---

## Secret Handling

**C-16** The Ed25519 private key must never be stored in a struct field that lives longer than a single signing operation. Retrieve → sign → drop, within a single async task.

**C-17** The GitHub webhook secret must never be logged at any tracing level.

**C-18** GitHub App private key bytes must never be logged at any tracing level.

**C-19** Vault tokens must never be logged at any tracing level.

**C-20** No secret value may appear in a metric label, a trace attribute, or an audit event.

---

## Logging and Observability

**C-21** All log statements must use `tracing` macros (`trace!`, `debug!`, `info!`, `warn!`, `error!`). `println!` and `eprintln!` are forbidden in library crates.

**C-22** Issue title, body, and any fragment thereof must never appear in log output at any level. Logs may record issue IDs, label names, verdict outcomes, and detection signature IDs.

**C-23** Every structured log event that crosses a module boundary must include `issue_id` and `event_type` as structured fields.

**C-24** Every external system call (GitHub API, Vault, AI provider) must be wrapped in a `tracing::instrument` span.

---

## Code Size

**C-25** No function may exceed 50 lines (excluding doc comments and blank lines). Functions approaching this limit must be decomposed.

**C-26** No source file may exceed 500 lines. Files approaching this limit must be split.

**C-27** Cyclomatic complexity must not exceed 10 per function. Functions exceeding this must be decomposed.

---

## Performance

**C-28** Deterministic detection must complete in under 100 ms for any issue content up to 65 536 bytes.

**C-29** The full approval sequence (hash + sign + post comment + apply labels) must complete in under 2 000 ms at the 95th percentile.

**C-30** The Vault signing round-trip must complete in under 500 ms at the 95th percentile. If it does not, the signing call is considered failed and the clean path is aborted.

---

## Testing

**C-31** Business logic coverage target: 100% line coverage.

**C-32** Integration test coverage target: 90% of integration paths (GitHub API interactions, Vault signing round-trip, AI provider query).

**C-33** Infrastructure coverage target: 80% line coverage.

**C-34** Mutation test minimum score: 70% per module across verdict routing and content integrity modules. The detection module (`DeterministicDetector` and `IssueScanner`) has a **minimum of 90%** — a surviving mutant in the detection module means a code path exists that can silently classify suspect content as clean, which is a security defect. See `testing.md` for the full mutation test specification per module.

**C-35** Test function names must follow the pattern `test_{function}_{scenario}_{expected}`.

**C-36** Property-based tests (using `proptest`) are required for:

- `ContentHasher`: determinism and sensitivity to any input change
- `ApprovalCommentParser`: all well-formed inputs parse; all malformed inputs return `ParseError`
- `DeterministicDetector`: structural invariants (no signature matches the empty string; no signature matches pure ASCII whitespace) and the adversarial evasion invariants defined in `testing.md` §Property Tests — DeterministicDetector adversarial evasion invariants

See `testing.md` for the full property test specification for each module. `testing.md` is authoritative where it expands on the requirements listed here.

---

## Dependency Policy

**C-37** The dependency set must be minimal. Every new crate added must be justified in the pull request description.

**C-38** `cargo audit` must pass at `high` severity or above with no exceptions at CI time.

**C-39** The following crates are approved for use without per-PR justification: `tokio`, `axum` (or similar webhook HTTP server), `octocrab`, `reqwest`, `serde`, `serde_json`, `sha2`, `ed25519-dalek`, `base64`, `thiserror`, `anyhow`, `tracing`, `tracing-subscriber`, `opentelemetry`, `proptest`, `regex`.

---

## Transport Security

**C-49** All inbound connections to Entry Sentinel must use TLS 1.2 or later. The HTTP server must be configured with TLS termination (either directly or via a reverse proxy). Plain HTTP is not acceptable for the webhook endpoint in any environment.

**C-50** All outbound connections — to Vault, the GitHub API, AI providers, metrics sinks, and alert targets — must use TLS with certificate validation enabled. `danger_accept_invalid_certs`, `rustls::ClientConfig` with an empty verifier, or any equivalent certificate-validation bypass must never appear in production code or configuration.

---

## Intake Authentication

**C-51** Queue-level authentication is mandatory when the queue intake path is active. The `QueueReceiver` must refuse to start if authentication credentials are absent or invalid. An absence of authentication credentials is a hard startup failure. `where supported` is not an acceptable qualifier — the `queue-runtime` crate must be chosen and configured to guarantee message-level authentication.

---

## Request Limits

**C-52** The HTTP server must enforce a maximum inbound request body size of 1 MB (1 048 576 bytes). This matches GitHub's documented maximum webhook payload size. Requests exceeding this limit must be rejected with HTTP 413 before the body is fully read into memory. The limit applies before HMAC validation; it is not a bypass of HMAC.

---

## Vault Lifecycle

**C-53** Entry Sentinel must maintain a valid Vault token for the lifetime of the process. A background task must proactively renew the Vault token using the `renew_self` endpoint before expiry. The renewal attempt must be made when the remaining TTL falls below half the original `max_lease_ttl`. If three consecutive renewal attempts fail, an alert must be raised while the token is still valid. Vault token expiry mid-operation is covered by the `vault-unavailable` handling in EC-06; token expiry must not require a process restart as the only recovery path.

---

## AI Prompt Safety

**C-54** If the AI second pass is enabled, the configured `AiPrompt` template must be validated at startup before the service begins accepting events. Validation must confirm: (a) the template contains the issue content placeholder exactly once, (b) the binary-verdict instruction is present verbatim, and (c) the issue content placeholder is structurally isolated from the instruction text by explicit delimiters. A template that fails validation is a hard startup failure.

---

## ApprovalPayload Key Ordering

**C-55** `ApprovalPayload` must be assembled using the `KeyId` returned by `VaultClient::sign()`, not by a prior separate call to `VaultClient::key_id()`. The signing call is the authoritative source of the `KeyId`. Calling `key_id()` before `sign()` to pre-build the payload introduces a TOCTOU race during key rotation and must not be done.

---

## Naming

**C-40** Functions: `snake_case`
**C-41** Variables: `snake_case`
**C-42** Types (structs, enums, type aliases): `PascalCase`
**C-43** Constants: `SCREAMING_SNAKE_CASE`
**C-44** Modules: `snake_case`
**C-45** Test functions: `test_{function}_{scenario}_{expected}`

---

## Documentation

**C-46** All `pub` types and functions must have `///` doc comments.

**C-47** Non-trivial public functions must include at least one doc test or a `# Examples` section in their doc comment.

**C-48** ADRs must be created for: architectural decisions, technology choices, security model changes. See `docs/adr/ADR_TEMPLATE.md` for format.
