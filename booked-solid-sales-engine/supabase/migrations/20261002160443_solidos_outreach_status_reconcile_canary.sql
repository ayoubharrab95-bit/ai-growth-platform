create or replace function solidos_control.reconcile_lead_outreach_status()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if current_setting('solidos.outreach_reconcile_canary',true) is distinct from 'on' then return new; end if;
  if lower(coalesce(new.status,'')) not in ('qualified','sent','replied','meeting','won') then
    update booked_solid.outreach_queue
    set status='cancelled', failure_reason='Lead no longer qualified: '||coalesce(new.status,'unknown')
    where lead_id=new.id and status in ('blocked_email_not_configured','ready');
  end if;
  return new;
end $$;
revoke all on function solidos_control.reconcile_lead_outreach_status() from public,anon,authenticated;
grant execute on function solidos_control.reconcile_lead_outreach_status() to service_role;
create trigger solidos_reconcile_lead_outreach_status
after update of status on booked_solid.leads for each row
execute function solidos_control.reconcile_lead_outreach_status();
