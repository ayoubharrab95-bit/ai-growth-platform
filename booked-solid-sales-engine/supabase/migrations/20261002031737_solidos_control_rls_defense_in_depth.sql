
alter table solidos_control.dead_letter enable row level security;
alter table solidos_control.dirty_companies enable row level security;
alter table solidos_control.health_events enable row level security;
alter table solidos_control.settings enable row level security;
alter table solidos_control.sheet_sync_requests enable row level security;

revoke all on solidos_control.dead_letter from public,anon,authenticated;
revoke all on solidos_control.dirty_companies from public,anon,authenticated;
revoke all on solidos_control.health_events from public,anon,authenticated;
revoke all on solidos_control.settings from public,anon,authenticated;
revoke all on solidos_control.sheet_sync_requests from public,anon,authenticated;
