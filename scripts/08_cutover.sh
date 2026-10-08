#!/usr/bin/env bash
# Step 8: the cutover. Stop writes on the source, drain the replication, fix sequences,
# refresh statistics on the target, hand out the new connection string.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

cat <<EOT

  CUTOVER PLAN
  1. Block new writes on the source database '$DBNAME' (default_transaction_read_only=on) and kick out app sessions
  2. Write a final marker row and wait until the subscriber has applied it (lag = 0)
  3. Copy sequence values from source to target
  4. ANALYZE the target (a fresh server has no planner statistics)
  5. Point your application at the target
  The subscription stays in place until you run 09_cleanup.sh, so you can still go back.

EOT
confirm "Stop writes on $SRC_SERVICE/$DBNAME now?"

log "1. Making source database read-only for new sessions and terminating application sessions"
psql_src -q -c "ALTER DATABASE $DBNAME SET default_transaction_read_only = on;"
psql_src -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                WHERE datname = '$DBNAME' AND pid <> pg_backend_pid() AND backend_type = 'client backend';"
ok "new sessions on '$DBNAME' are read-only; existing application sessions were terminated"

log "2. Final marker + drain"
MARKER="cutover-$(date -u +%Y%m%dT%H%M%SZ)"
# Our own session overrides the read-only default for exactly this one write.
psql_src -q -c "SET default_transaction_read_only = off;" -c "INSERT INTO audit_log(what) VALUES ('$MARKER');"
for _ in $(seq 1 600); do
  if [[ -n "$(q_dst "SELECT 1 FROM audit_log WHERE what = '$MARKER'")" ]]; then ok "marker '$MARKER' arrived on target"; break; fi
  sleep 0.5
done
SRC_LSN="$(q_src 'SELECT pg_current_wal_lsn()')"
echo "   publisher LSN $SRC_LSN, subscriber lag: $(q_dst "SELECT pg_size_pretty(pg_wal_lsn_diff('$SRC_LSN', latest_end_lsn)) FROM pg_stat_subscription WHERE subname='$SUBSCRIPTION' AND relid IS NULL")"

log "3. Syncing sequences (identity columns included)"
q_src "$(cat "$REPO/sql/sync_sequences.sql")" > "$REPO/setval-from-source.sql"
psql_dst -q -f "$REPO/setval-from-source.sql"
cat "$REPO/setval-from-source.sql" | sed 's/^/   /'
ok "sequences set on target (statements saved in setval-from-source.sql)"

log "4. ANALYZE on target"
psql_dst -q -c "ANALYZE;"
ok "planner statistics collected"

log "5. Final verification"
"$HERE/07_verify_data.sh"

log "Done. New connection string for your application:"
echo "   $(svc_uri "$DST_SERVICE" "$DBNAME" | sed -E 's#:[^:@/]+@#:********@#')"
echo "   (avn service get --project $AVN_PROJECT --json $DST_SERVICE | jq -r .service_uri)"
echo
echo "When you are happy: scripts/09_cleanup.sh. Need a safety net first? scripts/10_reverse_replication.sh"
