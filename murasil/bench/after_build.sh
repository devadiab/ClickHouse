#!/usr/bin/env bash
# Once FINAL_DONE: fetch the binary, A/B it under writes on the capacity pair against murasil1, replay
# production's queries on the clone. Leaves the numbers in $S/pgo/murasil2_*.txt.
set -uo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"; FORK=$HOME/Projects/clickhouse
source "$REPO/deploy/digitalocean/lib.sh"; load_secrets
S=/private/tmp/claude-501/-Users-adiab-SMS-Platform-sms-platform/5c074344-c32d-415d-aec8-b9cd69438602/scratchpad
PGO=165.232.95.133; ch=$(cat $S/capacity/ch_ip); clone=$(cat $S/rehearsal/ip)
OPTS=(-i "$HOME/.ssh/id_ed25519" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)
until ssh "${OPTS[@]}" root@$PGO 'tail -c 4000 /root/final.log | grep -qE "FINAL_DONE|ninja: build stopped"' 2>/dev/null; do sleep 120; done
ssh "${OPTS[@]}" root@$PGO 'tail -c 4000 /root/final.log | grep -E "FINAL_DONE|build stopped|sha256|version" | tail -4' 2>/dev/null
ssh "${OPTS[@]}" root@$PGO 'test -f /out/clickhouse' 2>/dev/null || { echo "NO BINARY"; exit 1; }
ssh "${OPTS[@]}" root@$PGO 'cd /out && zstd -T0 -3 -q -f clickhouse -o clickhouse-murasil2.zst && ls -la clickhouse-murasil2.zst | cut -c20-' 2>/dev/null
scp -q "${OPTS[@]}" root@$PGO:/out/clickhouse-murasil2.zst $FORK/murasil/out/clickhouse-murasil2.zst 2>/dev/null
(cd $FORK/murasil/out && zstd -d -q -f clickhouse-murasil2.zst -o clickhouse-murasil2 && chmod 755 clickhouse-murasil2 && shasum -a 256 clickhouse-murasil2 | cut -c1-70)
# to the capacity ClickHouse and the clone, straight from the build droplet
scp -3 -q "${OPTS[@]}" root@$PGO:/out/clickhouse-murasil2.zst root@$ch:/opt/murasil/clickhouse-murasil2.zst 2>/dev/null
scp -3 -q "${OPTS[@]}" root@$PGO:/out/clickhouse-murasil2.zst root@$clone:/opt/murasil/clickhouse-murasil2.zst 2>/dev/null
for h in $ch $clone; do remote $h 'cd /opt/murasil && zstd -d -q -f --rm clickhouse-murasil2.zst && chmod 755 clickhouse-murasil2 && cat > m2.yml <<EOF
services:
  clickhouse:
    volumes:
      - /opt/murasil/clickhouse-murasil2:/usr/bin/clickhouse:ro
EOF
echo staged' 2>&1 | grep -v "known hosts"; done
echo "== writes A/B (merge_ab.sh), murasil1 then murasil2, twice" > $S/pgo/murasil2_writes.txt
for cycle in 1 2; do
  for build in m1 m2; do
    if [ $build = m2 ]; then ov="-f compose.yml -f m2.yml"; else ov="-f compose.yml"; fi
    remote "$ch" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose $ov up -d --wait >/dev/null 2>&1; sleep 15; docker exec murasil_clickhouse clickhouse-client --password \"\$(grep CH_PASSWORD .env | cut -d= -f2)\" --query 'SELECT version()'" 2>&1 | grep -v "known hosts"
    bash $FORK/murasil/bench/merge_ab.sh ${build}_c$cycle 7000 300 "" >> $S/pgo/murasil2_writes.txt 2>&1
  done
done
echo "== reads on the clone: murasil2 then murasil1 (pgo numbers are in compare_abc)" > $S/pgo/murasil2_reads.txt
for cycle in 1 2; do
  remote "$clone" 'cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f m2.yml up -d --wait >/dev/null 2>&1; sleep 30' 2>&1 | grep -v "known hosts"
  remote "$clone" "python3 /tmp/replay.py warm_m2_$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 1 $CH_DATABASE" >/dev/null 2>&1
  remote "$clone" "python3 /tmp/replay.py m2_$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 3 $CH_DATABASE" 2>/dev/null | python3 -c 'import sys,json; rows=[json.loads(l) for l in sys.stdin if l.strip().startswith("{")]; print("m2 cycle", sum(r["ms"] for r in rows), "ms", sum(r["cpu_ms"] for r in rows), "cpu_ms", sum(1 for r in rows if r["ms"]>300), "over300")' >> $S/pgo/murasil2_reads.txt
  remote "$clone" 'cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose up -d --wait >/dev/null 2>&1; sleep 30' 2>&1 | grep -v "known hosts"
  remote "$clone" "python3 /tmp/replay.py warm_m1_$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 1 $CH_DATABASE" >/dev/null 2>&1
  remote "$clone" "python3 /tmp/replay.py m1_$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 3 $CH_DATABASE" 2>/dev/null | python3 -c 'import sys,json; rows=[json.loads(l) for l in sys.stdin if l.strip().startswith("{")]; print("m1 cycle", sum(r["ms"] for r in rows), "ms", sum(r["cpu_ms"] for r in rows), "cpu_ms", sum(1 for r in rows if r["ms"]>300), "over300")' >> $S/pgo/murasil2_reads.txt
done
echo AFTER_BUILD_DONE >> $S/pgo/murasil2_reads.txt
