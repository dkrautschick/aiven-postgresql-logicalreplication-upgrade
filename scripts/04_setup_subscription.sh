#!/usr/bin/env bash
# Step 4 (TARGET side): create the subscription via aiven_extras, then wait for the initial table sync.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

CONNINFO="$(svc_conninfo "$SRC_SERVICE" "$DBNAME")"

log "Creating subscription '$SUBSCRIPTION' on $DST_SERVICE (slot '$SLOT' will be created on the source)"
psql_dst -q -c "CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;"
if [[ -n "$(q_dst "SELECT 1 FROM aiven_extras.pg_list_all_subscriptions() WHERE subname='$SUBSCRIPTION'")" ]]; then
  warn "subscription already exists, skipping creation"
else
  # args: subscription name, conninfo, publication, slot name, create slot?, copy existing data?
  psql_dst -q -v conninfo="$CONNINFO" <<SQL
SELECT * FROM aiven_extras.pg_create_subscription(
  '$SUBSCRIPTION',
  :'conninfo',
  '$PUBLICATION',
  '$SLOT',
  TRUE,    -- create the replication slot on the publisher
  TRUE     -- copy_data: initial snapshot of every table, then stream changes
);
SQL
fi

log "Subscription as the catalog sees it (pg_subscription is superuser-only, aiven_extras wraps it)"
psql_dst -c "SELECT subname, subenabled, subslotname, subpublications FROM aiven_extras.pg_list_all_subscriptions();"

log "Waiting for initial table sync (pg_subscription_rel.srsubstate: i=init, d=copying, f=finished copy, s=synced, r=ready)"
for _ in $(seq 1 600); do
  read -r NOT_READY TOTAL <<<"$(q_dst "SELECT count(*) FILTER (WHERE srsubstate <> 'r'), count(*) FROM pg_subscription_rel" | tr '|' ' ')"
  printf '\r  tables ready: %s/%s   ' "$((TOTAL-NOT_READY))" "$TOTAL"
  [[ "$NOT_READY" == "0" && "$TOTAL" != "0" ]] && { echo; ok "all $TOTAL tables are in state 'r' (ready, streaming changes)"; break; }
  sleep 2
done

log "Double check: row counts after initial copy"
psql_dst -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;"
echo "Next: scripts/05_generate_load.sh in one terminal, scripts/06_check_replication.sh in another."
