# Two elephants, one WAL: logical replication, and how to upgrade PostgreSQL 15 to 18 on Aiven without a maintenance window

*All scripts in this post live in the companion repository: `pg-logical-upgrade-demo`. Every step references a numbered script you can run against your own Aiven project.*

## The maintenance window is a myth

Every PostgreSQL major version lives for five years. PostgreSQL 14 reaches end of life on 12 November 2026, 15 follows in November 2027, and on Aiven the EOL dates are identical to upstream, so the platform will eventually upgrade you whether you planned it or not. The question is never *if* you upgrade. It is how many minutes of "we're sorry, we'll be right back" you are willing to put in front of your users.

The classic answer, `pg_upgrade`, is excellent. On Aiven it is a single click (or `avn service update -c pg_version=18`) and finishes in about a minute for small databases. But it has two properties that make architects nervous: the database is unavailable while it runs, and there is no way back. Once you are on 18, you are on 18.

Logical replication offers a different deal. You build the new server next to the old one, let it catch up while production keeps running, verify everything at your own pace, and then flip a connection string. Downtime shrinks to the seconds it takes your application to reconnect. And the old server is still there, intact, if anything looks wrong. The same mechanism also moves a database from Amazon RDS, Google Cloud SQL or Azure Database for PostgreSQL to Aiven, because to logical replication a different cloud is just a different hostname.

This post explains what logical replication is, where it came from, how it differs from the streaming replication you already run, and what PostgreSQL 18 and the upcoming 19 add to it. Then we upgrade a PostgreSQL 15 service to 18 on Aiven, with checks at every step, because "it replicated" and "the data is correct" are two different sentences.

## Physical versus logical: photocopier versus phone call

PostgreSQL has two kinds of replication, and the names are only mildly helpful.

**Physical (streaming) replication** ships the write-ahead log, byte for byte, to a standby that replays it. The standby is a block-level clone of the primary: same major version, same architecture, same everything, down to the dead tuples and the bloat. It is the photocopier of replication. It copies the whole book including the coffee stains, it is fast, it is boring, and boring is what you want from high availability. Aiven's own HA standbys and read replicas work this way.

**Logical replication** decodes the same WAL into *row changes* ("row with primary key 42 in table `orders` changed status to `paid`") and sends those to a subscriber that applies them as ordinary SQL. It is the phone call: "Hi, order 42 is paid now." The subscriber does not need to be the same version. It does not need to be the same instance type. It can hold other tables, other indexes, other data. It can be a PostgreSQL 18 server listening to a PostgreSQL 15 server, or an Aiven service listening to RDS.

| | Physical / streaming | Logical |
|---|---|---|
| What travels | WAL bytes | Decoded row changes (INSERT, UPDATE, DELETE, TRUNCATE) |
| Granularity | Whole cluster | Per database, per table, even per row filter or column list |
| Versions | Identical major version | Any supported combination, including old → new |
| Target is | Read-only clone | Normal, writable database |
| DDL | Replicated (it is just WAL) | Not replicated: you manage the schema |
| Sequences | Replicated | Not replicated before PostgreSQL 19 |
| Needs on the target | Nothing but disk | Matching tables, extensions, replica identities |
| Typical use | HA, read replicas, PITR | Upgrades, migrations, consolidation, selective sync, CDC |

The last row is the point. Streaming replication keeps a copy alive. Logical replication moves a database somewhere else while it is running.

## A short history, so you know whose shoulders you are standing on

Logical replication in PostgreSQL did not appear in one release. It took about fifteen years and several generations of tools.

- **2004: Slony-I.** Trigger-based. Every change fired a trigger that wrote to a queue table, and daemons shipped the queue around. It worked, it was the way to do major upgrades for a decade, and nobody who ran it misses it.
- **Londiste (Skype) and Bucardo** followed the same trigger-based idea with different trade-offs. Bucardo did multi-master, which mostly taught the community why multi-master is hard.
- **2014, PostgreSQL 9.4: logical decoding.** Andres Freund and others added the infrastructure to turn WAL into a stream of logical changes via output plugins. No triggers, no queue tables, no write amplification. `test_decoding` and later `wal2json` showed what was possible, and every CDC tool you know (Debezium, for example) sits on this layer.
- **2016: pglogical** (2ndQuadrant) packaged logical decoding into a usable replication extension, and became the prototype for what came next.
- **2017, PostgreSQL 10: built-in logical replication.** `CREATE PUBLICATION` on the source, `CREATE SUBSCRIPTION` on the target, done. Aiven shipped support a year later together with the open source `aiven_extras` extension, because `CREATE SUBSCRIPTION` needs superuser and no sane managed platform hands out superuser.

