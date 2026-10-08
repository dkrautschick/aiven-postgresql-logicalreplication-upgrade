#!/usr/bin/env bash
# Step 2: create the demo schema + data on the source, then copy ONLY the schema to the target.
# Logical replication does not replicate DDL, so the target needs the tables first.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
need pg_dump

log "Creating demo schema on source ($SRC_SERVICE/$DBNAME)"
psql_src -q -f "$REPO/sql/schema.sql"
log "Seeding demo data on source"
psql_src -q -f "$REPO/sql/seed.sql"
psql_src -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname"

log "Dumping schema only from source (no data, no publications, no subscriptions)"
SCHEMA_FILE="$REPO/schema-from-source.sql"
# --no-owner/--no-privileges: role names rarely match across providers (think RDS vs Aiven).
# Re-apply GRANTs for your application roles on the target afterwards.
# Use a pg_dump that is at least as new as the SOURCE server version.
pg_dump "$(svc_uri "$SRC_SERVICE" "$DBNAME")" \
  --schema-only --no-owner --no-privileges \
  --no-publications --no-subscriptions \
  > "$SCHEMA_FILE"
# aiven_extras is created explicitly by later scripts; drop it from the dump if present.
sed -i.bak '/EXTENSION.*aiven_extras/d' "$SCHEMA_FILE" && rm -f "$SCHEMA_FILE.bak"
ok "schema written to $SCHEMA_FILE ($(wc -l < "$SCHEMA_FILE") lines)"

log "Applying schema on target ($DST_SERVICE/$DBNAME)"
psql_dst -q -f "$SCHEMA_FILE"

log "Double check: same tables on both sides, zero rows on target"
TABLES_SQL="SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema') ORDER BY 1"
if diff <(q_src "$TABLES_SQL") <(q_dst "$TABLES_SQL"); then
  ok "table lists are identical"
else
  die "table lists differ between source and target"
fi
psql_dst -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname"
