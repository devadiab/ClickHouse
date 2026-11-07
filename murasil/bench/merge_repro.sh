#!/usr/bin/env bash
# merge_repro.sh <binary> <port> <minutes>: a throwaway server on the build box fed the way the
# platform writes (a small insert every 5 s into a table shaped like dlr_events, with the fork's
# merge settings), then every merge it made. Run two side by side to compare builds.
set -uo pipefail
bin=$1; port=$2; minutes=${3:-20}
dir=/work/repro_$port; rm -rf $dir; mkdir -p $dir/data $dir/log
cat > $dir/config.xml <<EOF
<clickhouse>
  <logger><level>warning</level><log>$dir/log/server.log</log><errorlog>$dir/log/err.log</errorlog></logger>
  <tcp_port>$((port+1))</tcp_port><http_port>$port</http_port>
  <path>$dir/data/</path><tmp_path>$dir/data/tmp/</tmp_path>
  <user_files_path>$dir/data/user_files/</user_files_path>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default><async_insert>0</async_insert><query_profiler_real_time_period_ns>0</query_profiler_real_time_period_ns><query_profiler_cpu_time_period_ns>0</query_profiler_cpu_time_period_ns></default></profiles>
  <quotas><default></default></quotas>
  <merge_tree><merge_selector_small_parts_min_count>30</merge_selector_small_parts_min_count><merge_selector_base>10</merge_selector_base></merge_tree>
  <part_log><database>system</database><table>part_log</table><flush_interval_milliseconds>2000</flush_interval_milliseconds></part_log>
  <query_metric_log remove="remove"/><trace_log remove="remove"/><metric_log remove="remove"/><asynchronous_metric_log remove="remove"/><text_log remove="remove"/><query_log remove="remove"/>
  <max_server_memory_usage_to_ram_ratio>0.2</max_server_memory_usage_to_ram_ratio>
  <mark_cache_size>268435456</mark_cache_size>
</clickhouse>
EOF
$bin server --config-file=$dir/config.xml --pid-file=$dir/pid --daemon
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$port/?query=SELECT%201" >/dev/null 2>&1 && break; sleep 1; done
q() { curl -fsS "http://127.0.0.1:$port/" --data-binary "$1"; }
q "CREATE TABLE dlr (tenant_id LowCardinality(String), message_id String, customer_id LowCardinality(String), supplier_id LowCardinality(String) DEFAULT '', status LowCardinality(String), error_code LowCardinality(String) DEFAULT '', event_ts DateTime, event_date Date DEFAULT toDate(event_ts)) ENGINE = MergeTree PARTITION BY toYYYYMM(event_date) ORDER BY (tenant_id, message_id, event_ts) TTL event_date + toIntervalYear(1)"
echo "server $($bin local -q "SELECT version()") on :$port, inserting for $minutes min"
end=$((SECONDS + minutes*60)); n=0
while [ $SECONDS -lt $end ]; do
  rows=$((15000 + RANDOM % 6000))
  q "INSERT INTO dlr (tenant_id, message_id, customer_id, supplier_id, status, error_code, event_ts) SELECT 'bench', lower(hex(randomString(11))), concat('cus-', toString(rand() % 27)), concat('sup-', toString(rand() % 15)), ['delivered','delivered','delivered','undeliverable','expired'][1 + rand() % 5], if(rand() % 20 = 0, 'ERR', ''), now() - (rand() % 30) FROM numbers($rows)"
  n=$((n+1)); sleep 5
done
q "SYSTEM FLUSH LOGS"
echo "== $bin: $n inserts"
q "SELECT count() AS merges, countIf(length(merged_from) <= 3) AS tiny, sum(rows) AS rows_merged, round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6, 1) AS merge_cpu_s, formatReadableSize(sum(size_in_bytes)) AS written, max(toUInt32(splitByChar('_', part_name)[4])) AS max_level FROM system.part_log WHERE event_type = 'MergeParts' AND table = 'dlr' FORMAT PrettyCompactMonoBlock"
q "SELECT count() parts, formatReadableSize(sum(bytes_on_disk)) sz, max(level) max_level FROM system.parts WHERE active AND table = 'dlr' FORMAT PrettyCompactMonoBlock"
q "SELECT event_time, length(merged_from) n, formatReadableSize(size_in_bytes) sz, part_name FROM system.part_log WHERE event_type = 'MergeParts' AND table = 'dlr' AND length(merged_from) <= 3 ORDER BY event_time LIMIT 8 FORMAT PrettyCompactMonoBlock"
q "SELECT sum(rows) inserted FROM system.part_log WHERE event_type = 'NewPart' AND table = 'dlr' FORMAT TSV"
kill $(cat $dir/pid) 2>/dev/null