Since then every release has added something:

| Version | Logical replication additions |
|---|---|
| 11 | TRUNCATE is replicated |
| 13 | Partitioned tables can publish via the partition root |
| 14 | Streaming of large in-progress transactions, binary transfer mode |
| 15 | Row filters, column lists, `FOR TABLES IN SCHEMA` |
| 16 | Logical decoding from a standby, parallel apply of large transactions, `origin = none` for bidirectional setups, non-superuser subscription owners via `pg_create_subscription` |
| 17 | Failover slots (slots survive a primary failover), `pg_createsubscriber` to turn a physical standby into a logical replica, `pg_upgrade` preserves slots and subscriptions |
| 18 | Generated columns, conflict logging and statistics, `streaming = parallel` by default, two-phase commit toggle on existing subscriptions, `idle_replication_slot_timeout`, `max_active_replication_origins` |
| 19 (beta 4) | Sequence replication, `ALL TABLES EXCEPT`, `retain_dead_tuples` for `update_deleted` conflict detection, automatic logical WAL level, subscriptions via `postgres_fdw` servers |

We come back to 18 and 19 at the end. First, the upgrade.

## Three ways to upgrade, one worth a blog post

| Method | Downtime | Rollback | Cross-cloud | Effort |
|---|---|---|---|---|
| `pg_dump` / `pg_restore` | Hours for anything serious | Trivial (old server untouched) | Yes | Low |
| In-place `pg_upgrade` (Aiven: one click) | Seconds to minutes, unreadable during the run | None | No | Lowest |
| Logical replication | Application reconnect | Old server intact, optionally kept in sync | Yes | Medium |

Aiven's in-place upgrade is the right default for most services: `pg_upgrade --check` runs first, the whole thing usually takes under a minute on small databases, and you can rehearse it on a fork. Use it when a short interruption is fine and your extensions exist for the target version.

Reach for logical replication when the interruption is not fine, when you want a rehearsal with real traffic, when you need a rollback path, or when the source is not on Aiven at all.

## What Aiven does for you, and what it does not

A few platform facts before we start typing:

- `wal_level` is `logical` on every Aiven for PostgreSQL service. Nothing to configure, no restart.
- `aiven_extras` is preinstalled. Its functions run the superuser-only statements (`CREATE SUBSCRIPTION`, `CREATE PUBLICATION FOR ALL TABLES`, `ALTER SUBSCRIPTION ... REFRESH PUBLICATION`) on your behalf.
- Replication slots are recreated after failovers and maintenance updates. They are *not* carried over an in-place major version upgrade, so finish logical migrations before upgrading a publisher in place.
- Aiven's built-in migration (`avn service update -c migration.host=... -c migration.method=replication`, or *Import database* in the console) wraps all of this into one command via `aiven-db-migrate`. It is the fast path. This post shows the slow path so you understand what the fast path does, and so you can adapt it when your situation does not fit the wizard.

And the three limits of logical replication you will meet in every migration:

1. **No DDL.** Tables, indexes, functions and extensions must exist on the target before data arrives, and schema changes during the migration must be applied on both sides.
2. **No sequences.** Identity columns and serials keep working on the target, but their sequences start where the empty target started. You sync them at cutover. PostgreSQL 19 fixes this.
3. **Replica identity.** UPDATE and DELETE need a way to say *which* row. A primary key does it. A table without one needs `REPLICA IDENTITY FULL` (or, better, a primary key).

Large objects (`pg_largeobject`) are a fourth, rarer limit: they are never replicated. If you still have them, you have bigger upgrade questions than this post answers.

## The demo: PostgreSQL 15 → 18 in nine scripts

The repository builds a small web shop (customers, products, orders, order items, an audit log with no primary key, a standalone invoice sequence and a stored generated column) because a demo without the annoying parts teaches nothing.

### 1. Two services, one command each

```bash
avn service create --project $AVN_PROJECT --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=15 pg-source-15
avn service create --project $AVN_PROJECT --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=18 pg-target-18
avn service wait --project $AVN_PROJECT pg-source-15
avn service wait --project $AVN_PROJECT pg-target-18
```

