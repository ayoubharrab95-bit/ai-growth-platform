
create table if not exists booked_solid.resolution_cache (
  cache_key text primary key,
  normalized_name text not null,
  location_key text,
  domain text not null,
  url text not null,
  method text,
  confidence numeric not null default 0,
  verified_at timestamptz not null default now(),
  expires_at timestamptz not null,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table booked_solid.resolution_cache enable row level security;
create index if not exists resolution_cache_expires_idx
  on booked_solid.resolution_cache(expires_at);

create or replace function solidos_control.work_queue_dedupe_before_insert()
returns trigger
language plpgsql
set search_path=''
as $function$
declare
  v_company text:=nullif(new.payload->>'company_id','');
  v_lead text:=nullif(new.payload->>'lead_id','');
begin
  if new.status not in ('pending','running') then return new; end if;

  if new.kind in ('resolve','research','qualify','contact') and v_company is not null then
    if exists(
      select 1 from booked_solid.work_queue q
      where q.kind=new.kind
        and q.status in ('pending','running')
        and q.payload->>'company_id'=v_company
    ) then
      return null;
    end if;
  elsif new.kind='message' and v_lead is not null then
    if exists(
      select 1 from booked_solid.work_queue q
      where q.kind='message'
        and q.status in ('pending','running')
        and q.payload->>'lead_id'=v_lead
    ) then
      return null;
    end if;
  end if;

  return new;
end
$function$;

drop trigger if exists solidos_work_queue_dedupe_insert on booked_solid.work_queue;
create trigger solidos_work_queue_dedupe_insert
before insert on booked_solid.work_queue
for each row execute function solidos_control.work_queue_dedupe_before_insert();

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-cache-cleanup-daily') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-cache-cleanup-daily'));
  end if;
  perform cron.schedule(
    'solidos-cache-cleanup-daily',
    '23 4 * * *',
    'delete from booked_solid.resolution_cache where expires_at<now(); delete from booked_solid.source_query_cache where expires_at<now();'
  );
end $$;
