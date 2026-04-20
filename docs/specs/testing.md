# Testing Strategy — Entry Sentinel

This document defines the testing approach, tool selection, required coverage, and specific test scenarios. All tests must follow the naming convention `test_{function}_{scenario}_{expected}`.

---

## Test Levels

### Unit Tests

**Scope**: Single functions and pure modules with no external I/O.
**Framework**: `cargo test` / `cargo nextest`
**Location**: `#[cfg(test)]` modules co-located with source code
**Characteristics**: No file I/O, no network, no async runtime dependencies where avoidable

Required for every function in:

- `ContentHasher`
- `ApprovalCommentParser`
- `ApprovalCommentBuilder`
- `ApprovalPayload` construction
- `DeterministicDetector` (one test per detection signature type)
- `HashComparator`
- `VerdictRouter` (pure routing logic)

---

### Integration Tests

**Scope**: Interactions with external systems through their abstract interfaces, using test doubles or sandbox environments.
**Framework**: `cargo nextest` (parallel execution)
**Location**: `tests/` directory at crate root
**Characteristics**: May use real async runtime; may use test doubles or sandboxed real services

Required integration test scenarios:

| Scenario | External System | Test Approach |
|---|---|---|
| Full new issue clean path | GitHub API sandbox + Vault dev | End-to-end from webhook receipt to label application |
| Full new issue suspect path | GitHub API sandbox | End-to-end from webhook receipt to quarantine + lock |
| Edit with same hash (no-op) | GitHub API sandbox | Verify no write calls made |
| Edit with different hash (clean) | GitHub API sandbox + Vault dev | Verify approval comment updated |
| Edit with different hash (suspect) | GitHub API sandbox | Verify content reverted, quarantine applied |
| Vault unavailable for signing | Mock Vault returning 503 | Verify clean path aborts; issue remains unlabelled |
| Duplicate webhook delivery | Internal | Verify DeliveryIdGuard discards second delivery |
| GitHub API 429 with retry success | Mock GitHub returning 429 then 200 | Verify retry succeeds within bounds |
| Detection signature library load | File-based config | Verify all signature types parse correctly |

---

### Property-Based Tests

**Framework**: `proptest`
**Location**: Co-located with unit tests in `#[cfg(test)]` modules
**Purpose**: Verify invariants hold for arbitrary inputs

Required property tests:

**ContentHasher:**

- `hash(content_a) == hash(content_a)` for all `content_a` — determinism
- `hash(content_a) != hash(content_b)` for all `content_a != content_b` — sensitivity (with high probability)
- `hash(content)` always produces a 32-byte array — output length invariant
- `hash` over title + `"\n"` + body equals manual SHA-256 over the same byte sequence

**ApprovalCommentParser:**

- All well-formed approval comment strings (with `issue:`, `approved:`, `hash:`, `key_id:`, `signature:` fields) parse successfully
- All strings missing any required field return `ParseError`
- All strings with a malformed base64 signature field return `ParseError`
- Parsing is not sensitive to surrounding whitespace within field values

**DeterministicDetector:**

- No signature matches the empty string
- No signature matches a string containing only ASCII whitespace (spaces, tabs, newlines)
- A signature that matched a string S also matches any string containing S as a substring (where applicable for substring patterns)

**DeterministicDetector — adversarial evasion invariants (critical):**

The detection module is the primary security boundary. Property tests must verify that common evasion techniques do not produce a `Clean` verdict for content that a baseline match would catch. All of the following must be satisfied for every signature in the library:

