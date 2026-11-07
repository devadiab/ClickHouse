#!/usr/bin/env python3
"""perf_fold.py <perf script output> [comm] [limit%]: inclusive share of each frame among the
samples of one thread name (default: all), a frame counted once per sample, and the leaves."""
import sys, re, collections
path = sys.argv[1]; want = sys.argv[2] if len(sys.argv) > 2 else None
limit = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
samples = []; stack = []; comm = None
for line in open(path, errors='replace'):
    if not line.strip():
        if stack and (want is None or comm == want): samples.append(stack)
        stack = []; comm = None; continue
    if line[0] not in ' \t':
        comm = line.split()[0]; continue
    parts = line.strip().split(' ', 1)
    if len(parts) < 2: continue
    sym = re.sub(r'\+0x[0-9a-f]+ \(.*$', '', parts[1]).strip()
    sym = re.sub(r'\(.*', '', sym).strip() if sym.startswith('[unknown]') else sym
    stack.append(sym[:110])
if stack and (want is None or comm == want): samples.append(stack)
n = len(samples)
print(f"{n} samples for {want or 'all threads'}")
incl = collections.Counter(); leaf = collections.Counter()
for st in samples:
    for s in set(st): incl[s] += 1
    leaf[st[0] if st else '?'] += 1
print("== inclusive")
for s, c in incl.most_common(200):
    p = 100.0 * c / n
    if p < limit: break
    print(f"{p:5.1f}  {s}")
print("== leaves")
for s, c in leaf.most_common(25): print(f"{100.0*c/n:5.1f}  {s}")
