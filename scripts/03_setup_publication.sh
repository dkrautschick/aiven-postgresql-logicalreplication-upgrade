#!/usr/bin/env bash
# Step 3 (SOURCE side): preflight checks, fix replica identities, create the publication.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "Preflight: tables without a primary key or replica identity"
# UPDATE and DELETE on such tables fail to replicate ("cannot update table because it does not have a replica identity").
NO_RI="$(q_src "$(cat "$REPO/sql/check_replica_identity.sql")")"
if [[ -n "$NO_RI" ]]; then
  warn "these tables have no PK and default replica identity:"
  echo "$NO_RI" | sed 's/^/      /'
  warn "Best fix: add a primary key. Demo fix: REPLICA IDENTITY FULL (whole old row is written to WAL, slower)."
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    psql_src -q -c "ALTER TABLE $t REPLICA IDENTITY FULL;"
    ok "ALTER TABLE $t REPLICA IDENTITY FULL"
  done <<<"$NO_RI"
else
  ok "every table has a usable replica identity"
fi

log "Preflight: things logical replication will NOT carry over"
echo "  sequences : $(q_src "SELECT count(*) FROM pg_sequences WHERE schemaname NOT IN ('pg_catalog','information_schema')") (synced at cutover by 08_cutover.sh; native in PostgreSQL 19)"
echo "  large objs: $(q_src "SELECT count(*) FROM pg_largeobject_metadata") (not replicated at all; move them with pg_dump -b if you have any)"
echo "  extensions: $(q_src "SELECT string_agg(extname||' '||extversion, ', ') FROM pg_extension WHERE extname NOT IN ('plpgsql')")"

log "Creating publication '$PUBLICATION' for all tables"
if [[ "$SOURCE_IS_AIVEN" == "true" ]]; then
  # FOR ALL TABLES needs superuser in vanilla PostgreSQL. On Aiven, aiven_extras does it for you.
  psql_src -q -c "CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;"
  if [[ -z "$(q_src "SELECT 1 FROM pg_publication WHERE pubname='$PUBLICATION'")" ]]; then
    psql_src -q -c "SELECT * FROM aiven_extras.pg_create_publication_for_all_tables('$PUBLICATION', 'INSERT,UPDATE,DELETE,TRUNCATE');"
  else
    warn "publication already exists"
  fi
else
  # RDS (rds_superuser), Cloud SQL (cloudsqlsuperuser) and Azure (azure_pg_admin) allow this for their admin role.
  psql_src -q -c "CREATE PUBLICATION $PUBLICATION FOR ALL TABLES WITH (publish = 'insert,update,delete,truncate');" \
    || warn "publication already exists or role lacks privileges"
fi

log "Double check: publication and its tables"
psql_src -c "SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate FROM pg_publication WHERE pubname='$PUBLICATION';"
psql_src -c "SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname='$PUBLICATION' ORDER BY 1,2;"
