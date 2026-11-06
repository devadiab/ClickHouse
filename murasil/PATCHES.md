# Engine patches

Every change to ClickHouse itself on the `murasil` branch, newest first. Settings and
configuration are not patches; they live in `config.d/` and are not listed here.

Base: `v26.10.2.103-stable`.

| Commit | Why | Upstream |
|---|---|---|
| _none yet_ | The slowness the fork was started over (Nov 2026) turned out to be in the platform's own queries and insert batching, fixed there. | |

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
