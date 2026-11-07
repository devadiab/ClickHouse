# Engine patches

Every change to ClickHouse itself on the `murasil` branch, newest first. Settings and
configuration are not patches; they live in `config.d/` and are not listed here.

Base: `v26.10.2.103-stable`.

| Commit | Why | Upstream |
|---|---|---|
| 915eabae1e `SimpleMergeSelector`: a range the right-tail heuristic trimmed has to reach the base on its own | Under the platform's writes (an insert into every table every few seconds, small parts held back by `merge_selector_small_parts_min_count` until thirty wait), the selector merged one large part with one fresh part, over and over: a 116 MiB `dlr_events` part stood at level 80, and two- and three-part merges were 77% of that table's merge CPU and 48% of the ledger's (`system.part_log`, 8 vCPU server, 2026-11-07). The heuristic trimmed the small parts off a range `allow` had accepted for their sake, leaving the large part and the first small one; the estimator now re-checks the trimmed range against the base. On the live server (4 vCPU, 2026-11-07, last 24 h before the fix): 49,591 merges, 45,224 of them of two or three parts, 17,529 of 17,740 merge CPU seconds, 891 GiB written, parts at level 54,757. Until this build is deployed the live tables run with `merge_selector_enable_heuristic_to_remove_small_parts_at_right = 0` (`ALTER TABLE ... MODIFY SETTING`, applied 20:50 UTC), which measured 111/148 -> 93 merge CPU seconds and 17/64 -> 1 tiny merges on the bench (7000 msg/s x 300 s). `clickhouse-examples merge_selector_murasil` replays a partition from `part_log` with the server's settings. | To offer, with the gtest |
| _none before 2026-11-08_ | The slowness the fork was started over (Nov 2026) turned out to be in the platform's own queries and insert batching, fixed there. | |

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
