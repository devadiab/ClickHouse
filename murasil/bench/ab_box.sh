#!/usr/bin/env bash
# ab_box.sh <label> <build> <build>...: run from the build box (it holds a key for the bench
# hosts), so a laptop's dropped connection cannot cut a round short. Each build, twice,
# alternating: the platform's writes on the capacity pair (180 s) with insert CPU and merge
# CPU per merged row from the server's logs, and at the same time the page-query replay on the
# clone (3 rounds, sum of medians). Builds are compose overrides mN.yml on the hosts.
set -uo pipefail
label=$1; shift; builds=("$@")
S="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"
cap=206.81.20.113; app=207.154.225.71; clone=104.248.32.148
secs=${SECS:-180}; out=/work/ab_$label.txt; : > $out
r() { ssh $S root@$1 "${@:2}"; }
q() { r $cap 'docker exec -i murasil_clickhouse sh -c "clickhouse-client --password \"\$CLICKHOUSE_PASSWORD\" --database bench_db --multiquery"'; }
switch() { r $1 "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f $2.yml up -d --wait >/dev/null 2>&1; sleep $3"; }
echo "== $label: ${builds[*]} x2, writes ${secs}s $(date -u +%H:%M)" >> $out
(
for cycle in 1 2; do for b in "${builds[@]}"; do
  switch $cap $b 15
  since=$(r $cap "date -u +'%Y-%m-%d %H:%M:%S'")
  r $app "bash /opt/murasil/bench_run.sh 7000 $secs" >/dev/null
  for _ in $(seq 1 $(( (secs + 240) / 10 ))); do sleep 10; r $app "test -f /tmp/bench_done" 2>/dev/null && break; done
  sleep 60
  until_=$(r $cap "date -u +'%Y-%m-%d %H:%M:%S'")
  printf '%s' "SELECT '${b}_w$cycle' AS run, (SELECT count() FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND event_time BETWEEN '$since' AND '$until_') AS inserts, (SELECT round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6, 1) FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND event_time BETWEEN '$since' AND '$until_') AS insert_cpu_s, (SELECT count() FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND event_time BETWEEN '$since' AND '$until_') AS merges, (SELECT countIf(length(merged_from) <= 3) FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND event_time BETWEEN '$since' AND '$until_') AS tiny, (SELECT round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1e6, 1) FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND event_time BETWEEN '$since' AND '$until_') AS merge_cpu_s, (SELECT round(sum(ProfileEvents['OSCPUVirtualTimeMicroseconds']) / sum(rows), 3) FROM system.part_log WHERE event_type='MergeParts' AND database='bench_db' AND event_time BETWEEN '$since' AND '$until_') AS merge_us_per_row FORMAT TSVWithNames" | q >> $out 2>&1
done; done
switch $cap m3 5
echo WRITES_DONE >> $out
) &
(
rout=/work/ab_${label}_reads.txt; : > $rout
for cycle in 1 2; do for b in "${builds[@]}"; do
  switch $clone $b 30
  r $clone "python3 /tmp/replay.py warm_${b}_$cycle default \"\$(cat /tmp/ch.pass)\" 1 sms_platform" >/dev/null 2>&1
  r $clone "python3 /tmp/replay.py ${b}_r$cycle default \"\$(cat /tmp/ch.pass)\" 3 sms_platform 2>/dev/null | python3 -c \"import sys,json; rows=[json.loads(l) for l in sys.stdin if l.strip().startswith('{')]; print('${b}_r$cycle', len(rows), 'queries', sum(r['ms'] for r in rows), 'ms', sum(r['cpu_ms'] for r in rows), 'cpu_ms', sum(1 for r in rows if r['ms']>300), 'over300')\"" >> $rout 2>&1
done; done
switch $clone m3 5
echo READS_DONE >> $rout
) &
wait
cat /work/ab_${label}_reads.txt >> $out
echo AB_DONE $(date -u +%H:%M) >> $out
