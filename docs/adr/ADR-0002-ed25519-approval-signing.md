# ADR-0002: Ed25519 for Approval Comment Signing

Status: Accepted
Date: 2026-04-15
Owners: entry-sentinel

## Context

Entry Sentinel posts an approval comment on clean issues. Downstream services must be able to verify that the comment was genuinely produced by Entry Sentinel and that the approved content has not changed since approval.

The verification must work without contacting Entry Sentinel directly — each downstream service verifies independently using only the comment and a published public key. This decentralised trust model requires asymmetric cryptography.

The approval comment is the primary integrity mechanism across the pipeline. Any weakness in the signing scheme is a weakness in the entire pipeline.

Two additional design questions arose:
1. **Should the issue ID be included in the signed payload?** Including it binds the signature to a specific issue and fully closes the cross-issue replay attack (a valid approval comment from issue A cannot be applied to issue B).
2. **Do we need a timestamped signature (RFC 3161 / TSA) to prove the key was valid at signing time, which would help with key rotation?** An RFC 3161 Trusted Timestamp Authority would provide a third-party proof that signature S existed at time T, allowing downstream verifiers to accept old signatures even after a key is retired. However, this introduces an external dependency, significant operational complexity, and is designed for long-lived legal documents. For a pipeline where issues move in days, a simpler `key_id`-based transition window is sufficient.

## Decision

Entry Sentinel signs approval comments using **Ed25519** (Curve25519-based EdDSA).

The signed payload is the exact byte sequence:

```
issue:<github_numeric_id>\napproved:<ISO8601 timestamp>\nhash:sha256:<lowercase hex>\nkey_id:<key_id>\n
```

The signature is base64-encoded and stored in the approval comment. The private key is held in HashiCorp Vault. The public key and its `key_id` are published in the service registry.

**Rotation uses a `key_id` transition window, not RFC 3161 timestamps.** The service registry stores public keys with `effective_from` and `retired_until` date fields. During rotation, the new key is published and Entry Sentinel starts signing with it immediately; the old key remains in the registry until `retired_until` expires. Downstream verifiers look up the correct key by `key_id` from the approval comment and check it is within its validity window. No re-approval of all issues is required unless the transition window has lapsed.

## Consequences

- **Enables**: Any downstream service can verify approval independently using only the service registry and the public key identified by `key_id`; issue ID binding fully closes cross-issue replay; key rotation no longer invalidates all approved issues immediately — only those where the transition window has expired
- **Forbids**: Symmetric signing schemes (HMAC) that require sharing the secret key with verifiers; signature caching or key caching in memory beyond a single signing operation; omitting `key_id` from the signed payload
- **Trade-offs accepted**: After the transition window lapses, any issue with an approval signed by the retired key must be re-approved. The window is configurable (default 90 days); this is a much smaller operational burden than re-approving all issues on every rotation.

## Alternatives considered

- **HMAC-SHA256**: Simpler; no PKI. Rejected — symmetric: any downstream service holding the secret can also forge approvals. Sharing the key with all downstream services widens the attack surface.
- **RSA-2048**: Widely understood; supported everywhere. Rejected — 256-byte signatures are unnecessary for this use case; slower key generation; Ed25519 is strictly superior.
- **RSA-4096**: Even larger; no benefit over Ed25519 for this threat model.
- **No signing**: Simplest; removes all operational complexity. Rejected — without signing, any GitHub comment matching the format would be trusted. Trivially forgeable.
- **RFC 3161 TSA timestamps**: Would provide a cryptographic third-party proof that the signature existed before time T, allowing verifiers to accept signatures made before a key was retired without any transition window. Rejected — requires an external TSA service; adds significant operational and dependency complexity; designed for long-lived legal documents; the `key_id` transition window achieves the same practical goal for this use case with far less overhead.
- **Vault transit (server-side signing)**: The signing occurs within Vault, and the private key never leaves Vault. This is the preferred Vault integration pattern and should be the default implementation.

## Implementation notes

The `ApprovalSigner` component holds the Vault path for the Ed25519 private key. If using Vault transit (recommended), the component calls the Vault transit signing endpoint and receives the raw signature bytes — the private key never leaves Vault.

If Vault transit is not available, the component retrieves the raw private key bytes, performs local Ed25519 signing using the `ed25519-dalek` crate, and immediately drops the key from memory. The `ed25519-dalek` crate must be used in its `SigningKey`-based API (not the deprecated legacy API).

The `ed25519-dalek` crate provides constant-time verification, which mitigates timing attacks on downstream verification.

Key rotation procedure is documented in [specs/operations.md](../specs/operations.md).

## Examples

Approval comment format:

```
<!-- entry-sentinel
issue: 42
approved: 2026-04-15T10:23:44Z
hash: sha256:a3f2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2
key_id: es-2026-04-01
signature: <base64-encoded 64-byte Ed25519 signature>
-->
```

Signed payload (exact bytes, UTF-8):

```
issue:42\napproved:2026-04-15T10:23:44Z\nhash:sha256:a3f2b1c4...\nkey_id:es-2026-04-01\n
```

## References

- [specs/security.md — T-03 Approval Comment Tampering, T-04 Replay Attack, T-05 Key Compromise](../specs/security.md)
- [specs/vocabulary.md — ApprovalSignature, ApprovalPayload, KeyId](../specs/vocabulary.md)
- [specs/operations.md — Secret Rotation Procedure](../specs/operations.md)
- [RFC 8032 — Edwards-Curve Digital Signature Algorithm](https://www.rfc-editor.org/rfc/rfc8032)
