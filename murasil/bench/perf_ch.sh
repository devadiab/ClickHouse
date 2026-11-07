#!/usr/bin/env bash
# perf on the ClickHouse server under the platform's writes, folded per thread name.
set -uo pipefail
REPO="/Users/adiab/SMS Platform/sms_platform"; FORK=$HOME/Projects/clickhouse
source "$REPO/deploy/digitalocean/lib.sh"
S=/private/tmp/claude-501/-Users-adiab-SMS-Platform-sms-platform/5c074344-c32d-415d-aec8-b9cd69438602/scratchpad
ch=$(cat $S/capacity/ch_ip); app=$(cat $S/capacity/app_ip); label=${1:-m1}; rate=${2:-7000}
upload "$ch" /opt/murasil/perf_fold.py "$FORK/murasil/bench/perf_fold.py"
( remote "$app" "cd /opt/murasil && docker compose exec -T app bin/sms_platform rpc 'Ops.Bench.run(rate: $rate, seconds: 150, binds: 48, window: 800, settle: 30, flush_ms: 5000, write: true, out: \"/tmp/bench\"); IO.puts(:done)'" > $S/pgo/perf_${label}_bench.log 2>&1 ) &
sleep 45
remote "$ch" 'pid=$(docker inspect -f "{{.State.Pid}}" murasil_clickhouse); perf record -q -F 199 -g -p $pid -o /tmp/ch.data -- sleep 60 >/dev/null 2>&1; echo recorded $(stat -c %s /tmp/ch.data)
perf report -i /tmp/ch.data --no-children --sort comm -g none --stdio 2>/dev/null | grep -v "^#" | grep -v "^$" | head -10
perf script -i /tmp/ch.data -F comm,ip,sym,dso 2>/dev/null > /tmp/ch.txt
for c in MergeMutate HTTPHandler QueryPipelineEx; do echo "=== $c"; python3 /opt/murasil/perf_fold.py /tmp/ch.txt $c 1.5 | head -90; done' 2>&1 | grep -v "known hosts" > $S/pgo/perf_$label.txt
wait
echo PERF_DONE >> $S/pgo/perf_$label.txt
