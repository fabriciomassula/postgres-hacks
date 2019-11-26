
------------------------------ BASIC 

-- Get indexes of tables
SELECT
    t.relname as table_name,
    i.relname as index_name,
    string_agg(a.attname, ',') as column_name
FROM
    pg_class t,
    pg_class i,
    pg_index ix,
    pg_attribute a
WHERE
    t.oid = ix.indrelid
    and i.oid = ix.indexrelid
    and a.attrelid = t.oid
    and a.attnum = ANY(ix.indkey)
    and t.relkind = 'r'
    and t.relname not like 'pg_%'
GROUP BY  
    t.relname,
    i.relname
ORDER BY
    t.relname,
    i.relname;


------------------------------ DEBUG NOW 

-- Show running queries
SELECT pid, age(query_start, clock_timestamp()), usename, query  FROM pg_stat_activity WHERE query != '<IDLE>' AND query NOT ILIKE '%pg_stat_activity%' ORDER BY query_start desc;

-- Queries which are running for more than 2 minutes
SELECT now() - query_start as "runtime", usename, datname, waiting, state, query FROM pg_stat_activity WHERE now() - query_start > '2 minutes'::interval ORDER BY runtime DESC;

-- Queries which are running for more than 9 seconds
SELECT now() - query_start as "runtime", usename, datname, waiting, state, query FROM pg_stat_activity WHERE now() - query_start > '9 seconds'::interval ORDER BY runtime DESC;

-- Kill running query
SELECT pg_cancel_backend(procpid);

-- Kill idle query
SELECT pg_terminate_backend(procpid);

-- Vacuum Command
VACUUM (VERBOSE, ANALYZE);



------------------------------ INTEGRITY 

-- Cache Hit Ratio
SELECT sum(blks_hit)*100/sum(blks_hit+blks_read) as hit_ratio FROM pg_stat_database;
-- (perfectly )hit_ration should be > 90%

-- Anomalies
SELECT datname, (xact_commit100)/nullif(xact_commit+xact_rollback,0) as c_commit_ratio, (xact_rollback100)/nullif(xact_commit+xact_rollback, 0) as c_rollback_ratio, deadlocks, conflicts, temp_files, pg_size_pretty(temp_bytes) FROM pg_stat_database;

-- c_commit_ratio should be > 95%
-- c_rollback_ratio should be < 5%
-- deadlocks should be close to 0
-- conflicts should be close to 0
-- temp_files and temp_bytes watch out for them

-- Table Sizes
SELECT relname, pg_size_pretty(pg_total_relation_size(relname::regclass)) as full_size, pg_size_pretty(pg_relation_size(relname::regclass)) as table_size, pg_size_pretty(pg_total_relation_size(relname::regclass) - pg_relation_size(relname::regclass)) as index_size FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relname::regclass) desc limit 10;

-- Another Table Sizes Query
SELECT nspname || '.' || relname AS "relation", pg_size_pretty(pg_total_relation_size(C.oid)) AS "total_size" FROM pg_class C LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace) WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND C.relkind <> 'i' AND nspname !~ '^pg_toast' ORDER BY pg_total_relation_size(C.oid) DESC;

-- Database Sizes
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname);

-- Unused Indexes
SELECT * FROM pg_stat_all_indexes WHERE idx_scan = 0;
-- idx_scan should not be = 0

-- Write Activity(index usage)
SELECT s.relname, pg_size_pretty(pg_relation_size(relid)), coalesce(n_tup_ins,0) + 2 * coalesce(n_tup_upd,0) - coalesce(n_tup_hot_upd,0) + coalesce(n_tup_del,0) AS total_writes, (coalesce(n_tup_hot_upd,0)::float * 100 / (case when n_tup_upd > 0 then n_tup_upd else 1 end)::float)::numeric(10,2) AS hot_rate, (SELECT v[1] FROM regexp_matches(reloptions::text,E'fillfactor=(d+)') as r(v) limit 1) AS fillfactor FROM pg_stat_all_tables s join pg_class c ON c.oid=relid ORDER BY total_writes desc limit 50;
-- hot_rate should be close to 100

-- Does table needs an Index
SELECT relname, seq_scan-idx_scan AS too_much_seq, CASE WHEN seq_scan-idx_scan>0 THEN 'Missing Index?' ELSE 'OK' END, pg_relation_size(relname::regclass) AS rel_size, seq_scan, idx_scan FROM pg_stat_all_tables WHERE schemaname='public' AND pg_relation_size(relname::regclass)>80000 ORDER BY too_much_seq DESC;

-- Index % usage
SELECT relname, 100 * idx_scan / (seq_scan + idx_scan) percent_of_times_index_used, n_live_tup rows_in_table FROM pg_stat_user_tables ORDER BY n_live_tup DESC;

-- How many indexes are in cache
SELECT sum(idx_blks_read) as idx_read, sum(idx_blks_hit) as idx_hit, (sum(idx_blks_hit) - sum(idx_blks_read)) / sum(idx_blks_hit) as ratio FROM pg_statio_user_indexes;

