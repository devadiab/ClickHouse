#!/usr/bin/env bash
# The engine profiled under the platform's writes: profiler on, a bench, the samples read.
set -uo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"; FORK=$HOME/Projects/clickhouse
source "$REPO/deploy/digitalocean/lib.sh"
S=/private/tmp/claude-501/-Users-adiab-SMS-Platform-sms-platform/5c074344-c32d-415d-aec8-b9cd69438602/scratchpad
ch=$(cat $S/capacity/ch_ip); app=$(cat $S/capacity/app_ip)
build=${1:-m1}; rate=${2:-7000}; secs=${3:-240}
upload "$ch" /opt/murasil/99-profile.xml "$FORK/murasil/config.d/99-profile.xml.example"
upload "$ch" /opt/murasil/engine_profile.sql "$FORK/murasil/bench/engine_profile.sql"
if [ "$build" = pgo ]; then extra="-f final.yml"; else extra=""; fi
remote "$ch" "cd /opt/murasil && cat > profile.yml <<EOF
services:
  clickhouse:
    volumes:
      - /opt/murasil/99-profile.xml:/etc/clickhouse-server/config.d/99-profile.xml:ro
EOF
docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml $extra -f profile.yml up -d --wait 2>&1 | tail -1; sleep 20
docker exec murasil_clickhouse sh -c 'clickhouse-client --password \"\$CLICKHOUSE_PASSWORD\" --query \"SELECT version(), uptime(), now()\"'" 2>&1 | grep -v "known hosts"
since=$(remote "$ch" "date -u +'%Y-%m-%d %H:%M:%S'" 2>/dev/null | tail -1)
echo "since $since"
remote "$app" "cd /opt/murasil && docker compose exec -T app bin/sms_platform rpc 'case Ops.Bench.run(rate: $rate, seconds: $secs, binds: 48, window: 800, settle: 45, flush_ms: 5000, write: true, out: \"/tmp/bench\") do {:ok, r} -> IO.puts(\"finished #{inspect(get_in(r, [:capacity, :finished_per_s]) || r[:capacity])}\"); other -> IO.inspect(other) end'" 2>&1 | grep -v "known hosts\|FALLBACK" | tail -3 | cut -c1-200
remote "$ch" "docker exec -i murasil_clickhouse sh -c \"clickhouse-client --password \\\"\\\$CLICKHOUSE_PASSWORD\\\" --multiquery --allow_introspection_functions=1 --param_since='$since' --query 'SYSTEM FLUSH LOGS'\"; docker exec -i murasil_clickhouse sh -c \"clickhouse-client --password \\\"\\\$CLICKHOUSE_PASSWORD\\\" --multiquery --allow_introspection_functions=1 --param_since='$since'\" < /opt/murasil/engine_profile.sql" 2>&1 | grep -v "known hosts" > $S/pgo/profile_$build.txt
remote "$ch" "docker exec -i murasil_clickhouse sh -c \"clickhouse-client --password \\\"\\\$CLICKHOUSE_PASSWORD\\\" --param_since='$since' --query \\\"SELECT 'merges' w, round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6) cpu_s, count() n FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND event_time >= {since:DateTime} UNION ALL SELECT 'inserts', round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6), count() FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND event_time >= {since:DateTime} UNION ALL SELECT 'selects', round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6), count() FROM system.query_log WHERE type='QueryFinish' AND query_kind='Select' AND event_time >= {since:DateTime} UNION ALL SELECT 'system merges', round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6), count() FROM system.part_log WHERE event_type='MergeParts' AND database='system' AND event_time >= {since:DateTime} FORMAT PrettyCompactMonoBlock\\\"\"" 2>&1 | grep -v "known hosts" >> $S/pgo/profile_$build.txt
remote "$ch" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose up -d --wait 2>&1 | tail -1" 2>&1 | grep -v "known hosts"
echo PROFILE_DONE >> $S/pgo/profile_$build.txt