`scripts/01_create_services.sh` does this, creates the `shop` database on both, and then checks what it created: `SELECT version()` on each side, `SHOW wal_level` on the source, and the worker limits on the target. The script refuses to continue if `wal_level` is anything but `logical`, which is exactly the check that saves you an hour when the source is RDS.

### 2. Schema over, data stays

```bash
pg_dump "$SRC_URI" --schema-only --no-owner --no-privileges \
  --no-publications --no-subscriptions > schema-from-source.sql
psql "$DST_URI" -f schema-from-source.sql
```

`scripts/02_schema_and_seed.sh` seeds the source, dumps the schema with a `pg_dump` at least as new as the source server, and applies it on the target. `--no-owner --no-privileges` because role names rarely survive a change of provider; re-grant your application roles afterwards. Then the double check: a `diff` of the table lists from both catalogs, and a look at `pg_stat_user_tables` on the target to confirm it is empty. Same shape, no content. That is what we want before the copy.

### 3. Publish (and find the table without a primary key first)

```sql
-- the preflight: tables that cannot replicate UPDATE/DELETE
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND c.relreplident = 'd'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary);
```

`scripts/03_setup_publication.sh` runs this, finds `audit_log`, and applies `ALTER TABLE audit_log REPLICA IDENTITY FULL`. In a real migration you would add a primary key instead; `FULL` writes the entire old row into WAL on every change and makes the subscriber scan for it. The script also prints the sequence count, large object count and installed extensions, so nothing surprises you later. Then:

```sql
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT aiven_extras.pg_create_publication_for_all_tables(
  'pub_shop_all', 'INSERT,UPDATE,DELETE,TRUNCATE');
```

On a non-Aiven source (set `SOURCE_IS_AIVEN=false`), the same script runs plain `CREATE PUBLICATION pub_shop_all FOR ALL TABLES`, which `rds_superuser`, `cloudsqlsuperuser` and `azure_pg_admin` are allowed to do. The check at the end lists `pg_publication_tables` so you see exactly which tables are in.

### 4. Subscribe, then wait for every table to say "r"

```sql
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT aiven_extras.pg_create_subscription(
  'sub_shop_from_pg15',
  'host=pg-source-15-....aivencloud.com port=12345 dbname=shop user=avnadmin password=... sslmode=require',
  'pub_shop_all',
  'slot_shop_to_pg18',
  TRUE,   -- create the slot on the publisher
  TRUE);  -- copy_data: snapshot every table first, then stream
```

`scripts/04_setup_subscription.sh` builds the connection string from `avn service get --json`, creates the subscription, and then polls `pg_subscription_rel` until every table has `srsubstate = 'r'`. The states are worth knowing because they are what you stare at during a large migration: `i` initializing, `d` copying data, `f` copy finished, `s` synchronized, `r` ready and streaming. Only `r` means "live". The script finishes with row counts on the target, which should now match the source.

### 5. Load, because a quiet database proves nothing

```bash
scripts/05_generate_load.sh 120 4
```

runs `pgbench` with a custom script: insert an order, insert a line item, mark an older order as paid, write an audit row, bump the invoice sequence. Four clients, two minutes. Run it in one terminal and keep the next script open in another.

### 6. Check from both ends

`scripts/06_check_replication.sh --watch` refreshes every five seconds and shows the things you will be asked about in a go/no-go meeting:

```sql
-- publisher: is the slot active, how much WAL is it holding back?
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_behind
FROM pg_replication_slots;

-- subscriber: how far behind is the apply worker?
SELECT subname, received_lsn, latest_end_lsn, now() - latest_end_time AS apply_delay
FROM pg_stat_subscription WHERE relid IS NULL;

-- subscriber: anything failing?
SELECT * FROM pg_stat_subscription_stats;
```

The slot query is the one to internalize. A replication slot makes the publisher keep every WAL segment the subscriber has not confirmed. If the subscriber goes away and the slot stays, `wal_behind` grows until the publisher's disk is full and the publisher stops accepting writes. That is the single most common way logical replication takes down a production database, and it is entirely self-inflicted. `09_cleanup.sh` exists for this reason.

On PostgreSQL 18 the last query also shows the new conflict counters: `confl_insert_exists`, `confl_update_missing`, `confl_delete_missing` and friends. If someone writes to the target while you migrate, you will see it here instead of in a stuck apply worker.