- **Mixed case**: if pattern P matches string S, then `DeterministicDetector::scan` also returns `Suspect` for S with any casing variation (e.g., `Ignore All Previous Instructions`, `IGNORE all PREVIOUS instructions`). Patterns must compile with case-insensitive flags.
- **Whitespace insertion**: if P matches S, then `Suspect` is returned for S with extra spaces, tabs, or newlines inserted between significant words (e.g., `ignore  all   previous\tinstructions`). Patterns must account for variable whitespace between tokens.
- **Unicode lookalikes / homoglyphs**: generate strings by substituting ASCII characters in known suspect phrases with visually similar Unicode codepoints (e.g., Latin `a` → Cyrillic `а`, `o` → `ө`). The detector must return `Suspect` for these *or* the content must trigger the `non-utf8-content` or structural heuristic suspects. The scanner must not silently pass homoglyph evasions as `Clean`.
- **Zero-width and invisible characters**: insert Unicode zero-width joiners (U+200D), zero-width non-joiners (U+200C), and soft hyphens (U+00AD) within known suspect phrases. The detector must return `Suspect` for these. Detection signatures for phrase-level patterns must be designed to tolerate or explicitly strip these characters before matching.
- **Base64 encoding**: a base64-encoded representation of a known suspect phrase (or the URL containing it) must not pass as `Clean`. The URL/encoding heuristic signatures must cover this.
- **Ordering of checks**: for any generated suspect input S, the verdict returned by scanning S is always `Suspect` regardless of which signature fires first. No ordering of signatures in the library should produce `Clean` for S.

**ContentHasher — canonical form:**

- `hash(IssueContent { title: t, body: b })` is equivalent to `sha2::Sha256::digest(format!("{t}\n{b}").as_bytes())`

---

### Contract Tests

**Scope**: Verify that the abstract trait interfaces behave as business logic expects.
**Framework**: Mock implementations (`mockall` or hand-written) combined with `cargo nextest`
**Purpose**: Catch regressions in integration points before hitting real external services

Required contract tests:

**GitHubIssueWriter:**

- When `set_labels` is called with an empty slice, the GitHub API call clears all labels
- When `lock` is called, the issue is locked with the correct lock reason
- When `update_content` is called, both title and body are sent in the same API call

**GitHubCommentWriter:**

- When `post_comment` is called, the exact comment body string is sent
- When `update_comment` is called with a `CommentId`, the correct comment is updated
- When `delete_comment` is called, only the specified comment is deleted

**VaultClient:**

- `sign` is called with the exact `ApprovalPayload` bytes (not a partial or serialised form)
- The returned `ApprovalSignature` has exactly 64 bytes

**AiProvider:**

- A prompt is sent that contains the constrained instruction (does not reproduce issue content in the instruction text itself)
- The provider times out after the configured duration

---

### Mutation Tests

**Tool**: `cargo-mutants`
**Minimum score**: 70% per module (see `constraints.md` C-34); detection module minimum is **90%** (see below)
**Priority modules**: Detection engine, verdict routing, content integrity, approval signing

Run mutation tests for:

- `DeterministicDetector`: mutants that change match conditions must fail at least one test; mutants that short-circuit any individual signature check must fail; mutants that change `Suspect` to `Clean` must fail immediately — **minimum mutation score for this module is 90%**, not 70%, because a surviving mutant means a code path exists that silently passes suspect content
- `VerdictRouter`: mutants that invert the clean/suspect branch must fail at least one test
- `ContentIntegrityChecker`: mutants that bypass the hash comparison must fail at least one test
- `ApprovalCommentParser`: mutants that suppress `ParseError` returns must fail at least one test
- `ApprovalPayload` construction: mutants that omit any field (`issue:`, `approved:`, `hash:`, `key_id:`) must fail at least one test

---

### Fuzz Tests

**Tool**: `cargo-fuzz` (libFuzzer)
**Location**: `fuzz/fuzz_targets/` at the workspace root
**Purpose**: Expose panics, unexpected behaviour, and security-relevant corner cases under arbitrary byte input

Entry Sentinel processes attacker-controlled input at multiple points. Fuzz tests target the boundaries where that input enters the system.

**Required fuzz targets:**

| Target | Input | Invariant |
|---|---|---|
| `fuzz_approval_comment_parser` | Arbitrary `&str` | `parse_approval_comment` never panics; any input returns `Ok` or `Err(ParseError)` |
| `fuzz_detection_pattern_match` | Arbitrary `&str` | `DeterministicDetector::scan` never panics on any input string |
| `fuzz_detection_no_false_approval` | Arbitrary `&str` derived by mutating known-suspect phrases | `DeterministicDetector::scan` returns `Suspect` for all mutated inputs; a mutation that produces `Clean` is a security-critical finding |
| `fuzz_detection_encoding_evasion` | Arbitrary byte sequences decoded as UTF-8 where valid, rejected otherwise | Non-UTF-8 input returns `Suspect` with reason `non-utf8-content`; all valid UTF-8 input is classified without panic |
| `fuzz_webhook_payload_parse` | Arbitrary `&[u8]` | Webhook payload parsing never panics; invalid JSON always returns a typed error |
| `fuzz_queue_message_parse` | Arbitrary `&[u8]` | Queue message parsing never panics; invalid input always returns a typed error |
| `fuzz_content_hasher` | Arbitrary `(String, String)` | `hash_content` never panics; output is always 32 bytes |

