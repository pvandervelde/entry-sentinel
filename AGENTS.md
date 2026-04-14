# AI Agent Guidelines

This file provides guidance and context for AI coding assistants working on this project.

## Project Overview

Entry Sentinel is a standalone service backed by a GitHub App that guards the intake boundary of the OffAxis Dynamics issue pipeline. Every newly created issue passes through Entry Sentinel before any other automation touches it. Its sole responsibility is to determine whether an issue is safe to process, applying the appropriate label to route it into the pipeline or into quarantine for human review.

Key traits:
- **Security gate**: Entry Sentinel is the first and only gate before any downstream automation (Triage Titan, Scope-Sage, CogWorks) acts on an issue. No issue enters the pipeline without an explicit `clean` verdict.
- **Binary verdict**: Produces exactly `clean` or `suspect` — no scores, no partial labels, no ambiguity. Ambiguous cases are suspect.
- **Cryptographic integrity**: Signs every approved issue with Ed25519. Downstream services verify the signature independently before acting, with no inter-service coordination required.
- **Deterministic-first detection**: Pattern matching and structural heuristics run before any optional AI-assisted second pass.
- **Content integrity on edit**: Re-scans edited issues and reverts + quarantines if new content fails the scan.
- **Narrow scope**: Entry Sentinel has no knowledge of priority, completeness, or architecture — those concerns belong downstream.

See [docs/specs/overview.md](docs/specs/overview.md) for the full system context and [docs/specs/README.md](docs/specs/README.md) for the spec index.

## Production Software Standards

**This is production-grade software.** All code must meet production quality standards:

- **Complete Implementation**: No TODOs, placeholders, or "demonstration" code. Every feature must be fully implemented.
- **Comprehensive Error Handling**: All error paths must be handled properly, with clear error messages and proper error propagation.
- **Full Test Coverage**: All functionality must have comprehensive tests covering happy paths, error cases, and edge conditions.
- **Production-Ready Documentation**: All public APIs must have complete rustdoc with examples, error conditions, and behavioral specifications.
- **Security First**: All security-sensitive operations must be implemented with production-grade security measures.
- **Performance Conscious**: Code must be optimized for production workloads, not just correctness.
- **Observability**: All operations must have appropriate logging, metrics, and tracing for production debugging.

When implementing features:

- Write production code from the start - no prototypes or demos
- Think about failure scenarios and edge cases
- Consider operational concerns (monitoring, debugging, maintenance)
- Implement complete functionality, not partial demonstrations

## Pre-Implementation Checklist

Before implementing features, verify:

1. **Read Specifications**: Check docs/specs/ for relevant documentation
2. Read [docs/specs/constraints.md](docs/specs/constraints.md) (implementation rules and tripwires)
3. Read [docs/specs/requirements.md](docs/specs/requirements.md) (what must be true — use to confirm scope before adding code)
4. Read relevant standards in [docs/standards/](docs/standards/) (language/domain specific; may be empty early in the project)
5. **Search Existing Code**: Use semantic_search to find similar implementations
6. **Check Module Structure**: Determine if code belongs in existing module or needs new one
7. **Security Review**: Identify sensitive data (tokens, secrets) requiring special handling
8. **Plan Tests**: Identify test scenarios before writing implementation

## Summary

Following these conventions ensures:

- **Consistency**: Codebase looks like one person wrote it
- **Maintainability**: Easy to find and understand code
- **Quality**: High test coverage and clear documentation
- **Security**: Sensitive data handled properly
- **Performance**: Conscious resource management

When in doubt, look at existing code in the repository as examples of these patterns in practice.

## Workflow

1. Check for existing ADRs related to your task
2. Follow coding standards in .tech-decisions.yml
3. Write tests before implementation (TDD preferred)
4. Run pre-commit hooks before committing
5. Include context in commit messages

## Task Management

This project uses Beads (bd) for AI-friendly task tracking.

### Before starting work

1. Check what's ready: `bd ready --json`
2. Pick a task: `bd show bd-abc --json`
3. Start work: `bd update bd-abc working`

### When creating new tasks

1. Create issue: `bd create "Task description" -p 1 -t feature`
2. Add dependencies: `bd update bd-xyz --blocks bd-abc`
3. The task will auto-appear in `bd ready` when blockers are done

### When finishing work

1. Commit with issue ID: `git commit -m "Fix auth bug (bd-abc)"`
2. Close issue: `bd close bd-abc --reason "Completed"`
3. Sync: `bd sync` (usually automatic)

### Integration with ADRs

- Link ADRs in task descriptions: "See ADR-0005 for context"
- Create tasks for implementing ADR decisions
- Reference task IDs in ADR implementation notes

### Quick reference

``bash
bd ready              # Show tasks ready to work on
bd create "desc" -p 1 # Create new task (priority 1-5)
bd show bd-xyz        # Show task details
bd update bd-xyz working  # Mark task in progress
bd close bd-xyz       # Close completed task
bd search "keyword"   # Search tasks
bd doctor             # Check for orphaned work
``
