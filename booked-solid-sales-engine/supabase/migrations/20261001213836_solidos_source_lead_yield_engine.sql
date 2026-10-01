
create table if not exists booked_solid.source_lead_yield_snapshot (
  source_slug text primary key,
  sample_count integer not null default 0,
  rejected_count integer not null default 0,
  lead_count integer not null default 0,
  qualified_count integer not null default 0,
  hot_high_count integer not null default 0,
  lead_rate numeric not null default 0,
  qualified_rate numeric not null default 0,
  hot_high_rate numeric not null default 0,
  yield_score numeric not null default 0,
  discovery_tier text not null default 'testing',
  window_days integer not null default 7,
  updated_at timestamptz not null default now()
);

alter table booked_solid.source_lead_yield_snapshot enable row level security;

create or replace function booked_solid.refresh_source_lead_yield(p_days integer default 7)
returns jsonb
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
declare
  v_days integer:=greatest(1,least(coalesce(p_days,7),60));
  v_rows integer:=0;
begin
  with stats as (
    select
      coalesce(c.source_first_seen,'unknown') source_slug,
      count(*)::int sample_count,
      count(*) filter(where c.status='rejected')::int rejected_count,
      count(*) filter(where exists(select 1 from booked_solid.leads l where l.company_id=c.id))::int lead_count,
      count(*) filter(where exists(select 1 from booked_solid.leads l where l.company_id=c.id and l.status='qualified'))::int qualified_count,
      count(*) filter(where exists(
        select 1 from booked_solid.leads l
        where l.company_id=c.id and l.status='qualified'
          and lower(coalesce(l.priority_band,'')) in ('hot','high')
      ))::int hot_high_count
    from booked_solid.companies c
    where c.created_at>=now()-make_interval(days=>v_days)
    group by coalesce(c.source_first_seen,'unknown')
  ),
  scored as (
    select *,
      round(lead_count::numeric/nullif(sample_count,0),4) lead_rate,
      round(qualified_count::numeric/nullif(sample_count,0),4) qualified_rate,
      round(hot_high_count::numeric/nullif(sample_count,0),4) hot_high_rate,
      round(
        least(100,
          40*least(1,coalesce(lead_count::numeric/nullif(sample_count,0),0)/0.25) +
          45*least(1,coalesce(qualified_count::numeric/nullif(sample_count,0),0)/0.08) +
          15*least(1,coalesce(hot_high_count::numeric/nullif(sample_count,0),0)/0.03)
        ) * least(1,0.35 + sample_count::numeric/20),
        2
      ) yield_score,
      case
        when sample_count>=20 and lead_count=0 then 'exploration_only'
        when sample_count>=40 and lead_count::numeric/nullif(sample_count,0)<0.03 and qualified_count=0 then 'exploration_only'
        when sample_count>=5 and (
          lead_count::numeric/nullif(sample_count,0)>=0.15
          or qualified_count::numeric/nullif(sample_count,0)>=0.05
        ) then 'proven'
        else 'testing'
      end discovery_tier
    from stats
  )
  insert into booked_solid.source_lead_yield_snapshot(
    source_slug,sample_count,rejected_count,lead_count,qualified_count,hot_high_count,
    lead_rate,qualified_rate,hot_high_rate,yield_score,discovery_tier,window_days,updated_at
  )
  select source_slug,sample_count,rejected_count,lead_count,qualified_count,hot_high_count,
         lead_rate,qualified_rate,hot_high_rate,yield_score,discovery_tier,v_days,now()
  from scored
  on conflict(source_slug) do update set
    sample_count=excluded.sample_count,
    rejected_count=excluded.rejected_count,
    lead_count=excluded.lead_count,
    qualified_count=excluded.qualified_count,
    hot_high_count=excluded.hot_high_count,
    lead_rate=excluded.lead_rate,
    qualified_rate=excluded.qualified_rate,
    hot_high_rate=excluded.hot_high_rate,
    yield_score=excluded.yield_score,
    discovery_tier=excluded.discovery_tier,
    window_days=excluded.window_days,
    updated_at=excluded.updated_at;

  get diagnostics v_rows=row_count;

  update booked_solid.source_catalog s
  set metadata=coalesce(s.metadata,'{}'::jsonb) || jsonb_build_object(
    'lead_yield',jsonb_build_object(
      'sample',y.sample_count,
      'rejected',y.rejected_count,
      'leads',y.lead_count,
      'qualified',y.qualified_count,
      'hot_high',y.hot_high_count,
      'lead_rate',y.lead_rate,
      'qualified_rate',y.qualified_rate,
      'hot_high_rate',y.hot_high_rate,
      'score',y.yield_score,
      'tier',y.discovery_tier,
      'window_days',v_days,
      'updated_at',now()
    ),
    'discovery_tier',y.discovery_tier
  ),
  updated_at=now()
  from booked_solid.source_lead_yield_snapshot y
  where y.source_slug=s.slug;

  return jsonb_build_object(
    'ok',true,
    'window_days',v_days,
    'sources_updated',v_rows,
    'proven',(select count(*) from booked_solid.source_lead_yield_snapshot where discovery_tier='proven'),
    'testing',(select count(*) from booked_solid.source_lead_yield_snapshot where discovery_tier='testing'),
    'exploration_only',(select count(*) from booked_solid.source_lead_yield_snapshot where discovery_tier='exploration_only'),
    'at',now()
  );
end
$function$;

revoke all on function booked_solid.refresh_source_lead_yield(integer) from public,anon,authenticated;
grant execute on function booked_solid.refresh_source_lead_yield(integer) to service_role;

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-source-lead-yield-15m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-source-lead-yield-15m'));
  end if;
  perform cron.schedule(
    'solidos-source-lead-yield-15m',
    '2,17,32,47 * * * *',
    'select booked_solid.refresh_source_lead_yield(7);'
  );
end $$;
