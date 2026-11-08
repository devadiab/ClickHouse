#!/usr/bin/env bash
# bench_run.sh <rate> <seconds>: runs the platform's write bench on this app host, detached from
# whoever started it; /tmp/bench_done appears when it ends and /tmp/bench_run.log holds its output.
cd /opt/murasil || exit 1
rm -f /tmp/bench_done
nohup sh -c "docker compose exec -T app bin/sms_platform rpc 'Ops.Bench.run(rate: $1, seconds: $2, binds: 48, window: 800, settle: 30, flush_ms: 5000, write: true, out: \"/tmp/bench\"); IO.puts(:done)' > /tmp/bench_run.log 2>&1; touch /tmp/bench_done" > /dev/null 2>&1 < /dev/null &
echo started
