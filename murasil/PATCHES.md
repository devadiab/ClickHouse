# Engine patches

Every change to ClickHouse itself on the `murasil` branch, newest first. Settings and
configuration are not patches; they live in `config.d/` and are not listed here.

Base: `v26.10.2.103-stable`.

| Commit | Why | Upstream |
|---|---|---|
| 4a1a6e1f54 + bfcc374458 `SerializationLowCardinality`: one scratch column per thread for values read in row formats | Every value of a LowCardinality column read from RowBinary, CSV, TSV or JSONEachRow made a column of the nested type, read into it and freed it: an allocation and a free per value of every such column of every insert, the path the platform's inserts take. A thread now keeps one such column, emptied before each value and replaced when the nested type differs; a value that fails to read drops it. Test: `SerializationLowCardinality.RowFormatValuesSurviveTypeChangesAndFailures`. Gain: in the murasil4 writes A/B (below), since murasil3 predates it. | Worth offering. |
| 43b39ba9e2 `ColumnLowCardinality`: remembers where a source dictionary's keys went | A merge or any row-by-row copy between LowCardinality columns (`insertFrom`, `insertManyFrom`) hashed the value into the destination dictionary for every row. The column now keeps a translation of the current source's keys to its own (reset when the source changes, capped at 65,536 keys), so the hash is computed once per distinct key per source. Checked by `bench/lc_merge_check.sh` (LowCardinality against plain twins, 400 inserts, OPTIMIZE FINAL, EXCEPT both ways: 120,000 rows, 0 differences, on the murasil3 build). Test: `ColumnLowCardinality.InsertFromRemembersKeyTranslations`. | Worth offering. |
| 915eabae1e `SimpleMergeSelector`: a range the right-tail heuristic trimmed has to reach the base on its own | Under the platform's writes (an insert into every table every few seconds, small parts held back by `merge_selector_small_parts_min_count` until thirty wait), the selector merged one large part with one fresh part, over and over: a 116 MiB `dlr_events` part stood at level 80, and two- and three-part merges were 77% of that table's merge CPU and 48% of the ledger's (`system.part_log`, 8 vCPU server, 2026-11-07). The heuristic trimmed the small parts off a range `allow` had accepted for their sake, leaving the large part and the first small one; the estimator now re-checks the trimmed range against the base. On the live server (4 vCPU, 2026-11-07, last 24 h before the fix): 49,591 merges, 45,224 of them of two or three parts, 17,529 of 17,740 merge CPU seconds, 891 GiB written, parts at level 54,757. Until this build is deployed the live tables run with `merge_selector_enable_heuristic_to_remove_small_parts_at_right = 0` (`ALTER TABLE ... MODIFY SETTING`, applied 20:50 UTC), which measured 111/148 -> 93 merge CPU seconds and 17/64 -> 1 tiny merges on the bench (7000 msg/s x 300 s), and on the live server, 45 minutes before against 45 after: 2,273 merges -> 213, 2,133 of two or three parts -> 1, 1,095 merge CPU seconds -> 61, 42.2 GiB written -> 1.7 GiB. `clickhouse-examples merge_selector_murasil` replays a partition from `part_log` with the server's settings. Side by side on the build box (`bench/merge_repro.sh`: a throwaway server per binary, the same 299 inserts of 15-21k rows over 25 minutes into a `dlr_events`-shaped table, heuristic on): official 26.10.2.103 made 12 merges (1 of two or three parts), rewrote 14.5 M rows in 10.4 CPU s and wrote 326 MiB; the patched build 11 merges (0 tiny), 10.3 M rows, 6.6 CPU s, 266 MiB. | To offer, with the gtest |
| _none before 2026-11-08_ | The slowness the fork was started over (Nov 2026) turned out to be in the platform's own queries and insert batching, fixed there. | |

## Builds

