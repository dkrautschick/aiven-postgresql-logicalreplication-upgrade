#!/usr/bin/env bash
# Step 1: create the two Aiven for PostgreSQL services (source = old major, target = new major)
# and the demo database on both. Idempotent: existing services are reused.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

create_if_missing() { # service version
  local svc="$1" ver="$2"
  if avn service get --project "$AVN_PROJECT" "$svc" >/dev/null 2>&1; then
    warn "$svc already exists, reusing it"
  else
    log "Creating $svc (PostgreSQL $ver, plan $PLAN in $CLOUD)"
    avn service create --project "$AVN_PROJECT" \
      --service-type pg --plan "$PLAN" --cloud "$CLOUD" \
      -c pg_version="$ver" "$svc"
  fi
}

if [[ "$SOURCE_IS_AIVEN" == "true" ]]; then
  create_if_missing "$SRC_SERVICE" "$SRC_VERSION"
else
  warn "SOURCE_IS_AIVEN=false: not creating a source service, using SRC_URI from .env"
fi
create_if_missing "$DST_SERVICE" "$DST_VERSION"

log "Waiting for services to reach RUNNING (this is the coffee break)"
[[ "$SOURCE_IS_AIVEN" == "true" ]] && avn service wait --project "$AVN_PROJECT" "$SRC_SERVICE"
avn service wait --project "$AVN_PROJECT" "$DST_SERVICE"

log "Creating database '$DBNAME' on both sides"
if [[ "$SOURCE_IS_AIVEN" == "true" ]]; then
  avn service database-create --project "$AVN_PROJECT" --dbname "$DBNAME" "$SRC_SERVICE" 2>/dev/null \
    || warn "database $DBNAME already exists on $SRC_SERVICE"
fi
avn service database-create --project "$AVN_PROJECT" --dbname "$DBNAME" "$DST_SERVICE" 2>/dev/null \
  || warn "database $DBNAME already exists on $DST_SERVICE"

log "Double check: versions and replication settings"
echo "source: $(q_src 'SELECT version()')"
echo "        wal_level=$(q_src 'SHOW wal_level')  max_replication_slots=$(q_src 'SHOW max_replication_slots')  max_wal_senders=$(q_src 'SHOW max_wal_senders')"
echo "target: $(q_dst 'SELECT version()')"
echo "        max_logical_replication_workers=$(q_dst 'SHOW max_logical_replication_workers')  max_sync_workers_per_subscription=$(q_dst 'SHOW max_sync_workers_per_subscription')"

if [[ "$(q_src 'SHOW wal_level')" == "logical" ]]; then
  ok "source wal_level is logical"
else
  die "source wal_level is not 'logical'. RDS: rds.logical_replication=1 | Cloud SQL: cloudsql.logical_decoding=on | Azure Flexible Server: wal_level=logical. All need a restart."
fi