For live demos there is `--ping`: it inserts a marker row on the source and times how long until it appears on the target. On two `startup-4` services in the same region that is typically well under a second, which tends to end the "is it real-time?" discussion.

### 7. Verify the content, not just the counts

```bash
scripts/07_verify_data.sh
```

For every table it runs the same statement on both sides:

```sql
SELECT count(*), md5(string_agg(t::text, E'\n' ORDER BY t::text)) FROM orders t;
```

and compares. Equal count and equal hash means equal content, including the generated column that the PostgreSQL 18 side computed on its own. Run it while load is active and the hashes will differ, which is correct and a good moment to explain why. Run it after the load stops and they match. The script also prints every sequence value on both sides, so the gap you are about to close in step 8 is visible before you close it.

### 8. Cutover: the fifteen seconds that matter

`scripts/08_cutover.sh` asks for confirmation and then does five things:

1. **Block writes on the source.** `ALTER DATABASE shop SET default_transaction_read_only = on`, then terminate existing application sessions, because the setting only applies to new ones.
2. **Drain.** Write one last marker row (our own session overrides the read-only default) and wait until it arrives on the target. Then compare `pg_current_wal_lsn()` on the publisher with `latest_end_lsn` on the subscriber: zero bytes of lag.
3. **Sync sequences.** On the source, `pg_sequences` knows every `last_value`, identity columns included. The script turns that into `setval()` statements and runs them on the target. Skip this and your first `INSERT` on the new server collides with an existing primary key. Everybody does this exactly once.
4. **ANALYZE.** A freshly loaded server has no planner statistics. One `ANALYZE` prevents the "the new version is slower" ticket that is really a "the planner is flying blind" ticket.
5. **Verify again** and print the new connection string.

Point your application at `pg-target-18`. Total write unavailability: from step 1 to the reconnect, usually seconds.

The subscription stays until you decide you are done. If you want a real safety net, `scripts/10_reverse_replication.sh` creates a publication on the new PostgreSQL 18 server and a subscription on the old 15 with `copy_data = FALSE`. Every write that lands on 18 now also lands on 15. Rolling back means pointing the application back. Logical replication does not care that the publisher is newer than the subscriber, which is a sentence you cannot say about any other upgrade method.

### 9. Clean up, especially the slot

`scripts/09_cleanup.sh` drops the subscription (which drops the slot on the publisher), confirms in `pg_replication_slots` that nothing was left behind, drops the publication, and with `TERMINATE=yes` removes both services. The check for orphaned slots is deliberately loud.

## The same recipe for RDS, Cloud SQL and Azure

Nothing in the scripts is Aiven-specific on the source side except the `aiven_extras` call for the publication, and that has a plain-SQL branch. To migrate from somewhere else:

| Source | Turn on logical WAL | Who may create the publication |
|---|---|---|
| Amazon RDS / Aurora PostgreSQL | parameter group `rds.logical_replication = 1`, reboot | `rds_superuser` |
| Google Cloud SQL | flag `cloudsql.logical_decoding = on`, restart; `ALTER USER ... WITH REPLICATION` | `cloudsqlsuperuser` |
| Azure Database for PostgreSQL Flexible Server | server parameter `wal_level = logical`, restart; `ALTER ROLE ... WITH REPLICATION` | `azure_pg_admin` |
| Self-managed | `wal_level = logical`, `max_replication_slots`, `max_wal_senders`, `pg_hba.conf` entry | any superuser or role with `REPLICATION` |

Then: open the source firewall for the Aiven service (Aiven static IPs help if you must allow-list addresses), set `SOURCE_IS_AIVEN=false` and `SRC_URI` in `.env`, and run scripts 02 to 09 unchanged. Or skip all of it and let `avn service update -c migration.host=... -c migration.port=... -c migration.ssl=true -c migration.username=... -c migration.password=... -c migration.dbname=... pg-target-18` do the same thing, then watch `avn service migration-status`. The wizard uses logical replication for every database that meets the preconditions and falls back to `pg_dump` for the ones that do not. You now know what those preconditions are.

## What PostgreSQL 18 changed for logical replication

PostgreSQL 18 (released 25 September 2025; Aiven runs 18.6 and uses 18 as the default for new services) is a quality-of-life release for replication:

