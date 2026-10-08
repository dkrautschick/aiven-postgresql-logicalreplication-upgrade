#!/usr/bin/env bash
# Optional: replicate BACK from the new major (target) to the old one (source) after cutover.
# This keeps the old server current so you can roll back the application without losing writes.
# Run it right after 08_cutover.sh, before any writes hit the target, and after 09_cleanup.sh
# has removed the forward subscription (two-way replication of the same tables is not what we want here).
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

REV_PUB="pub_shop_reverse"
REV_SUB="sub_shop_from_pg${DST_VERSION}"
REV_SLOT="slot_shop_to_pg${SRC_VERSION}"

[[ -z "$(q_dst "SELECT 1 FROM aiven_extras.pg_list_all_subscriptions() WHERE subname='$SUBSCRIPTION'" 2>/dev/null)" ]] \
  || die "forward subscription $SUBSCRIPTION still exists on $DST_SERVICE. Run 09_cleanup.sh first."

log "Publication on the NEW primary ($DST_SERVICE)"
psql_dst -q -c "CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;"
psql_dst -q -c "SELECT * FROM aiven_extras.pg_create_publication_for_all_tables('$REV_PUB', 'INSERT,UPDATE,DELETE,TRUNCATE');" \
  || warn "publication exists"

log "Subscription on the OLD server ($SRC_SERVICE), copy_data = FALSE because both sides are identical right now"
# The apply worker is a normal session: a database-level read-only default would block it.
psql_src -q -c "ALTER DATABASE $DBNAME RESET default_transaction_read_only;"
warn "source database is writable again for everyone. Keep your applications away from it."
psql_src -q -c "CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;"
psql_src -q -v conninfo="$(svc_conninfo "$DST_SERVICE" "$DBNAME")" <<SQL
SELECT * FROM aiven_extras.pg_create_subscription('$REV_SUB', :'conninfo', '$REV_PUB', '$REV_SLOT', TRUE, FALSE);
SQL

log "Double check"
psql_src -c "SELECT subname, subenabled, subslotname FROM aiven_extras.pg_list_all_subscriptions();"
echo "Rollback = point the application back at $SRC_SERVICE. The old server has every write made on $DST_SERVICE since cutover."
echo "Remember to sync sequences the other way round and to drop '$REV_SUB' when you are sure you will stay on $DST_VERSION."