| Build | Contents | Measured |
|---|---|---|
| murasil3 (`4dbfb2e9…`, 2026-11-07) | 26.10.2.103 + selector patch + LowCardinality translation cache, ThinLTO, PGO on the platform's inserts, merges and page queries | Against murasil1 (selector patch, no PGO) on the bench pair, 7000 msg/s x 300 s, two cycles each: insert CPU 85/84 -> 61/63 s (-27%), merges of two or three parts 29/61 -> 0/0, merge CPU 125/119 -> 71/244 s (a 5-minute window catches merges unevenly; the repro above is the fair merge comparison). Page queries on the clone (`bench/replay.py`, 3 rounds, sum of medians): 6,897 -> 5,227 ms and 5,715 -> 4,788 ms (-24%, -16%), CPU 13,946 -> 12,035 and 12,792 -> 11,403 ms (-14%, -11%). Unit tests: 36 of the three touched suites pass on the dev build. **On production since 2026-11-08 10:29 UTC** (image `murasil/clickhouse-server:26.10.2-murasil3`, with the two settings below; rows counted equal across 157 tables; way back: volume snapshot `murasil-ch-pre-upgrade-202611081019`, image `…-murasil1`). The per-table mitigation `merge_selector_enable_heuristic_to_remove_small_parts_at_right = 0` was reset on its 115 tables the same hour. |
| murasil4 (`7567f059…`, 2026-11-08) | murasil3 + patch 3 + BOLT (instrumentation profile: 7 minutes of the bench's writes, 2 rounds of the page queries; `-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh`) | Against murasil3, same hour, two cycles: insert CPU 64/62 -> 50/51 s (-20%; patch 3 and BOLT together), merge CPU per row the same. Page queries 4,921/5,137 -> 5,595/6,101 ms (+14%, +19%), CPU +13%/+15%: the read paths were cold in a profile dominated by writes and got split away. Not deployed. Next: the reads profile weighted (murasil5) and patch 3 without BOLT (murasil6), measured the same way. |

## Settings measured (2026-11-08, bench pair, 7000 msg/s x 300 s, murasil3, each twice alternating with the base)

| Setting | Insert CPU (base 62 s, 61 s) | Merge CPU per merged row (base 0.94 us, 0.87 us) | Kept |
|---|---|---|---|
| jemalloc `dirty_decay_ms:60000` (stock 5000) | 59 s, 59 s | 0.91, 0.99 | Yes, `ENV MALLOC_CONF` in `murasil/docker/Dockerfile` |
| `low_cardinality_use_single_dictionary_for_part = 1` | 62 s, 63 s | 1.05, 1.01 | No |
| vertical merges for every part (`vertical_merge_algorithm_min_rows_to_activate = 1`, `_min_columns_to_activate = 1`) | 62 s, 62 s | 0.82, 0.80 | Yes, `config.d/10-merges.xml` |

Merge CPU in a 5-minute window swings with which merges happen to land in it (54 to 185 s here), so merges compare per merged row. `bench/knobs_round2.sh` runs the round.

## Candidates

Measured against the platform's own workload (the platform's
`docs/performance/clickhouse.md`). So far every gain came from moving to 26.10, from settings
in `config.d/`, from the platform's own schema and from its insert format, and none needed
a change to the engine:

- **A build for this workload.** `cmake/profile_optimization.cmake` supports PGO and BOLT
  against a chosen workload. Profiling on the platform's inserts, merges and page queries
  is the next engine-level step, measured before and after with a replay of production's
  query log.
- **Merge selection.** `merge_selector_small_parts_min_count` makes the selector hand a round
  to a range holding the biggest part once a partition nears `max_parts_to_lower_base`: the
  setting at 60 read 172 GB where the default read 115 MB. A guard in `SimpleMergeSelector`
  would make the setting safe at any value; worth offering upstream.
- **Query guard.** A per-profile `max_rows_to_read` catches a page query that forgot
  its date bound. Settings first.