- **Generated columns are published.** `publish_generated_columns` on the publication, or a column list that names them. Before 18 the subscriber had to compute generated columns itself, which works between PostgreSQL servers and fails for everything else. In our 15 → 18 demo the publisher is still 15, so the subscriber computes `line_total_cents`. With an 18 publisher you can choose.
- **Conflicts are logged and counted.** `insert_exists`, `update_origin_differs`, `update_exists`, `update_missing`, `delete_origin_differs`, `delete_missing`, `multiple_unique_conflicts`: each gets a log line with the conflicting key and a counter in `pg_stat_subscription_stats`. Diagnosing a stuck subscription went from "read the logs and guess" to "read one row".
- **`streaming = parallel` is the default** for new subscriptions. Large in-progress transactions are applied by parallel workers instead of being spooled to disk first.
- **`ALTER SUBSCRIPTION ... SET (two_phase = ...)`** works on an existing subscription.
- **`idle_replication_slot_timeout`** invalidates slots nobody has consumed for a while. This is the server-side answer to the disk-full story above. Aiven's own slot handling already protects you from the worst of it; this GUC makes the protection standard PostgreSQL.
- **`max_active_replication_origins`** is its own setting, so many subscriptions no longer force a high `max_replication_slots`.
- **`pg_createsubscriber`** gained `--all`, `--clean` and `--enable-two-phase`. It converts a physical standby into a logical subscriber in one step, which is the fastest way to bootstrap a huge logical replica. It needs file-system access to the standby, so it is a self-managed tool; on Aiven the `copy_data` snapshot does the same job over the network.

## What PostgreSQL 19 brings (beta 4, 24 September 2026)

PostgreSQL 19 is in beta at the time of writing, so treat the list as "in the beta 4 release notes", not "in your production server next week". The logical replication section is the longest it has been in years:

- **Sequences replicate.** `CREATE PUBLICATION ... FOR ALL SEQUENCES`, and `ALTER SUBSCRIPTION ... REFRESH SEQUENCES` syncs their values; `pg_get_sequence_data()` lets you inspect the state. Step 3 of our cutover script becomes a one-liner, and the most common post-cutover incident disappears.
- **`ALL TABLES EXCEPT (...)`** on publications. Finally a way to say "everything but the 400 GB event archive".
- **`retain_dead_tuples`** on subscriptions keeps the information needed to detect `update_deleted` conflicts (an update arriving for a row that was concurrently deleted), with `max_retention_duration` as the safety valve, and a new `update_deleted` counter in `pg_stat_subscription_stats`.
- **Automatic logical WAL level.** With `wal_level = replica`, the server switches to logical decoding when a logical slot needs it, without a restart. `effective_wal_level` reports what is actually in effect. Self-managed sources no longer need the restart that RDS, Cloud SQL and Azure still require today.
- **`CREATE SUBSCRIPTION ... SERVER`** takes its connection details from a `postgres_fdw` foreign server, so passwords stop living in subscription definitions.
- **Per-subscription `wal_receiver_timeout`**, so a slow cross-region link does not force a global setting.
- **`REPACK CONCURRENTLY`**, the successor of `VACUUM FULL` and `CLUSTER`, rebuilds a table without an exclusive lock and uses logical decoding internally to replay changes made during the rebuild. Not replication as such, but the same machinery, and a hint at how central logical decoding has become.

If you are planning a 15 → 18 migration now, none of this changes the plan. If you are planning the 18 → 19 one for late 2026 or 2027, your cutover checklist just lost its most error-prone step.

## The two-minute version for your next architecture call

- Streaming replication copies a cluster; logical replication moves a database. Different tools for different jobs.
- A major version upgrade with logical replication costs a reconnect, not a maintenance window, and leaves the old server intact as a rollback.
- On Aiven: `wal_level` is already `logical`, `aiven_extras` replaces superuser, and `avn service update -c migration.*` wraps the whole procedure when the standard case fits. The scripts in the repository are for when it does not.
- Three things to check before any migration: replica identities, sequences, DDL freeze. One thing to check after: no orphaned slot.
- The same procedure migrates from RDS, Cloud SQL and Azure. Flip two parameters on the source and open a firewall.
- PostgreSQL 18 made conflicts visible; PostgreSQL 19 makes sequences replicate. Both make the method above easier, neither changes it.

Clone the repository, set `AVN_PROJECT`, and run the scripts in order. An afternoon and two `startup-4` services later you will have upgraded a database without anyone noticing. Which is, after all, the whole point.
