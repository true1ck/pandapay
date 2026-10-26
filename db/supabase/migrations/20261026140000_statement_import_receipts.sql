-- I12 receipt prerequisite: preserve the original batch request identity and
-- response summary so a mobile continuation can safely resume after a lost
-- response. No raw source document or financial payload is stored here.
begin;

alter table public.statement_imports
  add column if not exists import_request_hash text,
  add column if not exists import_response_summary jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.statement_imports'::regclass
                   and conname='statement_imports_request_hash_check') then
    alter table public.statement_imports add constraint statement_imports_request_hash_check
      check (import_request_hash is null or import_request_hash ~ '^[0-9a-f]{64}$');
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.statement_imports'::regclass
                   and conname='statement_imports_response_summary_check') then
    alter table public.statement_imports add constraint statement_imports_response_summary_check
      check (import_response_summary is null or (
        jsonb_typeof(import_response_summary)='object'
        and import_response_summary - array['imported','pendingDuplicates','exactRetries'] = '{}'::jsonb
        and import_response_summary ?& array['imported','pendingDuplicates','exactRetries']
        and jsonb_typeof(import_response_summary->'imported')='number'
        and jsonb_typeof(import_response_summary->'pendingDuplicates')='number'
        and jsonb_typeof(import_response_summary->'exactRetries')='number'
        and (import_response_summary->>'imported')::numeric between 0 and 5000
        and (import_response_summary->>'pendingDuplicates')::numeric between 0 and 5000
        and (import_response_summary->>'exactRetries')::numeric between 0 and 5000
        and (import_response_summary->>'imported')::numeric
          + (import_response_summary->>'pendingDuplicates')::numeric
          + (import_response_summary->>'exactRetries')::numeric <= 5000
        and (import_response_summary->>'imported')::numeric=trunc((import_response_summary->>'imported')::numeric)
        and (import_response_summary->>'pendingDuplicates')::numeric=trunc((import_response_summary->>'pendingDuplicates')::numeric)
        and (import_response_summary->>'exactRetries')::numeric=trunc((import_response_summary->>'exactRetries')::numeric)
      ));
  end if;
end $$;

comment on column public.statement_imports.import_request_hash is
  'Optional SHA-256 of the canonical semantic POST /statement-imports request. Null on legacy rows and unkeyed summary-only imports; not a secret or anonymization mechanism.';
comment on column public.statement_imports.import_response_summary is
  'Original bounded response counters for exact keyed request replay. Stored atomically with its statement import; null for legacy rows.';

commit;
