
revoke all on function solidos_control.capture_company_milestone() from public,anon,authenticated;
revoke all on function solidos_control.capture_lead_milestone() from public,anon,authenticated;
revoke all on function solidos_control.capture_contact_milestone() from public,anon,authenticated;

revoke all on table solidos_control.pipeline_milestones from public,anon,authenticated;
grant select on table solidos_control.pipeline_milestones to service_role;
