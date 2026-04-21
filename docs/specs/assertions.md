# Behavioural Assertions — Entry Sentinel

Testable specifications in Given/When/Then format. Each assertion must be covered by at least one automated test. Assertions are grouped by feature area.

See [vocabulary.md](vocabulary.md) for term definitions and [edge-cases.md](edge-cases.md) for failure mode coverage.

---

## New Issue — Clean Path

**A-01: Clean issue receives approval comment and clean-path labels**

- Given: A new issue is opened with content that matches no detection signatures
- When: The `issues: opened` webhook is received
- Then: A hidden approval comment is posted containing a valid timestamp, `ContentHash`, and `ApprovalSignature`; the labels `process:development` and `state:discovery` are applied; the issue is not locked; the audit log records outcome `clean`

**A-02: Approval comment is well-formed and self-consistently signed**

- Given: A clean verdict has been produced
- When: The approval comment is posted
- Then: The comment parses successfully using `ApprovalCommentParser`; the Ed25519 signature verifies against Entry Sentinel's published public key; the hash in the comment matches the SHA-256 of the current title and body

**A-03: Labels are not applied before the approval comment is posted**

- Given: A clean verdict has been produced
- When: The `GitHubCommentWriter` returns an error when posting the approval comment
- Then: No labels are applied to the issue; the audit log records outcome `error`; an alert is raised

**A-04: Clean issue with AI second pass enabled**

- Given: A new issue passes deterministic checks; AI second pass is enabled; the AI returns `clean`
- When: The `issues: opened` webhook is received
- Then: Same outcome as A-01; the audit log records that the AI pass was executed and returned `clean`

---

## New Issue — Suspect Path

**A-05: Issue with matching detection signature is quarantined**

- Given: A new issue is opened containing content that matches a known detection signature
- When: The `issues: opened` webhook is received
- Then: No approval comment is posted; `process:admin` and `state:quarantine` labels are applied; the issue is locked; a generic quarantine comment is posted (containing no detection reason); the designated reviewer is notified; the audit log records outcome `suspect` with the triggering signature ID

**A-06: Issue locked before notification is sent**

- Given: A suspect verdict has been produced
- When: The quarantine sequence executes
- Then: The `GitHubIssueWriter.lock()` call completes before any `AlertSink.send()` call is made

**A-07: Quarantine comment does not disclose detection reason**

- Given: A suspect verdict was triggered by a specific detection signature
- When: The quarantine comment is inspected
- Then: The comment text does not contain the name, ID, or pattern of the triggering detection signature; the comment text does not identify which check failed

**A-08: AI second pass returns suspect — issue is quarantined**

- Given: A new issue passes deterministic checks; AI second pass is enabled; the AI returns `suspect`
- When: The `issues: opened` webhook is received
- Then: Same quarantine outcome as A-05; the audit log records that the AI pass triggered the suspect verdict

**A-09: AI second pass returns non-binary response — treated as suspect**

- Given: A new issue passes deterministic checks; AI second pass is enabled; the AI returns a response that is not `clean` or `suspect` (e.g., empty, multiline, refusal)
- When: The AI response is parsed
- Then: The verdict is `Suspect`; the quarantine sequence runs; the raw AI response is not logged; the audit log records outcome `suspect` with reason `ai-non-binary-response`

**A-10: Processing failure on new issue — issue remains unlabelled**

- Given: Entry Sentinel encounters an unrecoverable error while processing a new issue (e.g., Vault unreachable)
- When: The error occurs at any point before labels are applied
- Then: The issue remains unlabelled; no partial labels are applied; no approval comment is posted; an alert is raised; the audit log records outcome `error`

---

## Edited Issue — No Meaningful Change

**A-11: Edit with identical hash produces no action**

- Given: An approved issue is edited in a way that does not change the title or body (e.g., a metadata-only change)
- When: The `issues: edited` webhook is received
- Then: No label changes are made; no new comment is posted; the existing approval comment is untouched; the audit log records outcome `no-change`

---

## Edited Issue — Clean Re-Scan

**A-12: Clean edit updates the approval comment**

- Given: An approved issue is edited, producing a different content hash; the re-scan verdict is `clean`
- When: The `issues: edited` webhook is received
- Then: The existing approval comment is replaced with a new one bearing a fresh timestamp, hash, and signature; the labels `process:development` and the existing `state:*` label are retained unchanged; the issue is not locked; the audit log records outcome `clean`

**A-13: Updated approval comment verifies correctly**

- Given: An approval comment has been updated after a clean re-scan
- When: The new comment is parsed and the signature is verified
- Then: The signature is valid against the published public key; the hash matches the current title and body

---

## Edited Issue — Suspect Re-Scan (Mid-Pipeline Quarantine)

**A-14: Suspect edit triggers content reversion before quarantine**

- Given: An approved issue is edited, producing a different content hash; the re-scan verdict is `suspect`
- When: The `issues: edited` webhook is received
- Then: The issue title and body are reverted to the values recorded in the approval comment; the approval comment is deleted; `process:development` and all `state:*` labels are removed; `process:admin` and `state:quarantine` are applied; the issue is locked; the reviewer is notified; the audit log records outcome `suspect`

**A-15: Reverted content matches the approved content exactly**

- Given: A suspect mid-pipeline quarantine has been executed
- When: The issue title and body are read via the GitHub API
- Then: They are byte-for-byte identical to the title and body that were recorded in the approval comment at the time of approval

**A-16: Edit event on issue with no approval comment — treated as new issue**

- Given: An `issues: edited` event is received for an issue that has no approval comment
- When: The handler attempts to locate the approval comment
- Then: The issue is treated as a new unscanned issue and goes through the full scan flow (A-01 through A-10 apply)

