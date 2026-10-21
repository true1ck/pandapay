-- Shared, atomic invitation-preview throttling for multiple API processes.
-- The API stores only a keyed fingerprint of the source IP, never the IP.

create table promotions.invitation_validation_limits (
  client_fingerprint text primary key
    check (client_fingerprint ~ '^[a-f0-9]{64}$'),
  window_started_at timestamptz not null default now(),
  request_count smallint not null default 1 check (request_count > 0),
  updated_at timestamptz not null default now()
);

alter table promotions.invitation_validation_limits enable row level security;
alter table promotions.invitation_validation_limits force row level security;
create policy invitation_validation_limits_owner
  on promotions.invitation_validation_limits
  for all to promotions_owner using (true) with check (true);

create or replace function promotions.consume_invitation_validation(p_client_fingerprint text)
returns boolean
language plpgsql volatile security definer
set search_path = pg_catalog, promotions
as $$
declare
  v_count smallint;
begin
  if p_client_fingerprint is null or p_client_fingerprint !~ '^[a-f0-9]{64}$' then
    return false;
  end if;

  insert into promotions.invitation_validation_limits
    (client_fingerprint, window_started_at, request_count, updated_at)
  values (p_client_fingerprint, now(), 1, now())
  on conflict (client_fingerprint) do update set
    window_started_at = case
      when promotions.invitation_validation_limits.window_started_at <= now() - interval '10 minutes'
      then now()
      else promotions.invitation_validation_limits.window_started_at
    end,
    request_count = case
      when promotions.invitation_validation_limits.window_started_at <= now() - interval '10 minutes'
      then 1
      else least(promotions.invitation_validation_limits.request_count + 1, 32767)
    end,
    updated_at = now()
  returning request_count into v_count;

  return v_count <= 20;
end
$$;

revoke execute on all functions in schema promotions from public;
grant execute on function promotions.consume_invitation_validation(text) to app_user;
