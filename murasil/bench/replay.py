#!/usr/bin/env python3
"""Replay production's own queries against a server: python3 replay.py <label> <password> [rounds].
Runs on the rehearsal droplet against 127.0.0.1:8123, in series, and prints per-query results as JSON lines."""
import base64, json, sys, time, urllib.parse, urllib.request
label, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 3
DB = sys.argv[5] if len(sys.argv) > 5 else "sms_platform"
AUTH = base64.b64encode(f"{user}:{password}".encode()).decode()
def q(sql, **params):
    u = "http://127.0.0.1:8123/?" + urllib.parse.urlencode({"database": DB, **params})
    req = urllib.request.Request(u, data=sql.encode())
    req.add_header("Authorization", "Basic " + AUTH)
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read().decode()
rows = [json.loads(l) for l in open("/tmp/queries.jsonl")]
failures = 0
for i, r in enumerate(rows):
    sql = r["query"]
    for k in range(rounds):
        try:
            q(sql.rstrip().rstrip(";") + " FORMAT Null", log_comment=f"replay|{label}|{i}", use_query_cache=0, max_execution_time=120)
        except Exception as e:
            failures += 1
            detail = e.read().decode()[:160] if hasattr(e, "read") else str(e)[:160]
            print(f"FAILED {i} {detail}", file=sys.stderr, flush=True)
            break
q("SYSTEM FLUSH LOGS")
print(q(f"""SELECT splitByChar('|', log_comment)[3] AS i, count() n, round(quantile(0.5)(query_duration_ms)) ms, round(quantile(0.5)(read_rows)) rows_read,
        round(quantile(0.5)(ProfileEvents['OSCPUVirtualTimeMicroseconds'])/1000) cpu_ms, round(quantile(0.5)(memory_usage)/1048576,1) mem_mib
        FROM system.query_log WHERE type='QueryFinish' AND log_comment LIKE 'replay|{label}|%' GROUP BY i ORDER BY toUInt32(i) FORMAT JSONEachRow"""))
print(f"FAILURES {failures}", file=sys.stderr)
