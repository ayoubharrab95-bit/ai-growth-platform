
create or replace function booked_solid.refresh_priority_yield_engine(p_days integer default 45)
returns jsonb
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
declare
  v_days integer:=greatest(7,least(coalesce(p_days,45),180));
  v_global_n integer:=0;
  v_global_hot integer:=0;
  v_global_high integer:=0;
  v_prior_hh numeric:=0.30;
  v_prior_hot numeric:=0.04;
  v_updated integer:=0;
begin
  select count(*)::int,
         count(*) filter(where lower(coalesce(priority_band,'standard'))='hot')::int,
         count(*) filter(where lower(coalesce(priority_band,'standard'))='high')::int
  into v_global_n,v_global_hot,v_global_high
  from booked_solid.leads
  where lower(status)='qualified'
    and updated_at>=now()-make_interval(days=>v_days);

  if v_global_n>0 then
    v_prior_hh:=(v_global_hot+v_global_high)::numeric/v_global_n;
    v_prior_hot:=v_global_hot::numeric/v_global_n;
  end if;

  with base as (
    select
      coalesce(s.slug,'') strategy_slug,
      coalesce(c.source_first_seen,'unknown') source_slug,
      coalesce(c.trade,'Unknown') trade,
      coalesce(nullif(c.metadata->>'search_market',''),nullif(c.metadata->>'geography',''),'Unknown') market,
      lower(coalesce(l.priority_band,'standard')) band,
      coalesce(l.opportunity_score,0)::numeric opportunity,
      coalesce(l.trigger_score,0)::numeric trigger_score
    from booked_solid.leads l
    join booked_solid.companies c on c.id=l.company_id
    left join booked_solid.search_strategies s on s.id=l.strategy_id
    where lower(l.status)='qualified'
      and l.updated_at>=now()-make_interval(days=>v_days)
  ),
  dims as (
    select 'strategy'::text dimension_type,strategy_slug dimension_key,band,opportunity,trigger_score from base where strategy_slug<>''
    union all select 'source',source_slug,band,opportunity,trigger_score from base
    union all select 'trade',trade,band,opportunity,trigger_score from base
    union all select 'market',market,band,opportunity,trigger_score from base
  ),
  agg as (
    select dimension_type,dimension_key,
      count(*)::int sample_count,
      count(*) filter(where band='hot')::int hot_count,
      count(*) filter(where band='high')::int high_count,
      count(*) filter(where band='signal')::int signal_count,
      count(*) filter(where band not in ('hot','high','signal'))::int standard_count,
      round(avg(opportunity),2) avg_opportunity,
      round(avg(trigger_score),2) avg_trigger
    from dims
    group by dimension_type,dimension_key
  ),
  scored as (
    select *,
      round((hot_count+high_count)::numeric/nullif(sample_count,0),4) hot_high_yield,
      round(hot_count::numeric/nullif(sample_count,0),4) hot_yield,
      round(
        100 * (
          0.78 * ((hot_count+high_count)+(v_prior_hh*8))/(sample_count+8) +
          0.22 * (hot_count+(v_prior_hot*8))/(sample_count+8)
        ),2
      ) yield_score
    from agg
  )
  insert into booked_solid.priority_yield_snapshot(
    dimension_type,dimension_key,sample_count,hot_count,high_count,signal_count,standard_count,
    hot_high_yield,hot_yield,avg_opportunity,avg_trigger,yield_score,updated_at
  )
  select dimension_type,dimension_key,sample_count,hot_count,high_count,signal_count,standard_count,
         hot_high_yield,hot_yield,avg_opportunity,avg_trigger,yield_score,now()
  from scored
  on conflict(dimension_type,dimension_key) do update set
    sample_count=excluded.sample_count,
    hot_count=excluded.hot_count,
    high_count=excluded.high_count,
    signal_count=excluded.signal_count,
    standard_count=excluded.standard_count,
    hot_high_yield=excluded.hot_high_yield,
    hot_yield=excluded.hot_yield,
    avg_opportunity=excluded.avg_opportunity,
    avg_trigger=excluded.avg_trigger,
    yield_score=excluded.yield_score,
    updated_at=excluded.updated_at;

  get diagnostics v_updated=row_count;

  delete from booked_solid.priority_yield_snapshot
  where updated_at<now()-interval '2 hours';

  update booked_solid.search_strategies s
  set
    performance_score=round(greatest(20,least(95,
      0.55*coalesce(s.performance_score,50) +
      0.45*(40+0.60*coalesce(py.yield_score,0))
    )),2),
    exploration_weight=case
      when py.sample_count<5 then greatest(coalesce(s.exploration_weight,1),1.6)
      when py.yield_score>=55 then greatest(1.0,least(coalesce(s.exploration_weight,1),1.25))
      when py.yield_score>=40 then greatest(0.9,least(coalesce(s.exploration_weight,1),1.15))
      else greatest(0.75,least(coalesce(s.exploration_weight,1),1.0))
    end,
    metadata=coalesce(s.metadata,'{}'::jsonb) || jsonb_build_object(
      'priority_yield',jsonb_build_object(
        'sample',py.sample_count,'hot',py.hot_count,'high',py.high_count,
        'hot_high_yield',py.hot_high_yield,'hot_yield',py.hot_yield,
        'avg_opportunity',py.avg_opportunity,'avg_trigger',py.avg_trigger,
        'score',py.yield_score,'window_days',v_days,'updated_at',now()
      ),
      'trade_priority_yield_score',coalesce((
        select tpy.yield_score
        from booked_solid.priority_yield_snapshot tpy
        where tpy.dimension_type='trade' and tpy.dimension_key=s.trade
      ),py.yield_score),
      'priority_yield_policy','v1_70_30'
    ),
    updated_at=now()
  from booked_solid.priority_yield_snapshot py
  where py.dimension_type='strategy' and py.dimension_key=s.slug;

  update booked_solid.source_catalog sc
  set metadata=coalesce(sc.metadata,'{}'::jsonb) || jsonb_build_object(
      'priority_yield_score',py.yield_score,
      'priority_yield_sample',py.sample_count,
      'priority_hot_high_yield',py.hot_high_yield,
      'priority_hot_yield',py.hot_yield,
      'priority_yield_updated_at',now()
    ),
    updated_at=now()
  from booked_solid.priority_yield_snapshot py
  where py.dimension_type='source' and py.dimension_key=sc.slug;

  update booked_solid.market_catalog mc
  set metadata=coalesce(mc.metadata,'{}'::jsonb) || jsonb_build_object(
      'priority_yield_score',py.yield_score,
      'priority_yield_sample',py.sample_count,
      'priority_hot_high_yield',py.hot_high_yield,
      'priority_hot_yield',py.hot_yield,
      'priority_yield_updated_at',now()
    ),
    updated_at=now()
  from booked_solid.priority_yield_snapshot py
  where py.dimension_type='market' and py.dimension_key=mc.display_name;

  return jsonb_build_object(
    'ok',true,'window_days',v_days,'dimensions_updated',v_updated,
    'global_qualified',v_global_n,'global_hot',v_global_hot,'global_high',v_global_high,
    'global_hot_high_yield',case when v_global_n>0 then round((v_global_hot+v_global_high)::numeric/v_global_n,4) else 0 end,
    'at',now()
  );
end
$function$;
