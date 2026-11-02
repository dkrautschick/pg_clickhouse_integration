-- Path 4, PostgreSQL side: what Debezium needs, and how to watch the slot.
SHOW wal_level;                       -- must be 'logical' (a restart if you have to change it)
SHOW max_replication_slots;
SHOW max_wal_senders;

-- Debezium creates the publication itself (publication.autocreate.mode = filtered). To do it by hand instead:
CREATE PUBLICATION dbz_beer FOR TABLE beer_sales;

-- The role Debezium connects with needs the REPLICATION attribute (a superuser has it implicitly):
-- CREATE ROLE debezium LOGIN REPLICATION PASSWORD '<password>';  GRANT SELECT ON beer_sales TO debezium;

-- Watch the slot. An inactive slot keeps WAL forever and fills your disk.
SELECT slot_name, plugin, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;

-- Row identity for deletes: with the default replica identity (primary key) a DELETE event carries the key in "before".
SELECT relname, relreplident FROM pg_class WHERE relname = 'beer_sales';   -- d = default (primary key), f = full
