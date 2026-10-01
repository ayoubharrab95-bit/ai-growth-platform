create or replace function commercial_intel.package_hourly_versions()
returns jsonb
language plpgsql
security invoker
set search_path = commercial_intel, pg_catalog
as $$
declare
  p record;
  v_no bigint;
  v_total int;
  v_safe int;
  v_review int;
  v_checksum text;
  v_created int:=0;
begin
  for p in select id,slug from commercial_intel.products where status='active' loop
    if exists (
      select 1 from commercial_intel.dataset_versions
      where product_id=p.id and date_trunc('hour',snapshot_at)=date_trunc('hour',now())
    ) then
      continue;
    end if;

    select
      count(*) filter(where eligible),
      count(*) filter(where exportable),
      count(*) filter(where eligible and not exportable),
      md5(coalesce(string_agg(company_id::text || ':' || exportable::text || ':' || product_score::text, ',' order by company_id),''))
    into v_total,v_safe,v_review,v_checksum
    from commercial_intel.product_memberships
    where product_id=p.id;

    select coalesce(max(version_no),0)+1 into v_no
    from commercial_intel.dataset_versions where product_id=p.id;

    insert into commercial_intel.dataset_versions(
      product_id,version_no,snapshot_at,record_count,safe_record_count,review_record_count,
      schema_version,checksum,status,sheet_target_id,metadata
    )
    select p.id,v_no,now(),v_total,v_safe,v_review,1,v_checksum,'prepared',st.id,
      jsonb_build_object('product_slug',p.slug,'pii_export',false,'commercial_layer_version',1)
    from commercial_intel.sheet_targets st
    where st.product_id=p.id
    limit 1;

    v_created:=v_created+1;
  end loop;
  return jsonb_build_object('versions_created',v_created,'at',now());
end
$$;
