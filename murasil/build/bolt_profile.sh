#!/usr/bin/env bash
# BOLT on top of PGO: the instrumented binary the box made (/work/bolt/clickhouse-inst, one profile
# file rewritten every minute, so the server runs without its watchdog fork) runs the
# platform's writes on the capacity pair and the page queries on the clone, its profile is merged
# on the box, the relocatable binary is laid out from it (murasil4), and murasil4 is A/B'd against
# the build it came from (murasil3) under the same writes and reads.
set -uo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"; FORK=$HOME/Projects/clickhouse
source "$REPO/deploy/digitalocean/lib.sh"; load_secrets
S=/private/tmp/claude-501/-Users-adiab-SMS-Platform-sms-platform/5c074344-c32d-415d-aec8-b9cd69438602/scratchpad
BOX=165.22.86.116; ch=$(cat $S/capacity/ch_ip); clone=$(cat $S/rehearsal/ip)
OPTS=(-i "$HOME/.ssh/id_ed25519" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
box() { ssh "${OPTS[@]}" root@$BOX "$@"; }
out=$S/pgo/murasil4.txt; [[ "${RESUME_FROM:-}" == merge ]] || : > $out
say() { echo "== $* $(date -u +%H:%M)" >> $out; }

# RESUME_FROM=merge skips the profiling runs and uses the writes.fdata and reads.fdata already on the hosts.
if [[ "${RESUME_FROM:-}" != merge ]]; then
say "stage the instrumented binary"
box 'cd /work/bolt && zstd -T0 -3 -q -f clickhouse-inst -o clickhouse-inst.zst && ls -la clickhouse-inst.zst | cut -c1-80' >> $out 2>&1
hosts="$ch $clone"; [[ -n "${SKIP_READS:-}" ]] && hosts="$ch"   # SKIP_READS=1 keeps the clone's reads.fdata
for h in $hosts; do
  box "scp -q -o StrictHostKeyChecking=accept-new /work/bolt/clickhouse-inst.zst root@$h:/opt/murasil/clickhouse-inst.zst"
  upload $h /opt/murasil/settle_profile.sh $FORK/murasil/bench/settle_profile.sh
  remote $h 'cd /opt/murasil && zstd -d -q -f --rm clickhouse-inst.zst && chmod 755 clickhouse-inst && mkdir -p bolt && chmod 777 bolt && rm -f bolt/*.fdata && cat > inst.yml <<EOF
services:
  clickhouse:
    volumes:
      - /opt/murasil/clickhouse-inst:/usr/bin/clickhouse:ro
      - /opt/murasil/bolt:/bolt
    environment:
      CLICKHOUSE_WATCHDOG_ENABLE: "0"
EOF
echo staged $(hostname)' 2>&1 | grep -v "known hosts" >> $out
done

say "writes on the instrumented binary (capacity pair)"
remote "$ch" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f inst.yml up -d --wait 2>&1 | tail -1; touch bolt/STARTED; sleep 20" 2>&1 | grep -v "known hosts" >> $out
bash $FORK/murasil/bench/merge_ab.sh inst_w 7000 420 "" >> $out 2>&1
# The instrumented server dumps its profile 600 s after it starts (and then every 600 s), a dump
# the stop at exit has twice cut short; the copy is taken once that first dump is written.
remote "$ch" "cd /opt/murasil && until [ \$(( \$(date +%s) - \$(stat -c %Y bolt/STARTED) )) -ge 660 ]; do sleep 5; done; bash settle_profile.sh bolt/prof.fdata bolt/writes.fdata 0 && docker compose stop -t 300 clickhouse >/dev/null 2>&1; ls -la bolt | cut -c1-90" 2>&1 | grep -v "known hosts" >> $out

if [[ -z "${SKIP_READS:-}" ]]; then
say "reads on the instrumented binary (clone)"
remote "$clone" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f inst.yml up -d --wait 2>&1 | tail -1; touch bolt/STARTED; sleep 30" 2>&1 | grep -v "known hosts" >> $out
remote "$clone" "python3 /tmp/replay.py inst_warm $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 1 $CH_DATABASE" >/dev/null 2>&1
remote "$clone" "python3 /tmp/replay.py inst_r $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 2 $CH_DATABASE" >/dev/null 2>&1
remote "$clone" "cd /opt/murasil && until [ \$(( \$(date +%s) - \$(stat -c %Y bolt/STARTED) )) -ge 660 ]; do sleep 5; done; bash settle_profile.sh bolt/prof.fdata bolt/reads.fdata 0 && docker compose stop -t 300 clickhouse >/dev/null 2>&1; ls -la bolt | cut -c1-90" 2>&1 | grep -v "known hosts" >> $out

fi
fi

say "merge and lay out on the box"
box 'rm -rf /work/bolt/fdata && mkdir -p /work/bolt/fdata/w /work/bolt/fdata/r'
box "scp -q -o StrictHostKeyChecking=accept-new root@$ch:/opt/murasil/bolt/writes.fdata /work/bolt/fdata/w/ && scp -q -o StrictHostKeyChecking=accept-new root@$clone:/opt/murasil/bolt/reads.fdata /work/bolt/fdata/r/"
box 'cd /work/bolt && ls -la fdata/w fdata/r | cut -c1-90 && docker run --rm -v /work:/work -w /work/bolt murasil/ch-toolchain bash -c "set -e
merge-fdata-22 \$(find fdata -name \"*.fdata\" -size +1M) > merged.fdata && ls -la merged.fdata | cut -c1-80
llvm-bolt-22 clickhouse-relocs -o clickhouse-bolt -data=merged.fdata -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -dyno-stats -use-gnu-stack 2>&1 | grep -E \"BOLT-INFO: (dyno|[0-9]+ out of|[0-9.]+% of)|BOLT-WARNING|BOLT-ERROR\" | head -20
llvm-strip-22 -o /work/out/clickhouse-bolt-stripped --strip-debug --remove-section=.comment --remove-section=.note clickhouse-bolt
/work/out/clickhouse-bolt-stripped --version && sha256sum /work/out/clickhouse-bolt-stripped && zstd -T0 -3 -q -f /work/out/clickhouse-bolt-stripped -o /work/out/clickhouse-bolt-stripped.zst"' >> $out 2>&1

say "stage murasil4"
if ! box 'test -s /work/out/clickhouse-bolt-stripped.zst'; then echo "BOLT made no binary; nothing to stage" >> $out; echo BOLT_DONE >> $out; exit 1; fi
scp -q "${OPTS[@]}" root@$BOX:/work/out/clickhouse-bolt-stripped.zst $FORK/murasil/out/clickhouse-murasil4.zst 2>/dev/null
(cd $FORK/murasil/out && zstd -d -q -f clickhouse-murasil4.zst -o clickhouse-murasil4 && chmod 755 clickhouse-murasil4 && shasum -a 256 clickhouse-murasil4 | cut -c1-70) >> $out
for h in $ch $clone; do
  box "scp -q -o StrictHostKeyChecking=accept-new /work/out/clickhouse-bolt-stripped.zst root@$h:/opt/murasil/clickhouse-murasil4.zst"
  remote $h 'cd /opt/murasil && zstd -d -q -f --rm clickhouse-murasil4.zst && chmod 755 clickhouse-murasil4 && cat > m4.yml <<EOF
services:
  clickhouse:
    volumes:
      - /opt/murasil/clickhouse-murasil4:/usr/bin/clickhouse:ro
EOF
echo staged $(hostname)' 2>&1 | grep -v "known hosts" >> $out
done

say "writes A/B: m3 then m4, twice"
for cycle in 1 2; do
  for build in m3 m4; do
    remote "$ch" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f $build.yml up -d --wait >/dev/null 2>&1; sleep 15" 2>&1 | grep -v "known hosts"
    bash $FORK/murasil/bench/merge_ab.sh ${build}_w$cycle 7000 300 "" >> $out 2>&1
  done
done
say "reads on the clone: m4 then m3, twice (3 rounds each, sum of medians)"
for cycle in 1 2; do
  for build in m4 m3; do
    remote "$clone" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f $build.yml up -d --wait >/dev/null 2>&1; sleep 30" 2>&1 | grep -v "known hosts"
    remote "$clone" "python3 /tmp/replay.py warm_${build}_$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 1 $CH_DATABASE" >/dev/null 2>&1
    remote "$clone" "python3 /tmp/replay.py ${build}_r$cycle $CH_USERNAME \"\$(cat /tmp/ch.pass)\" 3 $CH_DATABASE" 2>/dev/null | python3 -c "import sys,json; rows=[json.loads(l) for l in sys.stdin if l.strip().startswith('{')]; print('$build cycle $cycle', sum(r['ms'] for r in rows), 'ms', sum(r['cpu_ms'] for r in rows), 'cpu_ms', sum(1 for r in rows if r['ms']>300), 'over300')" >> $out 2>&1
  done
done
remote "$ch" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f m3.yml up -d --wait >/dev/null 2>&1" 2>&1 | grep -v "known hosts"
echo BOLT_DONE >> $out
