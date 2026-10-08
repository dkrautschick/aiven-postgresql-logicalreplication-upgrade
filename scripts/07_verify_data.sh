#!/usr/bin/env bash
# Step 7: compare row counts and content hashes per table on both sides.
# Run it while the source is quiet (or after cutover); with live writes the hashes will of course differ.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

TABLES="$(q_src "SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema') ORDER BY 1")"

log "Comparing $(wc -l <<<"$TABLES") tables (count + md5 over all rows, ordered by their text form)"
printf '%-32s %12s %12s  %-8s %-8s  %s\n' TABLE SRC_ROWS DST_ROWS SRC_MD5 DST_MD5 RESULT
FAIL=0
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  SQL="SELECT count(*)||'|'||coalesce(md5(string_agg(t::text, E'\n' ORDER BY t::text)),'empty') FROM $t t"
  IFS='|' read -r sc sh <<<"$(q_src "$SQL")"
  IFS='|' read -r dc dh <<<"$(q_dst "$SQL")"
  if [[ "$sc" == "$dc" && "$sh" == "$dh" ]]; then res="match"; else res="DIFF"; FAIL=1; fi
  printf '%-32s %12s %12s  %-8s %-8s  %s\n' "$t" "$sc" "$dc" "${sh:0:8}" "${dh:0:8}" "$res"
done <<<"$TABLES"

log "Sequences (NOT replicated before PostgreSQL 19; 08_cutover.sh syncs them)"
SEQ_SQL="SELECT schemaname||'.'||sequencename||' = '||coalesce(last_value::text,'(unused)') FROM pg_sequences ORDER BY 1"
paste <(echo "SOURCE"; q_src "$SEQ_SQL") <(echo "TARGET"; q_dst "$SEQ_SQL") | column -t -s $'\t'

[[ "$FAIL" == "0" ]] && ok "all tables match" || warn "differences found (expected while load is running; re-run after it stops)"
