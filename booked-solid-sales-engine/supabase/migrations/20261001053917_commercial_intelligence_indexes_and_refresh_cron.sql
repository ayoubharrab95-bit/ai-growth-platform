
create index if not exists buyer_matches_product_id_idx
  on commercial_intel.buyer_matches(product_id);
create index if not exists dataset_versions_sheet_target_id_idx
  on commercial_intel.dataset_versions(sheet_target_id);
create index if not exists product_memberships_company_id_idx
  on commercial_intel.product_memberships(company_id);
create index if not exists sheet_targets_product_id_idx
  on commercial_intel.sheet_targets(product_id);

select cron.schedule(
  'commercial-intel-refresh-15m',
  '7,22,37,52 * * * *',
  $$select commercial_intel.refresh_layer();$$
);
;
