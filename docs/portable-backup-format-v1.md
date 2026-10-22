# PandaPay portable backup format v1

Status: contract draft frozen for Wave 1 implementation. Changes require parent integration approval.

## Scope

`.pandapay-backup` is an authenticated, passphrase-encrypted archive for the same PandaPay account. It is not a CSV/PDF report, statement import, SMS backup import, database dump, credential transfer or device clone.

## Canonical payload

The decrypted payload contains `manifest.json`, deterministic UTF-8 NDJSON sections, and attachment files. NDJSON uses LF line endings, snake_case keys, explicit nulls, lowercase UUID strings, canonical decimal strings for money, UTC RFC 3339 timestamps with preserved precision, deterministic field order and stable record order. Section SHA-256 digests cover exact plaintext bytes. Encryption output is randomized; unchanged backups are compared by decrypted canonical digests.

## Encryption envelope

The outer header exposes only magic, format version, KDF identifier/parameters, salt and streaming-AEAD header. The payload uses Argon2id and an audited XChaCha20-Poly1305 streaming AEAD binding selected by the parent after Android/iOS compatibility and cross-runtime vector tests. Account identifiers, card data, SMS data, section names, tokens and passphrases remain encrypted.

### Wire layout (implemented in `app/lib/data/portable_backup/portable_crypto.dart`)

Plaintext header, 68 bytes, little-endian nothing — every multi-byte field is big-endian:

| offset | size | field |
| ------ | ---- | ----- |
| 0      | 8    | magic `PDBK1` (5) + format version `0x01` (1) + 2 reserved zero bytes |
| 8      | 4    | plaintext chunk bytes per non-final frame, BE32 (v1 writes 65536; readers accept 4096..4194304) |
| 12     | 16   | Argon2id salt (random per backup) |
| 28     | 16   | KDF parameters: memoryKiB, parallelism, iterations, hashLength, each BE32 (v1: 16384 / 1 / 2 / 32) |
| 44     | 24   | base nonce: 19 random bytes + 5 zero counter bytes |

Frames follow the header. Each frame is `ciphertext || MAC(16)` and nothing else; the plaintext chunk size for non-final frames is the header chunk field, and the final frame carries the remainder (possibly smaller, never larger). AEAD parameters per frame:

- nonce: `baseNonce[0..18] || 5-byte big-endian frame counter`, exactly 24 bytes for XChaCha20.
- AAD: the full 68-byte plaintext header `||` 8-byte big-endian frame counter `||` one final-flag byte (`0x00`/`0x01`).
- Key: Argon2id(passphrase, salt=salt, memoryKiB/parallelism/iterations/hashLength from the header).

Failure semantics on decrypt: wrong passphrase or tampered bytes fail on the first AEAD open that covers them (`SecretBoxAuthenticationError` → passphrase error), truncation fails with "final frame missing" or "truncated final frame", trailing bytes after the final frame are rejected, magic/KDF mismatches fail before any key derivation. Cross-runtime test vectors are a Wave-1 acceptance item (blocked: recorded in the implementation-status doc).

## Required manifest fields

The manifest records format/schema versions, backup UUID, account binding, creation/snapshot times, app/server versions, completeness, server revision, section names, record counts, plaintext byte lengths, SHA-256 digests, attachment inventory, required capabilities and declared exclusions. Missing required sections, unknown required capabilities, count/digest mismatches, ownership mismatches and unsafe archive paths fail before mutation.

## Device exclusions

Tokens, secure-storage values, device/install ID, push token, biometric state, SMS provider cursor, platform permissions and local sync cursor are never portable. Historical PandaPay-captured SMS/provenance rows are portable and restored without re-running ingestion.

## Compatibility

Readers accept this version and explicitly supported older versions. They reject newer required schema/capability versions before mutation. The v1 implementation does not support cross-account migration, populated-target replacement/merge or complete offline export.
