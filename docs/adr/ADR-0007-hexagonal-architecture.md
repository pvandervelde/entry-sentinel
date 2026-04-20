# ADR-0007: Hexagonal Architecture for Credential Provider Abstraction

Status: Accepted
Date: 2026-01-24
Owners: credential-provider team

## Context

Services in the stack need credentials at runtime — queue broker connections, webhook secrets, API tokens, TLS certificates, and cloud provider identities. Each service may run in different environments (local development, self-hosted infrastructure with Vault, Azure, AWS), and must obtain credentials from whichever secrets backend is available without coupling service logic to a specific backend.

Previous approaches considered:

- A single monolithic crate with all backends compiled in — heavyweight for library consumers
- Per-backend crates with no shared abstraction — leads to API drift and duplicated caching logic
- Trait object in each consumer library — no reuse of caching, refresh, or error handling

## Decision

Use **Hexagonal Architecture** (Ports and Adapters pattern) to separate credential management business logic from backend implementations, split across two crates:

- **Hexagon (Core — `credential-provider-core`)**: Credential types, the `CredentialProvider<C>` trait (the port), `CachingCredentialProvider`, and `CredentialError`. Contains all business logic for validity, caching, refresh, and stale fallback.
- **Ports (Interfaces)**: The `CredentialProvider<C>` trait — the single abstraction that all backends implement and all consumers depend on.
- **Adapters (Implementations — `credential-provider`)**: Env, Vault, Azure, and AWS provider implementations, each gated behind a Cargo feature flag.
- **Dependency Direction**: The adapter crate depends on the core crate. Consumer libraries depend only on the core crate. Applications depend on the adapter crate and wire concrete providers at startup.

Backend selection is **compile-time** via Cargo feature flags. Applications enable only the features they need, and unused backend SDKs are not compiled.

## Consequences

**Enables:**

- Consumer libraries depend only on the lightweight core crate (no backend SDKs in their dependency tree)
- Adding a new backend requires only a new adapter implementation and feature flag — no changes to core
- `CachingCredentialProvider` works with any backend via the trait abstraction
- The `env` adapter provides a zero-dependency test double — no external service needed
- Clear boundary: business logic (validity, caching, stale fallback) lives in core; backend communication lives in adapters

**Forbids:**

- Backend-specific types in the core crate (no `vaultrs`, `azure-identity`, `aws-config` imports)
- Consumer libraries depending on the adapter crate directly (they accept `Arc<dyn CredentialProvider<C>>`)
- Caching logic in adapter implementations (caching is solely the core's responsibility)

**Trade-offs:**

- Two crates to maintain instead of one, with a versioning relationship between them
- The port trait (`CredentialProvider<C>`) is intentionally minimal (`get()` only) — backend-specific capabilities are not exposed through the abstraction

## Alternatives considered

### Option A: Single crate with all backends and feature flags

**Why not**: Consumer libraries would need to depend on the crate even though they only need the trait definition. Feature flags would prevent compilation of unused backends, but the crate would still carry all backend-specific code in its source tree, and consumers would transitively depend on the adapter crate's optional dependency declarations.

### Option B: Per-backend crates with no shared core

**Why not**: Each backend crate would define its own provider trait and credential types. Consumers would need to depend on a specific backend crate, creating tight coupling. Caching logic would be duplicated across every backend. No single abstraction for dependency injection.

### Option C: Shared trait crate with separate adapter crates per backend

**Why not**: Multiplies the number of crates (one per backend) without clear benefit. A single adapter crate with feature flags achieves the same compile-time selection with less packaging overhead. If the adapter crate grows too large in the future, this can be revisited.

## Implementation notes

**Key boundaries:**

- `credential-provider-core` never imports any backend SDK (`vaultrs`, `azure-identity`, `aws-config`, etc.)
- `credential-provider` re-exports `credential-provider-core` so applications can use a single dependency
- All backend-specific code is gated behind feature flags (`env`, `vault`, `azure`, `aws`)

**Testing strategy:**

- Unit tests for core use `MockCredentialProvider` — no external services
- Unit tests for adapters test error mapping and response parsing in isolation
- Integration tests for Vault use a dev-mode container
- The `env` adapter doubles as the test provider for consumer libraries

**Adding new backends:**

1. Add a new feature flag in `credential-provider/Cargo.toml`
2. Implement `CredentialProvider<C>` for the new backend
3. Gate the module behind `#[cfg(feature = "new-backend")]`
4. Add error mapping from the backend SDK to `CredentialError`
5. Document in the spec and update feature flag tables

## Examples

**Consumer library — depends only on core:**

```rust
use credential_provider_core::{CredentialProvider, UsernamePassword};
use std::sync::Arc;

pub struct QueueConnector {
    credentials: Arc<dyn CredentialProvider<UsernamePassword>>,
}

impl QueueConnector {
    pub async fn connect(&self) -> Result<(), Error> {
        let creds = self.credentials.get().await?;
        // Use creds.username and creds.password — never knows which backend
    }
}
```

**Application — wires concrete providers at startup:**

```rust
use credential_provider::vault::VaultProvider;
use credential_provider_core::CachingCredentialProvider;

let raw = VaultProvider::dynamic_credentials(vault_client, "rabbitmq", "creds/queue-keeper");
let provider = Arc::new(CachingCredentialProvider::new(raw, Duration::from_secs(60)));

let connector = QueueConnector { credentials: provider };
```

## References

- [Architecture Spec](../spec/architecture.md)
- [Responsibilities Spec](../spec/responsibilities.md)
- [Overview: Design Goals](../spec/overview.md#design-goals)
- Hexagonal Architecture: <https://alistair.cockburn.us/hexagonal-architecture/>
