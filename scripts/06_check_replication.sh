#!/usr/bin/env bash
# Step 6: health check of the replication from both ends, plus an optional end-to-end "ping".
# Usage: scripts/06_check_replication.sh [--ping] [--watch]
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

check_once() {
  log "PUBLISHER ($SRC_SERVICE): replication slot and WAL retained for it"
  psql_src -c "SELECT slot_name, plugin, active, restart_lsn, confirmed_flush_lsn,
                      pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_behind,
                      wal_status
               FROM pg_replication_slots WHERE slot_name = '$SLOT';"
  # A slot that is NOT active keeps WAL forever and eventually fills the disk. Watch wal_behind.

  log "PUBLISHER: walsender view (what the subscriber has acknowledged)"
  if [[ "$SOURCE_IS_AIVEN" == "true" ]]; then
    psql_src -x -c "SELECT * FROM aiven_extras.pg_stat_replication_list();"   # includes Aiven's own backup/standby streams
  else
    psql_src -x -c "SELECT application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag
                    FROM pg_stat_replication WHERE application_name = '$SUBSCRIPTION';"
  fi

  log "SUBSCRIBER ($DST_SERVICE): apply worker status"
  psql_dst -x -c "SELECT subname, pid, received_lsn, latest_end_lsn, last_msg_receipt_time, latest_end_time,
                         now() - latest_end_time AS apply_delay
                  FROM pg_stat_subscription WHERE subname = '$SUBSCRIPTION' AND relid IS NULL;"

  log "SUBSCRIBER: per-table sync state (all should be 'r')"
  psql_dst -c "SELECT srrelid::regclass AS table_name, srsubstate, srsublsn FROM pg_subscription_rel ORDER BY 1;"

  log "SUBSCRIBER: error and conflict counters (PostgreSQL 18 adds the confl_* columns)"
  psql_dst -x -c "SELECT * FROM pg_stat_subscription_stats WHERE subname = '$SUBSCRIPTION';"

  log "Lag in bytes: publisher's current WAL position vs. what the subscriber applied"
  SRC_LSN="$(q_src 'SELECT pg_current_wal_lsn()')"
  psql_dst -c "SELECT '$SRC_LSN' AS publisher_lsn, latest_end_lsn AS subscriber_lsn,
                      pg_size_pretty(pg_wal_lsn_diff('$SRC_LSN', latest_end_lsn)) AS lag
               FROM pg_stat_subscription WHERE subname = '$SUBSCRIPTION' AND relid IS NULL;"
}

ping_once() {
  # Write a marker on the source, wait until it shows up on the target. Great for live demos.
  local marker="ping-$(date +%s%N)"
  local t0 t1
  t0=$(date +%s%N)
  psql_src -q -c "INSERT INTO audit_log(what) VALUES ('$marker');"
  for _ in $(seq 1 300); do
    if [[ -n "$(q_dst "SELECT 1 FROM audit_log WHERE what = '$marker'")" ]]; then
      t1=$(date +%s%N)
      ok "marker $marker replicated in $(( (t1 - t0) / 1000000 )) ms"
      return
    fi
    sleep 0.1
  done
  die "marker did not arrive within 30s"
}

case "${1:-}" in
  --ping)  ping_once ;;
  --watch) while true; do clear; check_once; sleep 5; done ;;
  *)       check_once ;;
esac
