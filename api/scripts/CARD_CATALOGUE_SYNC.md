# CardPipeline catalogue sync

`sync_card_catalogue.sh` is the repeatable path from the sibling
`CardPipeline` project's accepted JSON outputs to PandaPay's PostgreSQL card
catalogue.

It performs two stages:

1. `collect_card_pipeline.js` reads `CardPipeline/data/checklist.json`, takes
   only rows marked `done`, resolves each row's accepted run output, and writes
   an atomically replaced `all-collected.json` plus its positional index.
2. `import_card_pipeline.js` validates and maps each record, then writes the
   card and its rule families in one transaction per card.

Every imported card is a `draft`. Neither script publishes cards or writes
`verified_at`/`verified_by`.

After a human has reviewed and explicitly approved an exact collected input,
`publish_card_pipeline.js` is the repeatable publication step. It refuses any
row whose database import hash or transform version differs from that input,
uses the normal `draft -> in_review -> published` state machine, and writes an
`admin_audit_log` row for every transition. Run `--dry-run` first; it executes
the database constraints and rolls each card back.

## One-time setup

Apply database migrations through `0043_card_product_network_variants.sql`. The
normal production deploy applies it automatically; a direct run fails before
writing anything if the migration is missing.

Set a database URL using the first available variable:

- `DATABASE_URL`
- `API_DATABASE_URL` (the production compose name and preferred app role)
- `ADMIN_DATABASE_URL` (privileged operator fallback)

Set `CARD_IMPORT_ADMIN_ID` to an active `admin_users.id`, or pass
`--admin-id`. This identity is used for RLS and `admin_audit_log`.

## Run it

From anywhere:

```bash
CARD_IMPORT_ADMIN_ID=<admin-uuid> \
  api/scripts/sync_card_catalogue.sh --dry-run
```

Review the collect/import reports under `api/scripts/.staging/`, then run the
real import:

```bash
CARD_IMPORT_ADMIN_ID=<admin-uuid> \
  api/scripts/sync_card_catalogue.sh
```

Then, only after explicit approval of that exact staged JSON:

```bash
CARD_IMPORT_ADMIN_ID=<admin-uuid> \
  node api/scripts/publish_card_pipeline.js \
    --input api/scripts/.staging/all-collected.json \
    --dry-run

CARD_IMPORT_ADMIN_ID=<admin-uuid> \
  node api/scripts/publish_card_pipeline.js \
    --input api/scripts/.staging/all-collected.json
```

The default pipeline path is the sibling
`/Users/chandresh_kerkar/Documents/PandaPath/CardPipeline`. Override it on
another machine with `--pipeline /path/to/CardPipeline`.

## Ongoing extraction

Run the same command whenever more checklist rows reach `done`. Each source
record is stored with a canonical SHA-256 fingerprint:

- new card: inserted as `draft`;
- changed draft: refreshed transactionally;
- unchanged card: no database writes and no `data_version` bump;
- changed `in_review`/`published` card: left untouched and reported;
- `--force`: deliberately refreshes a reviewed card, but still never
  publishes it.

The source hash is paired with an importer transform version. When mapping
logic changes, incrementing that version rebuilds existing drafts even if the
JSON did not change; reviewed/published cards are still left untouched.

The importer also takes a database advisory lock, so two sync jobs cannot
interleave. Database failures produce a non-zero exit code; invalid source
records are skipped and listed for review without blocking valid cards.

`--include-unlisted` exists for recovery only. It imports successful run files
that the authoritative checklist has not marked done and weakens the
independent name-mismatch check, so normal scheduled runs should not use it.
