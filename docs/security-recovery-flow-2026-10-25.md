# Account data recovery: user flow and examples

25 October 2026 (IST). This describes the opt-in source implementation. **The feature is disabled for production pending release acceptance.** No extra user password or recovery-key file is required.

## Two different recovery needs

| Situation | Recovery mechanism | What it preserves |
| --- | --- | --- |
| User loses/replaces a phone | Existing phone/email OTP plus an encrypted account recovery copy | Account-scoped local records, pending unsynced changes and explicitly included receipt files captured by a successful copy |
| Database host fails or PostgreSQL moves to a different provider | Operator restores the complete paired encrypted PostgreSQL backups and original application keys | Product/auth database contents, UUID links, history, schema and recorded encryption metadata at the backup point |

OTP establishes access to the account. It cannot recreate a file or expense that existed only on the lost phone and was never successfully uploaded. Normal database-synced records remain available through ordinary account access.

## Flow on the original phone

1. The signed-in user opens Account data recovery and agrees to include their account data and pending changes. Receipt files have a separate opt-in.
2. They tap **Enable automatic recovery updates**. The existing phone/email OTP flow supplies recent verification when needed; no additional password is introduced.
3. The service records consent for the current active device. New devices are not automatically enrolled. Enrolling beyond eight devices pauses the oldest device's automatic enrollment without deleting its saved copies/history.
4. When the app is open, active and online, it attempts updates at 15-minute intervals. It skips unchanged content after a previously verified copy. Failures back off; no background OTP prompt or retry storm is introduced. Closed-app/OS background execution and an exact recovery time are not guaranteed.
5. The app captures an account-isolated consistent snapshot, encrypts it, uploads it and verifies the returned ciphertext using its current archive key. Automatic endpoints never return escrowed archive keys.
6. Existing storage bounds remain: at most two copies per account, a 5 MiB archive limit, account cooldown and global database quota. A full/quota-limited copy fails without deleting local records; receipt-heavy accounts may exceed this size and need a later storage policy before activation.

Stopping automatic recovery on this device preserves existing copies. **Discard saved recovery copies** revokes all automatic devices and removes the server copies together, preventing another device from immediately recreating them. Re-enabling creates a new consent generation and a new copy even when the local content is unchanged.

## Flow on a replacement phone

1. The user follows the existing phone/email sign-in flow, including the existing masked-email hint where applicable.
2. After existing OTP verification, the app can offer available recovery copies before publishing the sign-in session.
3. The user explicitly chooses a copy to restore. The service checks recent verification, the current account/session and ownership before releasing that copy's recovery key.
4. The app decrypts and validates the archive, then restores into a **fresh local account**. It refuses to replace existing local history. Pending mutation UUIDs and included receipt bytes are preserved.
5. The user continues signing in and normal sync can process pending work. Enabling automatic updates on this replacement device requires its own explicit consent.

## Concrete examples

**Successful recovery:** At 10:00 the user enters a ₹500 expense and adds a receipt. At 10:15 an encrypted copy uploads and verifies. At 11:00 the phone is lost. The user signs in on another phone using existing OTP and restores that copy, including the expense and receipt if receipt inclusion was enabled.

**Work never reached the server:** At 10:00 the user enters an expense while offline. The phone is lost at 10:05 before any successful recovery update or normal sync. Sign-in restores account access and earlier saved/synced data, but that new phone-only expense cannot be recovered.

**Online is not a guarantee:** Internet returns but the app remains closed, the OS blocks execution, the snapshot exceeds its limit or storage is full. No successful copy is implied. The recovery point is the last verified copy, not the time internet returned.

**Hosting migration:** The operator restores the complete product/auth PostgreSQL pair and retains the original phone, lookup and recovery-wrapping keys. Hosted recovery ciphertext/metadata migrates with the database. Local unsaved phone data still requires a successful account recovery copy. Current local backup storage remains one physical Mac; independent recovery custody is still a release gate.

## Security and implementation limits

Encryption protects the stored archive. The service retains wrapped recovery keys so a user can recover using existing OTP; this is not end-to-end encryption against the service operator. Key downloads and restoration retain the fresh-factor requirement; durable device consent authorizes only automatic upload and ciphertext verification.

Production activation still requires signed Android/iOS upgrade/reinstall, missing-key/locked-device/account-switch tests, quota/provider acceptance and the complete local-storage migration matrix. The prototype does not mean that existing on-device SQLite or receipt files have already been encrypted.
