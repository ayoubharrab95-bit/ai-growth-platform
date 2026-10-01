
insert into booked_solid.resolution_cache(
  cache_key,normalized_name,location_key,domain,url,method,confidence,verified_at,expires_at,metadata,updated_at
)
select
  trim(regexp_replace(lower(coalesce(c.name,'')),'[^a-z0-9]+',' ','g')) || '|' ||
  trim(regexp_replace(lower(coalesce(
    nullif(c.metadata->>'source_market',''),
    nullif(c.metadata->>'search_market',''),
    nullif(c.metadata->>'geography',''),
    c.state,
    ''
  )),'[^a-z0-9]+',' ','g')) as cache_key,
  trim(regexp_replace(lower(coalesce(c.name,'')),'[^a-z0-9]+',' ','g')),
  trim(regexp_replace(lower(coalesce(
    nullif(c.metadata->>'source_market',''),
    nullif(c.metadata->>'search_market',''),
    nullif(c.metadata->>'geography',''),
    c.state,
    ''
  )),'[^a-z0-9]+',' ','g')),
  c.canonical_domain,
  coalesce(c.website_url,'https://'||c.canonical_domain||'/'),
  coalesce(c.metadata->>'resolved_via','seed_verified_domain'),
  greatest(75,coalesce((c.metadata->>'resolution_confidence')::numeric,80)),
  now(),
  now()+interval '7 days',
  jsonb_build_object('seeded_from_company_id',c.id,'seeded_at',now()),
  now()
from booked_solid.companies c
where c.canonical_domain is not null
  and c.website_url is not null
  and c.status<>'rejected'
  and coalesce(c.metadata->>'identity_status','domain_verified') in ('domain_verified','verified','resolved')
  and length(trim(regexp_replace(lower(coalesce(c.name,'')),'[^a-z0-9]+',' ','g')))>2
on conflict(cache_key) do update set
  domain=excluded.domain,
  url=excluded.url,
  confidence=greatest(booked_solid.resolution_cache.confidence,excluded.confidence),
  expires_at=greatest(booked_solid.resolution_cache.expires_at,excluded.expires_at),
  updated_at=now();

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-worker-lanes-1m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-worker-lanes-1m'));
  end if;

  perform cron.schedule(
    'solidos-worker-lanes-1m',
    '* * * * *',
    $cron$
    with base as (
      select
        (select count(*) from booked_solid.work_queue
          where status='pending' and available_at<=now()
            and booked_solid.work_lane(kind,priority,payload)='fast')::int fast_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind='qualify')::int qualify_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind='research')::int research_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind='resolve')::int resolve_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind in ('contact','message'))::int contact_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind in ('discover','location'))::int discovery_due,
        (select count(*) from booked_solid.work_queue where status='running')::int running_now
    ),
    lanes as (
      select * from (values
        (1,'fast'),(2,'qualify'),(3,'research'),(4,'resolve'),(5,'contact'),(6,'discovery')
      ) v(ord,lane)
    ),
    desired as (
      select l.ord,l.lane,b.running_now,
        case l.lane
          when 'fast' then least(3,case when b.fast_due>0 then greatest(1,ceil(b.fast_due/2.0)::int) else 0 end)
          when 'qualify' then least(3,case when b.qualify_due>0 then greatest(1,ceil(b.qualify_due/2.0)::int) else 0 end)
          when 'research' then least(2,case when b.research_due>0 then greatest(1,ceil(b.research_due/2.0)::int) else 0 end)
          when 'resolve' then least(3,case when b.resolve_due>0 then greatest(1,ceil(b.resolve_due/3.0)::int) else 0 end)
          when 'contact' then least(1,case when b.contact_due>0 then 1 else 0 end)
          when 'discovery' then case when b.discovery_due>4 then 3 when b.discovery_due>1 then 2 when b.discovery_due=1 then 1 else 0 end
          else 0
        end::int desired_n
      from lanes l cross join base b
    ),
    alloc as (
      select d.*,
        greatest(
          0,
          least(
            d.desired_n,
            greatest(0,12-d.running_now)
            - coalesce(sum(d.desired_n) over(order by d.ord rows between unbounded preceding and 1 preceding),0)
          )
        )::int n
      from desired d
    )
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-worker',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := jsonb_build_object('source','solidos-lane-cron','batch_size',1,'lane',a.lane),
      timeout_milliseconds := 45000
    ) as request_id
    from alloc a
    cross join lateral generate_series(1,a.n)
    where a.n>0;
    $cron$
  );
end $$;