**A-17: Processing failure on edit — conservative quarantine**

- Given: Entry Sentinel encounters an unrecoverable error while processing an edit event (e.g., Vault unreachable after hash mismatch detected)
- When: The error occurs
- Then: The issue is conservatively quarantined; a human is notified; the audit log records outcome `error`

---

## Idempotency

**A-18: Duplicate webhook delivery produces no double-writes**

- Given: A webhook delivery ID has already been processed
- When: The same delivery ID arrives again (GitHub retry)
- Then: The handler exits immediately with HTTP 200; no GitHub API write calls are made; no audit event is written for the duplicate

**A-19: Clean verdict with existing approval comment — comment is updated, not duplicated**

- Given: An approval comment already exists on an issue (e.g., due to a prior re-scan)
- When: A new clean verdict is produced
- Then: The existing comment is updated in-place (not deleted and re-created as a separate comment); exactly one approval comment exists after the operation

---

## Approval Comment Integrity (Downstream Precondition)

**A-20: Tampered hash fails downstream verification**

- Given: An approval comment has been manually edited to change the hash value
- When: A downstream service parses the comment, recomputes the hash, and compares
- Then: The computed hash does not match the stored hash; the downstream service's precondition check fails

**A-21: Tampered signature fails downstream verification**

- Given: An approval comment has been manually edited to change the signature
- When: A downstream service verifies the signature using Entry Sentinel's public key
- Then: Signature verification fails; the downstream service's precondition check fails

**A-22: Stale approval comment fails downstream verification after content change**

- Given: An issue was approved, then the title or body was changed without Entry Sentinel re-approving it
- When: A downstream service computes the hash of the current title and body and compares with the stored hash
- Then: The hashes differ; the downstream service's precondition check fails

---

## Detection Signatures

**A-23: Detection signature library version is recorded for every scan**

- Given: Any scan (new issue or re-scan) is performed
- When: The audit event is written
- Then: It includes the version string of the `DetectionSignatureLibrary` that was loaded at the time

**A-24: Oversized issue is classified as suspect without full scan**

- Given: An issue with content exceeding the configured maximum length (default: 65 536 bytes)
- When: The scan runs
- Then: The verdict is `Suspect` immediately; the triggering reason is `content-too-large`; no pattern matching is performed; the audit log records this reason

**A-25: Empty body does not cause detection errors**

- Given: A new issue is opened with a non-empty title and an empty body
- When: The scan runs
- Then: The scan completes successfully; the hash is computed over `UTF-8(title) + b"\n" + b""` (the newline separator is always present regardless of body content)

---

## Detection Correctness (Security-Critical)

The assertions in this section exist because the deterministic detector is the primary security boundary. A silent false-negative (returning `Clean` on a genuinely suspect input) is a security failure, not a ordinary bug. Each assertion must be covered by at least one property test AND at least one fuzz corpus seed.

**A-26: Every signature in the loaded library matches its own canonical phrase**

- Given: A `DetectionSignatureLibrary` is loaded containing N signatures
- When: For each signature S, an issue is constructed whose body contains the exact canonical phrase that S is defined to detect
- Then: `DeterministicDetector::scan` returns `Verdict::Suspect` for all N issues; no canonical phrase produces `Verdict::Clean`

**A-27: Mixed-case variants of a canonical suspect phrase produce `Suspect`**

- Given: Signature S matches canonical phrase P (e.g., `ignore all previous instructions`)
- When: P is presented with arbitrary casing (e.g., `Ignore All Previous Instructions`, `IGNORE ALL PREVIOUS INSTRUCTIONS`, `iGnOrE aLl PrEvIoUs InStRuCtIoNs`)
- Then: `DeterministicDetector::scan` returns `Verdict::Suspect` for all casing variants; detection patterns must compile with case-insensitive flags

**A-28: Whitespace-inflated variants of a canonical suspect phrase produce `Suspect`**

- Given: Signature S matches canonical phrase P
- When: P is presented with extra spaces, tabs, or newlines inserted between significant words (e.g., `ignore  all   previous\tinstructions`)
- Then: `DeterministicDetector::scan` returns `Verdict::Suspect`; patterns must tolerate variable inter-token whitespace for phrase-level signatures

**A-29: Non-UTF-8 byte sequences produce `Suspect`, not `Clean`**

- Given: An issue payload contains bytes that are not valid UTF-8
- When: The scan runs
- Then: The verdict is `Verdict::Suspect` with reason `non-utf8-content`; no pattern matching is attempted; the scan does not panic or return an error to the caller

**A-30: Detection result is reproducible given identical inputs**

- Given: A `DetectionSignatureLibrary` L and issue content C
- When: `DeterministicDetector::scan(C, L)` is called twice
- Then: Both calls return identical verdicts and identical triggering reasons; the detector has no internal mutable state that affects classification

**A-31: AI prompt construction never embeds raw issue content outside the designated slot**

- Given: Any `IssueContent` value (including adversarial content injecting prompt-like instructions)
- When: `AiDetector` constructs the prompt sent to the AI backend
- Then: The raw issue title and body appear only within the explicitly delimited content placeholder; the binary-verdict instruction always appears verbatim and is not overridden by issue content; the constructed prompt is structurally invariant (same template, only the content slot varies)

**A-32: Detection audit log records signature ID, not issue content**

- Given: A scan produces `Verdict::Suspect`
- When: The audit event is written
- Then: The audit log contains the ID(s) of the signature(s) that fired; the audit log does NOT contain any substring of the raw issue title or body; this prevents sensitive or malicious content from propagating into log sinks
