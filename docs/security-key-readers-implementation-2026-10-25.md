# Retained encryption readers — 25 October 2026

This P05 slice adds compatible readers and release inventory checks. **Existing writers, keys, lookup hashes and client contracts remain unchanged.** No live connection, rotation, backfill, schema migration, deployment or feature activation occurred. P05 and M10/W02 remain partial; all 22 scoped findings remain unfinished.

## Implemented contracts

| Data | Reader support | Default write behavior |
| --- | --- | --- |
| Phone fields | Optional named keys read the new `v2:keyId:iv:tag:ciphertext` format. AES-256-GCM authenticates the exact UTF-8 AAD prefix `pandapay-field-encryption-v2` followed by a NUL byte and the key ID. New envelopes require canonical padded base64, a 12-byte IV, 16-byte tag, nonempty ciphertext, valid UTF-8 and at most 4,096 encoded bytes. | The existing `iv:tag:ciphertext` writer still uses the original `ENCRYPTION_KEY`. There is no v2 write switch in this batch. Legacy phone plaintext/decryption behavior stays compatible. |
| Recovery wrapping | The stored `wrapping_key_id` selects exactly the active or a configured retained key. Existing 60-byte AES-GCM wraps and account/snapshot/key-ID AAD are unchanged; wrong, missing or unknown keys fail safely. | Manual and automatic uploads still use only the configured active wrapping key/ID. Client PDAR1 archives, OTP/consent/device checks and disabled defaults remain unchanged. |
| Release inputs | Optional `retainedReadKeyIds` registers a nonsecret escrow/version label for every configured reader ID. Configuration evidence includes those labels; malformed or unregistered lists fail the gate. | Omitted/empty registration keeps the prior configuration digest compatible. Metadata does not prove key-byte identity or independent custody. |

The new phone format does not bind a user/account ID; its AAD binds its format and key ID. Existing authorization, canonical phone lookup and ownership checks remain separate controls. Unversioned legacy phone ciphertext is decrypted **only** with the original `ENCRYPTION_KEY`, without trying retained keys. Keep that original key for current rows and retained backups.

Sources: [phone reader](../auth/src/utils/fieldEncryption.js), [manual recovery](../api/src/account_recovery_routes.js), [automatic recovery](../api/src/automatic_account_recovery.js), [release check](../db/scripts/release_security_check.js).

## Optional configuration and custody

- `ENCRYPTION_READ_KEYS_JSON`: versioned phone read keys.
- `ACCOUNT_RECOVERY_WRAPPING_READ_KEYS_JSON`: retained recovery unwrap keys, excluding the active wrapping ID.

Both accept a JSON array of two-element `[keyId, base64Key]` pairs: at most eight entries and 8,192 UTF-8 bytes. IDs match `[A-Za-z0-9_-]{1,64}` and are case-sensitive; keys are canonical padded base64 encoding exactly 32 bytes. Duplicate IDs, malformed values, object roots, extra pair fields, oversized lists and unsupported encodings fail. Array pairs and Maps avoid special object-property ambiguity. Undefined/null options, an empty environment string or `[]` mean no optional keys; whitespace-only strings are malformed configuration.

The production/staging examples leave both settings blank. Compose passes the phone list to auth and the migration job, and the wrapping list to the API. Recovery remains `false` by default. Local-off phone mode retains its explicit plaintext writer; configured v2 read keys can still read v2 data there. Hosted auth still requires encryption enabled and the original valid key.

Store actual lists only in protected runtime configuration and its encrypted recovery escrow. Never put key bytes, list JSON or real credentials in this file, release inputs, logs, chat or Git. Release registration contains only nonsecret IDs and labels, for example `retainedReadKeyIds.ENCRYPTION_READ_KEYS_JSON.<keyId> = <escrow-version-label>`. Provisioning and custody were not performed by this source batch. The [location-only index](security-secrets-inventory-2026-10-23.md) records this distinction.

Before any future write-format or active-key change, verify all service replicas and required restore/migration readers can read both generations. Recovery read lists exclude the active ID, so each rollout stage needs a consistent active key plus the other retained IDs. Preserve original keys and private escrow through the complete data/backup lifetime. Do not infer safe rotation from one successful local test. IMAP versioning, phone HMAC rotation and bounded backfill are still separate unfinished work.

## Verification

[Exact-source evidence](../artifacts/security-key-readers-2026-10-25/verification.json) records source/configuration hashes, commands and result scopes. Counts overlap.

| Check | Result / boundary |
| --- | --- |
| Sanitized full API | 988 passed; two existing database-dependent skips; 990 total |
| Sanitized full auth | 317 passed |
| Sanitized database-tool suite | 190 passed, including 22 cross-parser configuration-contract cases |
| Cached Node 22 containers | Recovery: 15/15; phone encryption: 9/9; read-only sanitized source, no network, exact image IDs recorded |
| Compose | Production/staging parsed with an empty env file and interpolation disabled; correct auth/migration/API passthrough and disabled recovery default verified |
| Synthetic PostgreSQL 18 | Actual escrow migration and runtime role: old snapshot read with retained key, missing key 503, cross-account 404, new uploads use active ID, old rows remain unchanged; dump/restore preserves snapshot IDs/bytes and both generations reopen |
| Protected original-key restore | Existing encrypted paired set restored into disposable RAM-backed PostgreSQL 17 with original keys. Application key/phone-index/account-identity verification passed; 357 product/10 auth read-only checks completed, zero checked FK orphans and zero v1 catalogue collisions |

Phone tests manufacture v2 ciphertext independently, check a known-ID substitution with identical key bytes to prove AAD binding, and preserve legacy wrong-key refusal without fallback. Recovery tests cover both primary and retained IDs, authenticated account/snapshot binding and safe responses. Independent reviews checked the API and release guard; coordinator review preserved the exact legacy UTF-8 behavior and strengthened AAD/padding cases before final verification.

The synthetic fixture proves same-major local PostgreSQL persistence/restore. The protected restore proves current legacy-key compatibility, without applying the pending upgrade or exercising real retained lists. Neither establishes a production rotation, intended-provider acceptance or a new phone's integrated mobile recovery. No app or dependency-lock change was needed, so Flutter/native release suites were not repeated.

## Remaining sequence

1. Complete private deployed key/custodian and required-reader inventory; preserve every original key and verify actual retained configuration across replicas and restore jobs.
2. Design compatible IMAP/key-ID and multi-generation phone-lookup support. HMAC digests are not decryptable and must not be rotated as a simple environment replacement.
3. Add separately gated new-format writes and bounded resumable compare-and-swap backfill/rewrap, with historical/account/contact reuse invariants and post-write repair proofs on a complete protected clone.
4. Accept target-provider, independent custody, full client/device and monitored rollout gates. Normal mobile DB/receipt integration remains P06–P09 work; this server-reader batch does not activate it.

[Implementation plan](security-data-dependency-mobile-documentation-plan-2026-10-25.md) · [All remaining gaps](security-focused-gap-review-2026-10-25.md) · [Previous execution batch](security-execution-implementation-2026-10-25.md)
