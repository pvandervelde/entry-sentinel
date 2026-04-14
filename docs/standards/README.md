# Standards

These are stable conventions that keep the repo consistent.

If a rule changes often, it probably belongs in an ADR or a short guide instead.

## Active Standards for RepoRoller

- [code.md](code.md) — Coding conventions, naming, structure, error handling, documentation
- [testing.md](testing.md) — Test organization, coverage expectations, integration testing

## Related Documentation

- [ADRs](../adr/README.md) — Architecture Decision Records for significant design decisions
- [Technology Decisions](../../.tech-decisions.yml) — Technology choices and standards for enforcement
- [Constraints](../constraints.md) — Quick reference of hard rules and preferences
- [Catalog](../catalog.md) — What exists and where to find reusable components

## Recommended Standards Files (create as needed)

- `api.md` — versioning, backwards compatibility, deprecation policy
- `data.md` — schema changes, migrations, privacy, retention
- `security.md` — secrets, auth, permissions, threat model basics
- `observability.md` — logs/metrics/tracing, required fields, sampling
- `build-release.md` — CI, artifact versioning, release process
- `style-<lang>.md` — language-specific conventions (go/rust/python/ts/etc.)
