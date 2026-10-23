# Future merchant rule actions

`user_merchant_category_rules.action` is an explicit discriminator:

- `category` (the default) assigns `category_id` and optional `user_category_id`.
- `flag` stores a validated, opaque action key in `flag`.

Existing rows remain category rules because the migration defaults `action` to
`category`. A rule cannot carry both a category target and a flag target.

The repository currently does **not** define a transaction-level boolean flag.
`transactions.status` is an accounting lifecycle (`active`, `ignored`,
`reversed`, `deleted`), and the transaction detail flag icon creates a support
report. Future rule evaluation must therefore never change status or create a
support report as a side effect. A product-specific flag materializer must be
chosen before an importer applies `action = 'flag'`; until then the action is
stored and surfaced explicitly, while category resolution ignores flag-only
rules.

Both actions preserve the existing future-only invariant: creating, changing,
enabling, or disabling a rule never rewrites historical transactions.
