#!/usr/bin/env bash
# lc_merge_check.sh <host> : LowCardinality columns through many small inserts and a merge, against
# plain twins of the same rows. Prints the rows that differ; none is a pass. Needs the server's
# password in /opt/murasil/.env on the host (the capacity pair's layout).
set -euo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"
source "$REPO/deploy/digitalocean/lib.sh"
host=$1
remote "$host" 'docker exec -i murasil_clickhouse sh -c "clickhouse-client --password \"\$CLICKHOUSE_PASSWORD\" --multiquery"' <<'SQL' 2>&1 | { grep -v "known hosts" || true; }
DROP TABLE IF EXISTS lc_check;
DROP TABLE IF EXISTS lc_check_plain;
SET allow_suspicious_low_cardinality_types = 1;
CREATE TABLE lc_check (k UInt64, a LowCardinality(String), b LowCardinality(Nullable(String)), c LowCardinality(UInt16), d String) ENGINE = MergeTree ORDER BY k SETTINGS merge_selector_enable_heuristic_to_remove_small_parts_at_right = 0;
CREATE TABLE lc_check_plain (k UInt64, a String, b Nullable(String), c UInt16, d String) ENGINE = MergeTree ORDER BY k;
SET max_insert_block_size = 100000;
-- 400 inserts, each a part with a few of 60 keys, keys and null share drawn from the batch, rows interleaved by k across parts
INSERT INTO lc_check_plain SELECT number * 400 + batch AS k, concat('key_', toString((number * 7 + batch * 13) % (3 + batch % 57))) AS a, if((number + batch) % 11 = 0, NULL, concat('b', toString((number * 3 + batch) % 97))) AS b, toUInt16((number + batch * 5) % 500) AS c, concat('plain_', toString(number)) AS d FROM numbers(300) ARRAY JOIN range(400) AS batch;
SQL
for batch in $(seq 0 399); do echo "INSERT INTO lc_check SELECT k, a, b, c, d FROM lc_check_plain WHERE k % 400 = $batch;"; done | remote "$host" 'docker exec -i murasil_clickhouse sh -c "clickhouse-client --password \"\$CLICKHOUSE_PASSWORD\" --multiquery"' 2>&1 | { grep -v "known hosts" || true; }
remote "$host" 'docker exec -i murasil_clickhouse sh -c "clickhouse-client --password \"\$CLICKHOUSE_PASSWORD\" --multiquery"' <<'SQL' 2>&1 | { grep -v "known hosts" || true; }
SELECT count() AS parts_before FROM system.parts WHERE active AND table = 'lc_check';
OPTIMIZE TABLE lc_check FINAL;
SELECT count() AS parts_after FROM system.parts WHERE active AND table = 'lc_check';
SELECT 'differences', count() FROM (SELECT k, toString(a) a, toString(b) b, c, d FROM lc_check EXCEPT SELECT k, a, toString(b), c, d FROM lc_check_plain);
SELECT 'differences back', count() FROM (SELECT k, a, toString(b) b, c, d FROM lc_check_plain EXCEPT SELECT k, toString(a), toString(b), c, d FROM lc_check);
SELECT 'rows', count(), uniqExact(a), uniqExact(b), sum(c) FROM lc_check;
SELECT 'rows plain', count(), uniqExact(a), uniqExact(b), sum(c) FROM lc_check_plain;
SELECT 'merged by', part_name, length(merged_from) FROM system.part_log WHERE table = 'lc_check' AND event_type = 'MergeParts' ORDER BY event_time DESC LIMIT 1;
DROP TABLE lc_check;
DROP TABLE lc_check_plain;
SQL
