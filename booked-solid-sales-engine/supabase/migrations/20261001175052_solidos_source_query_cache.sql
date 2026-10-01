
create table if not exists booked_solid.source_query_cache (
  cache_key text primary key,
  source_slug text not null,
  payload jsonb not null default '{}'::jsonb,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists source_query_cache_expiry_idx
on booked_solid.source_query_cache (expires_at);

alter table booked_solid.source_query_cache enable row level security;
revoke all on booked_solid.source_query_cache from anon,authenticated;
grant select,insert,update,delete on booked_solid.source_query_cache to service_role;
