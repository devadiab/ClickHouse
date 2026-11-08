#!/usr/bin/env bash
# Server-side knobs on the bench pair, each twice alternating with the base, under the same
# writes (7000 msg/s x 300 s): jemalloc dirty_decay_ms, one dictionary per part for
# LowCardinality, vertical merges for every part. knobs_round2.sh <build override, e.g. m4>
set -uo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"; FORK=$HOME/Projects/clickhouse
source "$REPO/deploy/digitalocean/lib.sh"
S=/private/tmp/claude-501/-Users-adiab-SMS-Platform-sms-platform/5c074344-c32d-415d-aec8-b9cd69438602/scratchpad
ch=$(cat $S/capacity/ch_ip); build=${1:-m3}
out=$S/pgo/knobs_round2.txt; : > $out
q() { remote "$ch" 'docker exec -i murasil_clickhouse sh -c "clickhouse-client --password \"\$CLICKHOUSE_PASSWORD\" --database bench_db --multiquery"' 2>&1 | grep -v "known hosts"; }
restart() { remote "$ch" "cd /opt/murasil && docker compose stop clickhouse >/dev/null 2>&1; docker compose -f compose.yml -f $build.yml $1 up -d --wait 2>&1 | tail -1; sleep 15" 2>&1 | grep -v "known hosts" >> $out; }
remote "$ch" 'cd /opt/murasil && cat > vertical.xml <<EOF
<clickhouse><merge_tree><vertical_merge_algorithm_min_rows_to_activate>1</vertical_merge_algorithm_min_rows_to_activate><vertical_merge_algorithm_min_columns_to_activate>1</vertical_merge_algorithm_min_columns_to_activate></merge_tree></clickhouse>
EOF
cat > vertical.yml <<EOF
services:
  clickhouse:
    volumes:
      - /opt/murasil/vertical.xml:/etc/clickhouse-server/config.d/99-vertical.xml:ro
EOF
grep -l "" malloc.yml lc.yml vertical.yml' 2>&1 | grep -v "known hosts" >> $out
restart ""
echo "SELECT concat('ALTER TABLE \`', name, '\` MODIFY SETTING merge_selector_enable_heuristic_to_remove_small_parts_at_right = 0;') FROM system.tables WHERE database='bench_db' AND engine LIKE '%MergeTree' FORMAT TSVRaw" | q > $S/pgo/bench_off.sql
q < $S/pgo/bench_off.sql >> $out 2>&1
echo "heuristic off on $(wc -l < $S/pgo/bench_off.sql) bench tables" >> $out
for cycle in 1 2; do
  restart "";                echo "== r2_base_$cycle" >> $out;     bash $FORK/murasil/bench/merge_ab.sh r2_base_$cycle 7000 300 "" >> $out 2>&1
  restart "-f malloc.yml";   echo "== r2_malloc_$cycle" >> $out;   bash $FORK/murasil/bench/merge_ab.sh r2_malloc_$cycle 7000 300 "" >> $out 2>&1
  restart "-f lc.yml";       echo "== r2_lcsingle_$cycle" >> $out; bash $FORK/murasil/bench/merge_ab.sh r2_lcsingle_$cycle 7000 300 "" >> $out 2>&1
  restart "-f vertical.yml"; echo "== r2_vertical_$cycle" >> $out; bash $FORK/murasil/bench/merge_ab.sh r2_vertical_$cycle 7000 300 "" >> $out 2>&1
done
restart ""
echo KNOBS2_DONE >> $out
