#!/usr/bin/env bash
# Step 9: drop the subscription (and its slot on the publisher). Optionally terminate the services.
# Usage: scripts/09_cleanup.sh            -> remove replication objects only
#        TERMINATE=yes scripts/09_cleanup.sh -> also terminate both Aiven services
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "Dropping subscription '$SUBSCRIPTION' on $DST_SERVICE"
if [[ -n "$(q_dst "SELECT 1 FROM aiven_extras.pg_list_all_subscriptions() WHERE subname='$SUBSCRIPTION'" 2>/dev/null)" ]]; then
  # Drops the subscription and its slot on the publisher. If the publisher is unreachable,
  # the Aiven docs show a two-argument form with FALSE that skips the slot; try that as fallback.
  psql_dst -q -c "SELECT * FROM aiven_extras.pg_drop_subscription('$SUBSCRIPTION');" \
    || psql_dst -q -c "SELECT * FROM aiven_extras.pg_drop_subscription('$SUBSCRIPTION', FALSE);"
  ok "subscription dropped"
else
  warn "no subscription named $SUBSCRIPTION"
fi

log "Making sure no orphaned slot keeps WAL on the publisher"
if [[ -n "$(q_src "SELECT 1 FROM pg_replication_slots WHERE slot_name='$SLOT'")" ]]; then
  psql_src -q -c "SELECT pg_drop_replication_slot('$SLOT');"
  ok "slot $SLOT dropped"
else
  ok "slot $SLOT is gone"
fi
psql_src -c "SELECT slot_name, active, wal_status FROM pg_replication_slots;"

log "Dropping publication on the source"
psql_src -q -c "DROP PUBLICATION IF EXISTS $PUBLICATION;" && ok "publication dropped"

if [[ "${TERMINATE:-no}" == "yes" ]]; then
  confirm "Terminate $SRC_SERVICE and $DST_SERVICE in project $AVN_PROJECT?"
  [[ "$SOURCE_IS_AIVEN" == "true" ]] && avn service terminate --project "$AVN_PROJECT" --force "$SRC_SERVICE"
  avn service terminate --project "$AVN_PROJECT" --force "$DST_SERVICE"
  ok "services terminated"
else
  echo "Services left running. TERMINATE=yes $0 removes them."
fi
