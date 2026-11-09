# Internal current-session verification contract

This endpoint is for trusted backend services only. Do not call it from a mobile app or browser: verified raw contact values are returned to the authenticated backend caller.

## Request

`POST /internal/session/verify`

Headers:

- `Authorization: Bearer <user access token>` — the session being checked.
- `x-auth-service-secret: <shared backend secret>` — compare against `AUTH_INTERNAL_SERVICE_SECRET`, configured only in the auth and trusted backend environments. Use a randomly generated value of at least 32 bytes.

No request body is required. A missing/invalid service secret returns `401`; an unset/too-short secret returns `503`; a missing bearer token returns `400`.

## Response

Valid active member session:

```json
{
  "token_valid": true,
  "valid": true,
  "subject": "auth-user-uuid",
  "auth_proof": { "channel": "email", "verified_at": 1792600000 },
  "session": {
    "active": true,
    "revoked": false,
    "expires_at": "2026-10-21T12:00:00.000Z",
    "revocation": null
  },
  "verified_contacts": {
    "email": { "verified": true, "value": "person@example.com" },
    "phone": { "verified": false, "value": null }
  },
  "claimed_contacts": {
    "phone": { "claimed": true, "value": "+919876543210" }
  },
  "phone_gate": { "required": false, "satisfied": true }
}
```

`token_valid` reports signature and token-claim validity. `valid` and `session.active` additionally require a live, non-deleted account, matching token version, and an active device when the token is device-bound. For a cryptographically valid but revoked/inactive session, `token_valid` remains `true`, `valid` is `false`, and `session.revoked` is `true`. An invalid/expired token returns HTTP 200 with `token_valid: false`, `valid: false`, a null subject, and empty verified contacts. A backend/database verification failure returns `503` and must be treated as unavailable—not as proof that the user is signed out.

`claimed_contacts.phone` is a phone number the person typed in at sign-up. It is **not verified**: no code was sent to it, so never treat it as proof of anything and never put it in `verified_contacts`. It is non-null only for an active session. `phone_gate.required` is true when auth/ runs with `REQUIRE_PHONE_AT_SIGNUP=true`; `satisfied` is true when the account has a typed or a verified phone. When `required && !satisfied`, product services must refuse the request with 403 `phone_required` (api/ does this in `verifyMemberRequest` and `POST /profile`). A response that omits both fields (an older auth/) means "not required".

Raw email/phone values are non-null only when the session is active and the corresponding stored verified flag is true. The contact object is server-to-server data; never forward these values to an app response or logs. `auth_proof` is signed token metadata when available; older valid tokens can have null proof metadata while their verified-contact flags remain authoritative.

There are no guest sessions. `POST /auth/guest-login` was removed and any access token that still carries `is_guest: true` is rejected as an invalid token (`token_valid: false`). The `guest` field was removed from this response; services that still read it should treat a missing value as `false`.
