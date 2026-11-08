#!/usr/bin/env bash
# The box's binary (selector + LowCardinality patches, PGO): fetched, checked for LowCardinality
# correctness, A/B'd under writes against murasil1, and replayed on the clone against murasil1.
set -uo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"; FORK=$HOME/Projects/clickhouse
source "$REPO/deploy/digitalocean/lib.sh"; load_secrets
S=/private/tmp/claude-501/-Users-adiab-SMS-Platform-sms-platform/5c074344-c32d-415d-aec8-b9cd69438602/scratchpad
BOX=165.22.86.116; ch=$(cat $S/capacity/ch_ip); clone=$(cat $S/rehearsal/ip)
OPTS=(-i "$HOME/.ssh/id_ed25519" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
out=$S/pgo/murasil3.txt; : > $out
scp -q "${OPTS[@]}" root@$BOX:/work/out/clickhouse-stripped.zst $FORK/murasil/out/clickhouse-murasil3.zst 2>/dev/null
(cd $FORK/murasil/out && zstd -d -q -f clickhouse-murasil3.zst -o clickhouse-murasil3 && chmod 755 clickhouse-murasil3 && shasum -a 256 clickhouse-murasil3 | cut -c1-70) >> $out
for h in $ch $clone; do
  scp -3 -q "${OPTS[@]}" root@$BOX:/work/out/clickhouse-stripped.zst root@$h:/opt/murasil/clickhouse-murasil3.zst 2>/dev/null
  remote $h 'cd /opt/murasil && zstd -d -q -f --rm clickhouse-murasil3.zst && chmod 755 clickhouse-murasil3 && cat > m3.yml <<EOF
services:
  clickhouse:
    volumes:
      - /opt/murasil/clickhouse-murasil3:/usr/bin/clickhouse:ro
EOF
echo staged $(hostname)' 2>&1 | grep -v "known hosts" >> $out
done
echo "== LowCardinality check on murasil3 (capacity pair)" >> $out
remote "$ch" 'cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f m3.yml up -d --wait >/dev/null 2>&1; sleep 10; docker exec murasil_clickhouse clickhouse-client --password "$(grep CH_PASSWORD .env | cut -d= -f2)" --query "SELECT version()"' 2>&1 | grep -v "known hosts" >> $out
bash $FORK/murasil/bench/lc_merge_check.sh $ch >> $out 2>&1
echo "== writes A/B: m1 then m3, twice" >> $out
for cycle in 1 2; do
  for build in m1 m3; do
    if [ $build = m3 ]; then ov="-f compose.yml -f m3.yml"; else ov="-f compose.yml"; fi
    remote "$ch" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose $ov up -d --wait >/dev/null 2>&1; sleep 15" 2>&1 | grep -v "known hosts"
    bash $FORK/murasil/bench/merge_ab.sh ${build}_w$cycle 7000 300 "" >> $out 2>&1
  done
done
echo "== reads on the clone: m3 then m1, twice (3 rounds each, sum of medians)" >> $out
for cycle in 1 2; do
  for build in m3 m1; do
    if [ $build = m3 ]; then ov="-f compose.yml -f m3.yml"; else ov="-f compose.yml"; fi
    remote "$clone" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose $ov up -d --wait >/dev/null 2>&1; sleep 30" 2>&1 | grep -v "known hosts"
    remote "$clone" "python3 /tmp/replay.py warm_${build}_$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 1 $CH_DATABASE" >/dev/null 2>&1
    remote "$clone" "python3 /tmp/replay.py ${build}_r$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 3 $CH_DATABASE" 2>/dev/null | python3 -c "import sys,json; rows=[json.loads(l) for l in sys.stdin if l.strip().startswith('{')]; print('$build cycle $cycle', sum(r['ms'] for r in rows), 'ms', sum(r['cpu_ms'] for r in rows), 'cpu_ms', sum(1 for r in rows if r['ms']>300), 'over300')" >> $out
  done
done
echo AFTER_BUILD2_DONE >> $out
