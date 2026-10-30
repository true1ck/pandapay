# Private admin protocol v1

The implementation plan defines HTTP bodies, expiry values and permission rules. `routes.json` is generated from the private API registration policy and copied into the gateway package; `node scripts/sync_admin_contracts.js --check` must pass before release. Never edit the two copies independently.

`session.schema.json` describes the credential-free internal introspection response. Actor authority comes from a current opaque token lookup; a JSON shape alone is never proof of identity. HTTP callers supply `X-Admin-Protocol: 1` and `X-Console-Request: 1`; mutations also require exact Origin and a valid session CSRF token. Protocol responses never expose an upstream access token.

The implementation uses dedicated `admin_private` auth state because legacy `console_private` browser sessions are deliberately excluded from the privileged protocol. The public auth listener never mounts the legacy gateway. Old records cannot be upgraded into admin authority.

Pinned locally bundled WebAuthn packages: server 14.0.3; browser 14.0.0. The browser bundle is copied from its npm tarball with its license, not downloaded by the installed UI. Replacing either package requires lockfile and asset review plus the complete login/enrollment tests.
