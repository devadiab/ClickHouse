#!/usr/bin/env bash
# merge_ab.sh <label> <rate> <seconds> [SQL applied before the run]: the platform's write load
# against the capacity ClickHouse, then what the merges and inserts cost in that window.
set -uo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"
source "$REPO/deploy/digitalocean/lib.sh"
S=/private/tmp/claude-501/-Users-adiab-SMS-Platform-sms-platform/5c074344-c32d-415d-aec8-b9cd69438602/scratchpad
ch=$(cat $S/capacity/ch_ip); app=$(cat $S/capacity/app_ip)
label=$1; rate=$2; secs=$3; sql=${4:-}
q() { remote "$ch" 'docker exec -i murasil_clickhouse sh -c "clickhouse-client --password \"\$CLICKHOUSE_PASSWORD\" --database bench_db --multiquery"' 2>&1 | grep -v "known hosts"; }
[ -n "$sql" ] && printf '%s\n' "$sql" | q
since=$(remote "$ch" "date -u +'%Y-%m-%d %H:%M:%S'" 2>/dev/null | tail -1)
remote "$app" "cd /opt/murasil && docker compose exec -T app bin/sms_platform rpc 'Ops.Bench.run(rate: $rate, seconds: $secs, binds: 48, window: 800, settle: 30, flush_ms: 5000, write: true, out: \"/tmp/bench\"); IO.puts(:done)'" 2>&1 | grep -v "known hosts\|FALLBACK" | grep -E "report written|error" | cut -c1-120
sleep 90
until_=$(remote "$ch" "date -u +'%Y-%m-%d %H:%M:%S'" 2>/dev/null | tail -1)
echo "== $label  $since .. $until_  ($sql)"
cat <<EOF | q
SELECT 'inserts' AS what, count() AS n, round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6) AS cpu_s, sum(written_rows) AS rows FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND event_time BETWEEN '$since' AND '$until_'
UNION ALL SELECT 'merges', count(), round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6), sum(rows) FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND event_time BETWEEN '$since' AND '$until_'
UNION ALL SELECT 'tiny merges (<=3 parts)', count(), round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6), sum(rows) FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND length(merged_from) <= 3 AND event_time BETWEEN '$since' AND '$until_'
UNION ALL SELECT 'system log merges', count(), round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6), sum(rows) FROM system.part_log WHERE event_type='MergeParts' AND database='system' AND event_time BETWEEN '$since' AND '$until_'
UNION ALL SELECT 'server cpu (metric_log)', 0, round(sum(ProfileEvent_OSCPUVirtualTimeMicroseconds)/1e6), 0 FROM system.metric_log WHERE event_time BETWEEN '$since' AND '$until_'
FORMAT PrettyCompactMonoBlock;
SELECT table, countIf(length(merged_from) <= 3) AS tiny, count() AS merges, round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6) AS cpu_s, sum(rows) AS merged_rows, max(level) AS max_level FROM (SELECT *, toUInt32(splitByChar('_', part_name)[4]) AS level FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND event_time BETWEEN '$since' AND '$until_') GROUP BY table ORDER BY cpu_s DESC LIMIT 9 FORMAT PrettyCompactMonoBlock;
SELECT table, count() AS parts FROM system.parts WHERE active AND database='bench_db' GROUP BY table ORDER BY parts DESC LIMIT 5 FORMAT PrettyCompactMonoBlock;
EOF
