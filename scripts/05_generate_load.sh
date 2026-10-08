#!/usr/bin/env bash
# Step 5: generate realistic write load on the SOURCE while replication runs.
# Usage: scripts/05_generate_load.sh [seconds=120] [clients=4]
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
need pgbench

SECONDS_TO_RUN="${1:-120}"
CLIENTS="${2:-4}"

log "Running pgbench with sql/load.pgbench against $SRC_SERVICE/$DBNAME for ${SECONDS_TO_RUN}s with $CLIENTS clients"
echo "  (each transaction: new order + order item + mark an older order as paid + audit row)"
pgbench "$(svc_uri "$SRC_SERVICE" "$DBNAME")" \
  --no-vacuum --client="$CLIENTS" --jobs=2 --time="$SECONDS_TO_RUN" \
  --progress=10 --file="$REPO/sql/load.pgbench"
