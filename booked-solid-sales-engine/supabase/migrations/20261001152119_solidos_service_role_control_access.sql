grant usage on schema solidos_control to service_role;
grant select,insert,update,delete on solidos_control.dirty_companies to service_role;
grant select,insert,update on solidos_control.sheet_sync_requests to service_role;
grant usage,select on sequence solidos_control.sheet_sync_requests_id_seq to service_role;
grant execute on function solidos_control.mark_company_dirty(uuid,text,numeric) to service_role;
grant execute on function solidos_control.request_sheet_sync(text,text,jsonb) to service_role;
