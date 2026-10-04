begin;

alter table statement_imports
  add column if not exists source_key text;

create unique index if not exists uq_statement_imports_source_key
  on statement_imports (profile_id, source_key)
  where source_key is not null;

comment on column statement_imports.source_key is
  'Client-computed SHA-256 of the local PDF bytes, wrapped in a server-side profile-scoped hash. Makes a retry/re-import idempotent without uploading the PDF.';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'transactions_statement_import_fk'
       and conrelid = 'transactions'::regclass
  ) then
    alter table transactions
      add constraint transactions_statement_import_fk
      foreign key (statement_import_id) references statement_imports(id) on delete set null;
  end if;
end $$;

commit;
