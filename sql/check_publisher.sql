-- Handy queries for the PUBLISHER side (psql).

-- The replication slot. An inactive slot retains WAL until the disk is full. Keep an eye on wal_behind.
SELECT slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_behind
FROM pg_replication_slots;

-- Publications and their tables
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate FROM pg_publication;
SELECT pubname, schemaname, tablename FROM pg_publication_tables ORDER BY 1, 2, 3;

-- Connected subscribers (on Aiven: aiven_extras.pg_stat_replication_list(), elsewhere: pg_stat_replication)
SELECT * FROM aiven_extras.pg_stat_replication_list();