**Fuzz target detail — `fuzz_detection_no_false_approval` (critical):**

This target is the most security-sensitive fuzz target in the codebase. Its purpose is to find inputs that the detector incorrectly classifies as `Clean` when they are semantically equivalent to a known-suspect phrase.

Seed corpus construction:
- Start with the full set of known-suspect phrases extracted from the `DetectionSignatureLibrary`
- Apply mutation operators: casing changes, whitespace insertion, Unicode homoglyph substitution, zero-width character insertion, base64 encoding, URL encoding, HTML entity encoding
- All seeds must produce `Suspect` before being added to the corpus (verify the baseline)

Invariant under fuzzing:
- For every input derived from a seed, the verdict must be `Suspect`
- Any `Clean` verdict on a mutated-seed input is a **security bug**, not just a test failure; the finding must be filed immediately and the corresponding detection signature updated
- Engine crashes are bugs regardless of their security relevance

This target must be run for a minimum of **10 minutes in CI** (not 60 seconds like the other targets) and for **at least 24 hours** before any release.

**Corpus management:**
- Seed corpus for each target lives in `fuzz/corpus/<target_name>/`
- Known crash-triggering inputs are committed as regression cases
- CI runs `fuzz_detection_no_false_approval` for a minimum of 10 minutes; all other targets for 60 seconds; longer runs are scheduled separately
- Any crash or `ParseError` missed by the unit/property suite is converted to a regression unit test
- Any `Clean` result from `fuzz_detection_no_false_approval` is treated as a critical security regression and blocks release

---

## Test Scenarios by Feature

### New Issue Scan

| Test | Type | Assertion |
|---|---|---|
| `test_scan_clean_content_returns_clean_verdict` | Unit | DeterministicDetector: content with no matching signatures → `Verdict::Clean` |
| `test_scan_prompt_injection_pattern_returns_suspect` | Unit | One test per registered injection pattern |
| `test_scan_oversized_content_returns_suspect` | Unit | Content ≥ max bytes → `Verdict::Suspect` with reason `content-too-large` |
| `test_scan_empty_body_succeeds` | Unit | Empty body → hash computed correctly, no detection error |
| `test_scan_empty_title_returns_suspect` | Unit | Empty title → `Verdict::Suspect` with reason `empty-title` |
| `test_scan_non_utf8_content_returns_suspect` | Unit | Non-UTF-8 bytes → `Verdict::Suspect` with reason `non-utf8-content` |
| `test_ai_scan_clean_response_returns_clean` | Unit | AI returns `"clean"` → `Verdict::Clean` |
| `test_ai_scan_suspect_response_returns_suspect` | Unit | AI returns `"suspect"` → `Verdict::Suspect` |
| `test_ai_scan_non_binary_response_returns_suspect` | Unit | AI returns anything else → `Verdict::Suspect`, raw response not in audit log |
| `test_ai_scan_timeout_returns_suspect` | Unit/Mock | AI times out → `Verdict::Suspect` with reason `ai-provider-error` |
| `test_scanner_deterministic_runs_before_ai` | Unit | AI is not invoked when deterministic result is `Suspect` |
| `test_scanner_ai_not_invoked_when_disabled` | Unit | AI disabled in config → AI provider never called |

---

### Content Hashing

| Test | Type | Assertion |
|---|---|---|
| `test_hash_content_is_deterministic` | Unit/Property | Same input → same hash every time |
| `test_hash_content_differs_on_title_change` | Unit | Changing title → different hash |
| `test_hash_content_differs_on_body_change` | Unit | Changing body → different hash |
| `test_hash_canonical_form_matches_manual_sha256` | Unit/Property | Output equals manual SHA-256 over canonical bytes |
| `test_hash_empty_body_includes_newline_separator` | Unit | Empty body → hash over `title + "\n"` |

