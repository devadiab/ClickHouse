# Platform compatibility log

What moving the Murasil platform from the ClickHouse it ran (24.12) to this fork's
base turned up, with where each item was fixed. Each entry is a behaviour change
between the two versions that the platform's own test suite caught.

## 24.12 → 26.10

| Behaviour | 24.12 | 26.10 | Fixed in |
|---|---|---|---|
| AggregatingMergeTree with a dimension column outside the sorting key | accepted; the column kept an arbitrary value after merges | refused at CREATE (`allow_dimensions_outside_sorting_key`) | platform schema 024: `cube_traffic_inner` keyed by every dimension its view groups by |
| An integer for a `DateTime64(3)` column in JSONEachRow input | read as ticks of the column's precision (milliseconds) | read as seconds, saturating at 9999-12-31; `date_time_input_format` does not change it | platform `Core.CH.insert_json`: DateTime64 columns are written as `YYYY-MM-DD hh:mm:ss.mmm` strings |
| Default `async_insert` | `0` | `1`: the server merges concurrent small inserts into one block before writing; with tables partitioned per tenant and month a block spanning 100+ tenants fails them all with TOO_MANY_PARTS ("Too many partitions for single INSERT block") | platform: every connection sends `async_insert=0` and `max_partitions_per_insert_block=10000` (`config :core, Core.CH, settings:`); fork: `users.d/00-murasil.xml` |
| Default `date_time_input_format` | `basic` | `best_effort` | nothing to do; noted |
| `clickhouse/clickhouse-server` image: the `default` user | passwordless | refuses to start the user setup without `CLICKHOUSE_PASSWORD` or `CLICKHOUSE_SKIP_USER_SETUP=1` | compose files set a password |
| `docker/packager` | present | gone; builds run through `ci/` (praktika) in the `ci/docker/fasttest` toolchain image (LLVM 22) | `murasil/build/builder-droplet.sh` |
