-- >>> MIGRATION 0038 — CARD QUEUE PIPELINE ======================================
--
-- Adds the execution layer for the card crawler queue.
-- 
-- 1. `card_targets`: the registry of all known cards across India, decoupled from live products.
-- 2. `card_crawl_jobs`: state machine for jobs traversing (discover -> fetch -> extract -> normalize -> promote)

create table if not exists card_targets (
    id uuid primary key default gen_random_uuid(),
    issuer_name text not null,
    card_name text not null,
    card_key text not null unique,
    aliases jsonb not null default '[]'::jsonb,
    status text not null default 'pending' check (status in ('pending', 'mapped', 'crawlable', 'drafted', 'published', 'retired')),
    coverage_priority int not null default 100,
    notes text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_card_targets_issuer on card_targets (issuer_name);
create index idx_card_targets_status on card_targets (status);

create table if not exists card_crawl_jobs (
    id uuid primary key default gen_random_uuid(),
    card_target_id uuid references card_targets(id) on delete cascade,
    source_id uuid references sources(id) on delete cascade,
    source_page_id uuid references source_pages(id) on delete cascade,
    job_type text not null check (job_type in ('discover', 'fetch', 'extract', 'normalize', 'promote')),
    priority int not null default 100,
    state text not null default 'queued' check (state in ('queued', 'running', 'succeeded', 'failed', 'skipped')),
    attempts int not null default 0,
    next_run_at timestamptz not null default now(),
    last_error text,
    payload jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index idx_card_crawl_jobs_queue on card_crawl_jobs (state, next_run_at, priority desc);
create index idx_card_crawl_jobs_target on card_crawl_jobs (card_target_id);
create unique index if not exists idx_card_crawl_jobs_dedupe
    on card_crawl_jobs (
        card_target_id,
        coalesce(source_id, '00000000-0000-0000-0000-000000000000'::uuid),
        coalesce(source_page_id, '00000000-0000-0000-0000-000000000000'::uuid),
        job_type
    );

-- Create simple trigger for updated_at
create or replace function update_updated_at_column()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language 'plpgsql';

create trigger update_card_targets_updated_at
    before update on card_targets
    for each row execute procedure update_updated_at_column();

create trigger update_card_crawl_jobs_updated_at
    before update on card_crawl_jobs
    for each row execute procedure update_updated_at_column();
