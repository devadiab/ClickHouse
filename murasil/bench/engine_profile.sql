-- Where the engine's CPU went, from the profiler's samples (config.d/99-profile.xml.example
-- on, a workload run, then this). Run with --allow_introspection_functions=1 and
-- --param_since='2026-11-08 00:00:00'. Background threads are merges, flushes and the
-- schedulers; a query thread is named by its query's kind.
WITH samples AS (
    SELECT t.trace AS trace,
           if(t.query_id = '', 'background', coalesce(q.query_kind, 'query')) AS kind
    FROM system.trace_log AS t
    LEFT JOIN (SELECT query_id, any(query_kind) AS query_kind FROM system.query_log
               WHERE event_time >= {since:DateTime} GROUP BY query_id) AS q ON q.query_id = t.query_id
    WHERE t.trace_type = 'CPU' AND t.event_time >= {since:DateTime}
)
SELECT kind, count() AS samples, round(100 * count() / sum(count()) OVER (), 1) AS pct
FROM samples GROUP BY kind ORDER BY samples DESC
FORMAT PrettyCompactMonoBlock;

-- The functions on the stack of background samples, inclusive: a frame counts once per sample.
WITH samples AS (
    SELECT arrayDistinct(arrayMap(a -> demangle(addressToSymbol(a)), trace)) AS syms
    FROM system.trace_log
    WHERE trace_type = 'CPU' AND query_id = '' AND event_time >= {since:DateTime}
)
SELECT round(100 * count() / (SELECT count() FROM samples), 1) AS pct, count() AS samples,
       substring(arrayJoin(syms), 1, 110) AS frame
FROM samples GROUP BY frame HAVING frame NOT LIKE '' ORDER BY samples DESC LIMIT 60
FORMAT PrettyCompactMonoBlock;

-- Where background samples were, by leaf.
SELECT count() AS samples, substring(demangle(addressToSymbol(trace[1])), 1, 110) AS leaf
FROM system.trace_log WHERE trace_type = 'CPU' AND query_id = '' AND event_time >= {since:DateTime}
GROUP BY leaf ORDER BY samples DESC LIMIT 30
FORMAT PrettyCompactMonoBlock;

-- The same two views for inserts.
WITH ins AS (SELECT query_id FROM system.query_log WHERE query_kind = 'Insert' AND event_time >= {since:DateTime}),
samples AS (
    SELECT arrayDistinct(arrayMap(a -> demangle(addressToSymbol(a)), trace)) AS syms
    FROM system.trace_log WHERE trace_type = 'CPU' AND query_id IN ins AND event_time >= {since:DateTime}
)
SELECT round(100 * count() / (SELECT count() FROM samples), 1) AS pct, count() AS samples,
       substring(arrayJoin(syms), 1, 110) AS frame
FROM samples GROUP BY frame HAVING frame NOT LIKE '' ORDER BY samples DESC LIMIT 60
FORMAT PrettyCompactMonoBlock;

WITH ins AS (SELECT query_id FROM system.query_log WHERE query_kind = 'Insert' AND event_time >= {since:DateTime})
SELECT count() AS samples, substring(demangle(addressToSymbol(trace[1])), 1, 110) AS leaf
FROM system.trace_log WHERE trace_type = 'CPU' AND query_id IN ins AND event_time >= {since:DateTime}
GROUP BY leaf ORDER BY samples DESC LIMIT 30
FORMAT PrettyCompactMonoBlock;
