update booked_solid.source_catalog
set lifecycle_state='canary',
    updated_at=now()
where enabled
  and lifecycle_state='degraded'
  and coalesce(consecutive_errors,0)=0
  and last_success_at is not null
  and coalesce(nullif(metadata->>'cooldown_until','')::timestamptz,'epoch'::timestamptz)<=now();
