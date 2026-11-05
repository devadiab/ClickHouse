# Engine patches

Every change to ClickHouse itself on the `murasil` branch, newest first. Settings and
configuration are not patches; they live in `config.d/` and are not listed here.

Base: `v26.10.2.103-stable`.

| Commit | Why | Upstream |
|---|---|---|
| _none yet_ | The slowness the fork was started over (Nov 2026) turned out to be in the platform's own queries and insert batching, fixed there. | |

## Candidates

What the live site's workload suggests, to be taken up only with numbers from
`system.query_log` showing the gain:

- **Insert batching for many small tables.** The platform writes ~15 tables (and
  their materialized views) every few seconds; each flush is one part per table.
  Upstream's `async_insert` covers this per table; measure whether a profile default
  is enough before touching the merge selector.
- **Query guard.** A per-profile `max_rows_to_read` catches a page query that forgot
  its date bound (the class of bug behind the November incident). Settings first;
  a patch only if the error message needs to name the missing prune for the
  platform's developers.