---

### Approval Comment

| Test | Type | Assertion |
|---|---|---|
| `test_build_approval_comment_contains_all_fields` | Unit | Output contains `issue:`, `approved:`, `hash:`, `key_id:`, `signature:` |
| `test_parse_approval_comment_well_formed_succeeds` | Unit/Property | Round-trip: build → parse succeeds |
| `test_parse_approval_comment_missing_hash_returns_error` | Unit | `ParseError` on missing `hash:` field |
| `test_parse_approval_comment_missing_signature_returns_error` | Unit | `ParseError` on missing `signature:` field |
| `test_parse_approval_comment_invalid_base64_returns_error` | Unit | `ParseError` on non-base64 signature |
| `test_parse_approval_comment_truncated_returns_error` | Unit | `ParseError` on comment missing closing `-->` |
| `test_build_approval_payload_is_correct_format` | Unit | Output matches `"issue:<id>\napproved:<ts>\nhash:sha256:<hex>\nkey_id:<key_id>\n"` exactly |

---

### Verdict Routing

| Test | Type | Assertion |
|---|---|---|
| `test_router_clean_verdict_invokes_approval_handler` | Unit/Mock | `Verdict::Clean` → `ApprovalHandler` called |
| `test_router_suspect_verdict_invokes_quarantine_handler` | Unit/Mock | `Verdict::Suspect` → `QuarantineHandler` called |
| `test_router_clean_path_label_not_applied_if_comment_fails` | Integration | Comment post fails → no label write calls made |

---

### Edit Flow

| Test | Type | Assertion |
|---|---|---|
| `test_edit_identical_hash_produces_no_action` | Integration | Hash unchanged → no GitHub writes |
| `test_edit_different_hash_clean_updates_comment` | Integration | Hash changed, clean → comment replaced, labels unchanged |
| `test_edit_different_hash_suspect_reverts_and_quarantines` | Integration | Hash changed, suspect → content reverted, approval deleted, quarantine applied |
| `test_edit_no_approval_comment_triggers_full_scan` | Integration | Missing approval comment → full scan runs |
| `test_edit_malformed_approval_comment_triggers_full_scan` | Integration | Malformed comment → treated as missing |

---

### Failure Handling

| Test | Type | Assertion |
|---|---|---|
| `test_new_issue_vault_unavailable_leaves_unlabelled` | Integration | Vault 503 → no labels, no comment, alert raised |
| `test_edit_vault_unavailable_triggers_quarantine` | Integration | Vault 503 after hash mismatch → conservative quarantine |
| `test_new_issue_github_404_records_audit_no_alert` | Integration | Issue 404 → audit records `issue-not-found`, no alert |
| `test_github_429_retries_and_succeeds` | Integration/Mock | 429 then 200 → operation completes on retry |

---

### Idempotency

| Test | Type | Assertion |
|---|---|---|
| `test_duplicate_delivery_id_discarded` | Unit | Same delivery ID → second handler call returns immediately, no writes |
| `test_existing_approval_comment_updated_not_duplicated` | Integration | Approval comment exists → updated in-place, not posted as new |

---

## Coverage Requirements

| Module | Line Coverage | Mutation Score |
|---|---|---|
| Detection (`deterministic`, `ai_detector`, `scanner`) | 100% | ≥70% |
| Content integrity (`hasher`, `parser`, `builder`) | 100% | ≥70% |
| Verdict routing | 100% | ≥70% |
| Approval and quarantine handlers | 100% | — |
| Infrastructure (`octocrab`, `vault`, `ai_provider`) | ≥80% | — |
| Overall integration | ≥90% of paths | — |

---

## Test Environment Requirements

**GitHub API Sandbox**: A dedicated GitHub organisation for testing with at minimum one repository. Test issues must be created and cleaned up within each test run. The sandbox App installation must have the same permissions as the production installation.

**Vault Dev Instance**: HashiCorp Vault in dev mode (`vault server -dev`) with:

- A transit secrets engine enabled
- A pre-loaded Ed25519 key at the configured test path
- An AppRole with the same policy as the production AppRole

**Detection Signature Config**: A test-only signature library loaded from a local file, containing at minimum one matching and one non-matching signature per category.
