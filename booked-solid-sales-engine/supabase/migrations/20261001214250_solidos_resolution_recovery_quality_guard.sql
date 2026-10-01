
create or replace function booked_solid.enqueue_resolution_recovery(p_limit integer default 8)
returns jsonb
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
declare
  r record;
  v_limit integer:=greatest(1,least(coalesce(p_limit,8),25));
  v_queued integer:=0;
begin
  for r in
    select c.id,c.trade,c.metadata,c.source_first_seen,
           coalesce(y.discovery_tier,'testing') discovery_tier,
           coalesce(y.yield_score,0) yield_score,
           coalesce(y.lead_rate,0) lead_rate
    from booked_solid.companies c
    left join booked_solid.source_lead_yield_snapshot y on y.source_slug=c.source_first_seen
    where c.status='rejected'
      and c.created_at>now()-interval '7 days'
      and coalesce(c.metadata->>'preflight_status','') in (
        'overpass_bypassed_degraded_source',
        'overpass_unavailable',
        'geocoder_no_match'
      )
      and (
        coalesce(y.discovery_tier,'testing')='proven'
        or (
          coalesce(y.discovery_tier,'testing')='testing'
          and (coalesce(y.yield_score,0)>=40 or coalesce(y.lead_rate,0)>=0.10)
        )
      )
      and coalesce((c.metadata->>'resolution_recovery_attempts')::int,0)<2
      and (
        nullif(c.metadata->>'resolution_recovery_last_at','') is null
        or (c.metadata->>'resolution_recovery_last_at')::timestamptz<now()-interval '12 hours'
      )
      and not exists(
        select 1 from booked_solid.work_queue q
        where q.kind='resolve' and q.status in ('pending','running')
          and q.payload->>'company_id'=c.id::text
      )
    order by
      case coalesce(y.discovery_tier,'testing') when 'proven' then 1 else 2 end,
      coalesce(y.yield_score,0) desc,
      c.created_at desc
    limit v_limit
  loop
    update booked_solid.companies
    set status='discovered',
        metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
          'resolution_recovery_attempts',coalesce((metadata->>'resolution_recovery_attempts')::int,0)+1,
          'resolution_recovery_last_at',now(),
          'resolution_recovery_state','queued',
          'resolution_recovery_policy','lead_yield_v2'
        ),
        updated_at=now()
    where id=r.id;

    insert into booked_solid.work_queue(kind,priority,payload,status,available_at)
    values(
      'resolve',
      case when r.discovery_tier='proven' then 88 else 80 end,
      jsonb_build_object(
        'company_id',r.id,
        'trade',r.trade,
        'geography',coalesce(nullif(r.metadata->>'search_market',''),nullif(r.metadata->>'geography',''),'US'),
        'location_text',coalesce(nullif(r.metadata->>'source_market',''),nullif(r.metadata->>'search_market',''),nullif(r.metadata->>'geography','')),
        'reason','lead_yield_resolution_recovery',
        'source_slug',r.source_first_seen,
        'source_yield_score',r.yield_score,
        'source_lead_rate',r.lead_rate,
        'source_tier',r.discovery_tier
      ),
      'pending',now()
    )
    on conflict do nothing;

    v_queued:=v_queued+1;
  end loop;

  return jsonb_build_object('ok',true,'queued',v_queued,'limit',v_limit,'policy','lead_yield_v2','at',now());
end
$function$;
