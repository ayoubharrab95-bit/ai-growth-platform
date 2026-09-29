create table if not exists booked_solid.runtime_settings (
 id boolean primary key default true,
 search_enabled boolean not null default false,
 email_enabled boolean not null default false,
 search_provider text not null default 'tavily',
 email_provider text,
 updated_at timestamptz not null default now()
);
insert into booked_solid.runtime_settings(id) values(true) on conflict(id) do nothing;
alter table booked_solid.runtime_settings enable row level security;

create or replace function booked_solid.claim_work(p_worker text)
returns setof booked_solid.work_queue
language plpgsql security definer
set search_path=booked_solid,public
as $$
begin
 return query
 update booked_solid.work_queue q
 set status='running',locked_at=now(),locked_by=p_worker,attempts=attempts+1,updated_at=now()
 where q.id=(select id from booked_solid.work_queue where status='pending' and available_at<=now() order by priority desc,created_at for update skip locked limit 1)
 returning q.*;
end $$;
revoke all on function booked_solid.claim_work(text) from public;
grant execute on function booked_solid.claim_work(text) to service_role;
