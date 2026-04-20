# Code Standards

## Code Organization

### Workspace Structure

This is a Cargo workspace with a single crate.

### Module Structure

Organize code into logical modules following clean architecture principles:

```
src/
├── lib.rs              # Public API and module declarations
├── error.rs            # Error types and handling
├── error_tests.rs      # Error tests
├── module1.rs          # Module 1 public interface (use for single-file modules)
├── module1/
│   ├── mod.rs          # Module public interface (use for multi-file modules)
│   ├── mod_tests.rs    # Module-level tests
│   ├── types.rs        # Domain types
│   ├── types_tests.rs  # Type tests
│   └── implementation.rs
├── module2.rs          # Module 2 public interface
└── module2/
    └── ...
```

**File vs Directory Modules**:

- Single file `module.rs`: Module fits in one file, no submodules needed
- Directory `module/mod.rs`: Module requires multiple files or has submodules

### Naming Conventions

- **Module names**: lowercase with underscores (`auth_provider`, `queue_client`)
- **Type names**: PascalCase (`GitHubAppId`, `InstallationToken`)
- **Function names**: snake_case (`get_installation_token`, `is_expired`)
- **Test files**: `<source_file>_tests.rs`
- **Test functions**: `test_<what_is_being_tested>`

## Documentation

### Rustdoc Requirements

All public APIs must have rustdoc comments:

```rust
/// Brief one-line summary of what this does.
///
/// More detailed explanation of the functionality, including:
/// - Key behaviors
/// - Important constraints
/// - Edge cases
///
/// # Examples
///
/// ```rust
/// use crate::MyType;
///
/// let instance = MyType::new(42);
/// assert_eq!(instance.value(), 42);
/// ```
///
/// # Errors
///
/// Returns `ErrorType` if:
/// - Condition 1
/// - Condition 2
///
/// # Panics
///
/// Documents any conditions that cause panics.
pub fn public_api() -> Result<(), ErrorType> {
    // Implementation...
}
```

### Test Documentation

Test functions should have doc comments explaining what they verify:

```rust
/// Verify that expired tokens are correctly identified.
///
/// Creates a token that expired 5 minutes ago and verifies
/// that `is_expired()` returns true.
#[test]
fn test_token_expiration_detection() {
    // Test implementation...
}
```

## Error Handling

### Error Type Guidelines

1. Use `thiserror` for error type derivation
2. Implement retry classification (`is_transient()`, `should_retry()`)
3. Include sufficient context for debugging
4. Never expose secrets in error messages
5. Use `.context()` to build error chains with additional context

```rust
#[derive(Debug, Error)]
pub enum MyError {
    #[error("Operation failed: {context}")]
    OperationFailed { context: String },

    #[error("Resource not found: {id}")]
    NotFound { id: String },
}

impl MyError {
    pub fn is_transient(&self) -> bool {
        match self {
            Self::OperationFailed { .. } => true,
            Self::NotFound { .. } => false,
        }
    }
}
```

## Rust-Specific Conventions

### Type Safety

- Use newtype pattern for domain identifiers
- Leverage type system to prevent invalid states
- Use `#[must_use]` for types that shouldn't be ignored

```rust
/// GitHub App identifier.
///
/// This is a newtype wrapper to prevent mixing up different ID types.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[must_use]
pub struct GitHubAppId(u64);
```

### Async/Await

- All I/O operations must be async
- Use `#[async_trait]` for async trait methods
- Document cancellation behavior
- Ensure proper resource cleanup
- Use `tokio::spawn` for concurrent tasks; avoid blocking operations in async context
- Implement timeouts with `tokio::time::timeout` for operations that may hang
- Use `tokio::select!` for cancellation patterns

### Trait Design

- Use traits for abstraction boundaries and testability
- Prefer trait objects (`dyn Trait`) for runtime polymorphism
- Use generic bounds (`T: Trait`) for compile-time polymorphism
- Document trait contracts thoroughly, including preconditions and postconditions
- Implement common traits (`Clone`, `Debug`, `Send`, `Sync`) when appropriate

### Performance Considerations

- Prefer borrowing (`&T`) over cloning when possible
- Use `Arc<T>` for shared ownership across threads
- Use `Cow<'_, T>` when data may or may not need to be owned
- Avoid unnecessary allocations in hot paths
- Profile before optimizing; measure impact of changes

### Security

- Never log secrets or tokens
- Implement `Debug` carefully for sensitive types
- Use constant-time comparison for security-critical operations
- Zero sensitive memory on drop when possible
- Validate and sanitize all external inputs (webhooks, API responses, user data)
- Use type system to distinguish validated vs unvalidated data

```rust
impl std::fmt::Debug for SecretToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecretToken")
            .field("token", &"<REDACTED>")
            .finish()
    }
}
```

### Logging and Observability

- Use structured logging with appropriate levels (trace, debug, info, warn, error)
- **Critical**: Never log secrets, tokens, or sensitive data in any form
- Log operation start/end for auditing
- Include correlation IDs for distributed tracing
- Use `Debug` trait carefully on types containing sensitive data
