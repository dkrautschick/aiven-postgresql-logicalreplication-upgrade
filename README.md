# Near-zero-downtime PostgreSQL major upgrade with logical replication on Aiven

Companion repository for the blog post *"Two elephants, one WAL: logical replication, and how to
upgrade PostgreSQL 15 to 18 on Aiven without a maintenance window"*.

The scripts build a PostgreSQL 15 service, a PostgreSQL 18 service, a demo database, and a
logical replication link between them. Then they generate load, check the replication from both
ends, verify the data, and perform the cutover. The same scripts work with a source outside Aiven
(Amazon RDS, Google Cloud SQL, Azure Database for PostgreSQL Flexible Server, your own server):
set `SOURCE_IS_AIVEN=false` and `SRC_URI`.

## Prerequisites

- [Aiven CLI](https://aiven.io/docs/tools/cli) (`pip install aiven-client`), logged in: `avn user login`
- `psql`, `pg_dump` and `pgbench` from a PostgreSQL client package **at least as new as the source server**
  (PostgreSQL 18 client tools talk to every version used here)
- `jq`
- An Aiven project. Two `startup-4` services for an afternoon cost a few euros.

## Quick start

```bash
cp .env.example .env            # set AVN_PROJECT at minimum
scripts/01_create_services.sh    # two services + database 'shop' on both   (~5 min)
scripts/02_schema_and_seed.sh    # schema + data on source, schema only on target
scripts/03_setup_publication.sh  # preflight checks, replica identity, CREATE PUBLICATION (source)
scripts/04_setup_subscription.sh # CREATE SUBSCRIPTION via aiven_extras, wait for initial sync (target)

scripts/05_generate_load.sh 120  # terminal 1: write load on the source for 2 minutes
scripts/06_check_replication.sh --watch   # terminal 2: slot, lag, per-table state, conflicts
scripts/06_check_replication.sh --ping    # end-to-end latency of one row

scripts/07_verify_data.sh        # row counts + content hashes, both sides
scripts/08_cutover.sh            # read-only source, drain, sync sequences, ANALYZE, new URI
scripts/10_reverse_replication.sh # optional safety net: replicate 18 -> 15 for rollback
scripts/09_cleanup.sh            # drop subscription/slot/publication; TERMINATE=yes also removes services
```

## What each script double-checks

| Script | Checks |
|---|---|
| `01_create_services.sh` | server versions, `wal_level=logical`, slot and worker limits |
| `02_schema_and_seed.sh` | identical table lists on both sides, target tables empty |
| `03_setup_publication.sh` | tables without replica identity (fixed with `REPLICA IDENTITY FULL`), sequences, large objects, extensions, publication contents |
| `04_setup_subscription.sh` | subscription visible, every table reaches `srsubstate = 'r'`, row counts after copy |
| `06_check_replication.sh` | slot active + WAL retained, walsender state, apply delay, per-table state, `pg_stat_subscription_stats` (conflict counters on PG 18), byte lag, optional round-trip ping |
| `07_verify_data.sh` | per-table `count(*)` and `md5()` over all rows on both sides, sequence values |
| `08_cutover.sh` | final marker row arrived, lag is zero, sequences synced, `ANALYZE` done, data verified again |
| `09_cleanup.sh` | no orphaned replication slot left on the publisher |

## Layout

```
scripts/   numbered bash scripts, all source scripts/00_lib.sh
sql/       schema, seed data, pgbench load script, check queries, sequence sync
terraform/ optional: create the two services with the Aiven Terraform provider
```

## Notes and gotchas

- **No superuser on managed PostgreSQL.** `CREATE SUBSCRIPTION` and `CREATE PUBLICATION FOR ALL TABLES`
  need superuser in vanilla PostgreSQL. Aiven ships the open source `aiven_extras` extension, whose
  functions run those statements for you. The scripts use it on both Aiven services.
- **Logical replication does not copy DDL.** Schema changes during the migration must be applied on
  both sides (target first for additive changes). New tables need a refresh on the subscriber:
  `SELECT aiven_extras.pg_alter_subscription_refresh_publication('sub_name', true);`
- **Sequences are not replicated before PostgreSQL 19.** `08_cutover.sh` copies them with `setval()`.
- **Large objects are never replicated.** Dump and restore them separately.
- **An inactive replication slot fills the publisher's disk.** `09_cleanup.sh` makes sure none is left behind.
  Aiven recreates slots after failover and maintenance, but not after an in-place major version upgrade.
- **Read-only trick at cutover** uses `ALTER DATABASE ... SET default_transaction_read_only = on`. It only
  affects new sessions, which is why the script also terminates existing application sessions. Note that a
  logical replication apply worker is a normal session too, so `10_reverse_replication.sh` resets it.
- **External sources:** RDS needs `rds.logical_replication = 1`, Cloud SQL `cloudsql.logical_decoding = on`,
  Azure Flexible Server `wal_level = logical` plus the `REPLICATION` attribute on the user. All require a
  restart. The source firewall must accept connections from the Aiven service (consider Aiven static IPs
  if you need stable addresses to allow-list).
- **Alternative with less typing:** Aiven's built-in migration (`avn service update -c migration.host=...`,
  console: *Import database*) runs `aiven-db-migrate`, which uses logical replication under the hood and
  falls back to `pg_dump` where it cannot. The scripts here show what happens underneath.

## License

MIT. Use, copy, break, improve.
