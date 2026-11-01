# Using the local PandaPay admin console

Prepared for the isolated local development stack on 1 November 2026. This does not activate or deploy a hosted administrator.

## Everyday use after initial activation

Double-click `PandaPay Admin.command` on the Desktop. It starts the existing local services if stopped, checks readiness including the TLS proxy, and opens `https://localhost:8443/` in Chrome. When sign-in is required, enter the approved admin email, verify the newest emailed code, and use the passkey or security key you registered. Existing valid browser sessions can resume through the gateway; expiry or logout requires normal sign-in again.

No enrollment grant file or assistant is needed for normal login. The private signing credential remains with your authenticator; the server stores its public key. Registration persists in the separate local database when you stop the application or restart the Mac. Services currently start through the shortcut, rather than automatically at login.

## Finish initial setup once

Browser-managed enrollment is enabled for this approved local owner. Open `PandaPay Admin.command`, verify a fresh email code, and click Register security key. The portal creates its temporary grant internally; there is no 43-character code or file to copy. Chrome asks you to confirm registration on your chosen authenticator. Finish within two minutes of requesting the email code. The temporary proof is consumed by a successful registration, so verify a fresh email code for the second key.

`PandaPay Admin Setup.command` still shows the owner state and registered key count, and provides these actions:

1. **Register primary key in the portal.** Opens Chrome for the email-code and passkey flow above.
2. **Register independent backup key in the portal.** Opens the same flow with a separate authenticator. Reusing a synced copy of the primary credential does not establish an independent backup. The server chooses the missing initial slot and replaces earlier unused internal grants when retrying.
3. **Review and activate the local owner.** Once both credentials are registered, review the exact local activation plan printed by the canonical CLI. Type `ACTIVATE` only after checking the identity, local target, owner role and independent authenticators. The helper applies that same plan hash, records the result, and confirms the principal is enabled. It does not activate automatically.

After activation, use the everyday shortcut. The setup helper refuses to issue initial enrollment grants for an enabled account. Registered credentials, membership and server sessions remain subject to the gateway's existing checks; this helper adds no OTP-only or alternate web provisioning route.

## Files and recovery

The shortcut files contain only the path to the local helper. Protected maintenance configuration, historical manual grant files and activation receipts remain outside Git under `$HOME/.config/pandapay-admin/local-dev/`. Those manual files and `active-enrollment.json` are unnecessary for the currently enabled browser-managed flow. Internal grants are single use and expire after ten minutes, independently of the shorter email sign-in window. Operator approval remains in the completed maintenance journal; the gateway has no access to create or approve that intent.

If registration times out while the account remains pending, request a fresh email code in the portal and retry registration. No manual grant renewal is needed. If activation is interrupted, retain `owner-enable-plan.json` and `owner-enable-result.json` and follow the canonical status/resume procedure in the [operator runbook](../deploy/admin/RUNBOOK.md); do not regrant or reset the account to retry activation.

If the primary key is unavailable, use the registered independent backup. Loss of all authenticators requires the reviewed maintenance/recovery process; there is no implemented self-service factor reset.

Read-only local status, without opening Chrome or changing the clipboard:

```sh
python3 "$HOME/.config/pandapay-admin/local-dev/admin_tools.py" status
python3 "$HOME/.config/pandapay-admin/local-dev/manage.py" status
```

The local helper has ten isolated tests covering the managed portal path, target refusal, legacy grant handling, secret-free output, disabled enrollment after activation, missing factors, cancelled approval, exact plan/hash reuse and interrupted activation. The helper's clipboard and Chrome actions were mocked in tests; actual owner enrollment and authenticated acceptance remain interactive.
