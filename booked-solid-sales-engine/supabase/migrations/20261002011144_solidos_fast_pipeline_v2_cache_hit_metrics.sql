
alter table booked_solid.resolution_cache
  add column if not exists hit_count bigint not null default 0,
  add column if not exists last_hit_at timestamptz;

alter table booked_solid.source_query_cache
  add column if not exists hit_count bigint not null default 0,
  add column if not exists last_hit_at timestamptz;

create or replace function booked_solid.record_resolution_cache_hit(p_cache_key text)
returns void
language sql
security definer
set search_path=''
as $function$
  update booked_solid.resolution_cache
  set hit_count=hit_count+1,last_hit_at=now(),updated_at=now()
  where cache_key=p_cache_key and expires_at>now();
$function$;

create or replace function booked_solid.record_source_query_cache_hit(p_cache_key text)
returns void
language sql
security definer
set search_path=''
as $function$
  update booked_solid.source_query_cache
  set hit_count=hit_count+1,last_hit_at=now(),updated_at=now()
  where cache_key=p_cache_key and expires_at>now();
$function$;

revoke all on function booked_solid.record_resolution_cache_hit(text) from public,anon,authenticated;
revoke all on function booked_solid.record_source_query_cache_hit(text) from public,anon,authenticated;
grant execute on function booked_solid.record_resolution_cache_hit(text) to service_role;
grant execute on function booked_solid.record_source_query_cache_hit(text) to service_role;

create or replace function solidos_control.cache_snapshot()
returns jsonb
language sql
security definer
set search_path=''
as $function$
select jsonb_build_object(
  'at',now(),
  'resolution',jsonb_build_object(
    'active_entries',(select count(*) from booked_solid.resolution_cache where expires_at>now()),
    'hits_total',(select coalesce(sum(hit_count),0) from booked_solid.resolution_cache),
    'entries_hit',(select count(*) from booked_solid.resolution_cache where hit_count>0),
    'hits_1h',(select coalesce(sum(hit_count),0) from booked_solid.resolution_cache where last_hit_at>now()-interval '1 hour'),
    'last_hit_at',(select max(last_hit_at) from booked_solid.resolution_cache)
  ),
  'source_query',jsonb_build_object(
    'active_entries',(select count(*) from booked_solid.source_query_cache where expires_at>now()),
    'hits_total',(select coalesce(sum(hit_count),0) from booked_solid.source_query_cache),
    'entries_hit',(select count(*) from booked_solid.source_query_cache where hit_count>0),
    'hits_1h',(select coalesce(sum(hit_count),0) from booked_solid.source_query_cache where last_hit_at>now()-interval '1 hour'),
    'last_hit_at',(select max(last_hit_at) from booked_solid.source_query_cache)
  )
);
$function$;

revoke all on function solidos_control.cache_snapshot() from public,anon,authenticated;
grant execute on function solidos_control.cache_snapshot() to service_role;