-- Dirty Pages
SELECT buffers_clean, maxwritten_clean, buffers_backend_fsync FROM pg_stat_bgwriter;
-- maxwritten_clean and buffers_backend_fsyn better be = 0

-- Sequential Scans
SELECT relname, pg_size_pretty(pg_relation_size(relname::regclass)) as size, seq_scan, seq_tup_read, seq_scan / seq_tup_read as seq_tup_avg FROM pg_stat_user_tables WHERE seq_tup_read > 0 ORDER BY 3,4 desc limit 5;
-- seq_tup_avg should be < 1000

                                                
------------------------------ CHECKPOINTS
                                                
-- Checkpoints
SELECT 'bad' as checkpoints FROM pg_stat_bgwriter WHERE checkpoints_req > checkpoints_timed;
                                                
SELECT * FROM pg_stat_bgwriter WHERE checkpoints_req > checkpoints_timed;

SELECT
    total_checkpoints,
    seconds_since_start / total_checkpoints / 60 AS minutes_between_checkpoints
FROM
(
    SELECT
        EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time())) AS seconds_since_start,
        (checkpoints_timed+checkpoints_req) AS total_checkpoints
    FROM 
        pg_stat_bgwriter
) AS sub;

-- minutes_between_checkpoints usually should be > 10min

-- if bad, check the configs
SELECT * from pg_settings where name IN ('checkpoint_timeout', 'checkpoint_completion_target', 'checkpoint_flush_after', 'checkpoint_warning', 'max_wal_size', 'min_wal_size')


-- to get the perfect wal log size, follow: https://www.2ndquadrant.com/en/blog/basics-of-tuning-checkpoints/

-- To current log on PG11
SELECT pg_current_wal_insert_lsn();

-- To get the size between 2 checkpoints on PG11
SELECT pg_wal_lsn_diff('300B4/5DBD1858', '300B4/628BC0F0');




------------------------------ ACTIVITY & CPU

-- Most CPU intensive queries (PGSQL v9.4)
SELECT substring(query, 1, 50) AS short_query, round(total_time::numeric, 2) AS total_time, calls, rows, round(total_time::numeric / calls, 2) AS avg_time, round((100 * total_time / sum(total_time::numeric) OVER ())::numeric, 2) AS percentage_cpu FROM pg_stat_statements ORDER BY total_time DESC LIMIT 20;

-- Most time consuming queries (PGSQL v9.4)
SELECT substring(query, 1, 100) AS short_query, round(total_time::numeric, 2) AS total_time, calls, rows, round(total_time::numeric / calls, 2) AS avg_time, round((100 * total_time / sum(total_time::numeric) OVER ())::numeric, 2) AS percentage_cpu FROM pg_stat_statements ORDER BY avg_time DESC LIMIT 20;

-- Maximum transaction age
SELECT client_addr, usename, datname, clock_timestamp() - xact_start as xact_age, clock_timestamp() - query_start as query_age, query FROM pg_stat_activity ORDER BY xact_start, query_start;
-- Long-running transactions are bad because they prevent Postgres FROM vacuuming old data. This causes database bloat and, in extreme circumstances, shutdown due to transaction ID (xid) wraparound. Transactions should be kept as short as possible, ideally less than a minute.

-- Bad xacts
SELECT * FROM pg_stat_activity WHERE state in ('idle in transaction', 'idle in transaction (aborted)');

-- Waiting Clients
SELECT * FROM pg_stat_activity WHERE waiting;

-- Waiting Connections for a lock
SELECT count(distinct pid) FROM pg_locks WHERE granted = false;

-- Connections
SELECT client_addr, usename, datname, count(*) FROM pg_stat_activity GROUP BY 1,2,3 ORDER BY 4 desc;

-- User Connections Ratio
SELECT count(*)*100/(SELECT current_setting('max_connections')::int) FROM pg_stat_activity;

-- Average Statement Exec Time
SELECT (sum(total_time) / sum(calls))::numeric(6,3) FROM pg_stat_statements;

-- Most writing (to shared_buffers) queries
SELECT query, shared_blks_dirtied FROM pg_stat_statements WHERE shared_blks_dirtied > 0 ORDER BY 2 desc;

-- Block Read Time
SELECT * FROM pg_stat_statements WHERE blk_read_time <> 0 ORDER BY blk_read_time desc;



------------------------------ MAINTENANCE PROCESSES

-- Last Vacuum and Analyze time
SELECT relname,last_vacuum, last_autovacuum, last_analyze, last_autoanalyze FROM pg_stat_user_tables;

-- Total number of dead tuples need to be vacuumed per table
SELECT n_dead_tup, schemaname, relname FROM pg_stat_all_tables;

-- Total number of dead tuples need to be vacuumed in DB
SELECT sum(n_dead_tup) FROM pg_stat_all_tables;
