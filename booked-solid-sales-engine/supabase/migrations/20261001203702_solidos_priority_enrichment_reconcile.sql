
create or replace function booked_solid.reconcile_priority_enrichment_log()
returns jsonb
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
declare
  v_count integer:=0;
begin
  update booked_solid.priority_enrichment_log pe
  set
    last_completed_at=coalesce(pe.last_completed_at,now()),
    after_band=l.priority_band,
    after_opportunity=l.opportunity_score,
    after_trigger=l.trigger_score,
    status=case
      when pe.target_band='hot' and lower(coalesce(l.priority_band,''))='hot' then 'promoted'
      when pe.target_band='high' and lower(coalesce(l.priority_band,'')) in ('high','hot') then 'promoted'
      else 'completed'
    end,
    last_reason=case
      when pe.target_band='hot' and lower(coalesce(l.priority_band,''))='hot' then 'priority_threshold_reached'
      when pe.target_band='high' and lower(coalesce(l.priority_band,'')) in ('high','hot') then 'priority_threshold_reached'
      else 'priority_enrichment_reconciled'
    end,
    metadata=coalesce(pe.metadata,'{}'::jsonb)||jsonb_build_object('reconciled_at',now()),
    updated_at=now()
  from booked_solid.leads l
  where l.id=pe.lead_id
    and pe.status='queued'
    and pe.last_queued_at<now()-interval '5 minutes'
    and not exists(
      select 1 from booked_solid.work_queue q
      where q.status in ('pending','running')
        and q.kind in ('research','qualify')
        and q.payload->>'company_id'=pe.company_id::text
    );

  get diagnostics v_count=row_count;
  return jsonb_build_object('ok',true,'reconciled',v_count,'at',now());
end
$function$;

create or replace function booked_solid.run_priority_yield_cycle(p_limit integer default 6)
returns jsonb
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
declare
  v_reconcile jsonb;
  v_enqueue jsonb;
begin
  v_reconcile:=booked_solid.reconcile_priority_enrichment_log();
  v_enqueue:=booked_solid.enqueue_priority_yield_enrichment(p_limit);
  return jsonb_build_object('ok',true,'reconcile',v_reconcile,'enqueue',v_enqueue,'at',now());
end
$function$;

revoke all on function booked_solid.reconcile_priority_enrichment_log() from public,anon,authenticated;
revoke all on function booked_solid.run_priority_yield_cycle(integer) from public,anon,authenticated;
grant execute on function booked_solid.reconcile_priority_enrichment_log() to service_role;
grant execute on function booked_solid.run_priority_yield_cycle(integer) to service_role;

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-priority-enrichment-10m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-priority-enrichment-10m'));
  end if;
  perform cron.schedule(
    'solidos-priority-enrichment-10m',
    '3,13,23,33,43,53 * * * *',
    'select booked_solid.run_priority_yield_cycle(6);'
  );
end $$;
