-- Handy queries for the SUBSCRIBER side (psql). Used piecemeal by scripts/06_check_replication.sh.

-- Subscriptions (pg_subscription is superuser-only on Aiven, use the aiven_extras wrapper)
SELECT subname, subenabled, subslotname, subpublications FROM aiven_extras.pg_list_all_subscriptions();

-- Apply worker: what has arrived, what has been applied
SELECT subname, pid, received_lsn, latest_end_lsn, latest_end_time, now() - latest_end_time AS apply_delay
FROM pg_stat_subscription WHERE relid IS NULL;

-- Per-table state: i=initialize, d=data copy, f=finished copy, s=synchronized, r=ready (streaming)
SELECT srrelid::regclass AS table_name, srsubstate, srsublsn FROM pg_subscription_rel ORDER BY 1;

-- Errors and conflicts. PostgreSQL 18 added confl_insert_exists, confl_update_origin_differs,
-- confl_update_exists, confl_update_missing, confl_delete_origin_differs, confl_delete_missing,
-- confl_multiple_unique_conflicts. PostgreSQL 19 adds update_deleted (needs retain_dead_tuples).
SELECT * FROM pg_stat_subscription_stats;
