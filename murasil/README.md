# Murasil ClickHouse

Murasil's build of ClickHouse: the engine under the Murasil wholesale SMS platform,
built from this fork with Murasil's defaults and, where upstream does not serve the
platform, Murasil's patches.

## Branches and tags

| Ref | What it is |
|---|---|
| `master` | A mirror of upstream `ClickHouse/ClickHouse` master. Never commit here. |
| `murasil` | The branch Murasil ships: an upstream LTS tag plus the `murasil/` directory and the patches listed in [PATCHES.md](PATCHES.md). |
| `murasil-<upstream version>-<n>` | A build that went to production, e.g. `murasil-26.10.2.103-1`. |

The current base is **v26.10.2.103-stable**, the newest upstream release when the
fork was made (the live site ran 24.12.6 then; moving it needs the platform's test
suite green against this build first). ClickHouse publishes a stable release every
month and marks two a year as LTS (26.3, 26.8). Murasil follows the latest stable:
`murasil` is rebased onto each monthly release and onto its patch releases, which
keeps the fork close to upstream and every rebase small. Falling back to the LTS line
is a one-line change of the base tag if a release misbehaves.

## What lives in `murasil/`

- `config.d/` server configuration loaded after upstream's `config.xml`: the system
  logs Murasil does not read are off, the rest have retention.
- `users.d/` profile defaults: no server-side insert batching, a partition cap that
  fits one partition per tenant per batch.
- `COMPATIBILITY.md` what moving the platform between ClickHouse versions turned up.
- `build/` how the Linux binary is produced. A ClickHouse build needs 16+ cores and
  32+ GB of RAM, so it runs on a throwaway DigitalOcean droplet
  (`build/builder-droplet.sh`) inside upstream's own toolchain image for the same
  source (`ci/docker/fasttest`, LLVM 22 at this base), with the cmake configuration of
  upstream's binary build (`ci/jobs/build_clickhouse.py`).
- `docker/` the server image Murasil deploys, built from that binary and this
  configuration.
- `PATCHES.md` every change to the engine itself, with why it exists and whether it
  was offered upstream.

## Rules

1. **Upstream first.** A fix that helps everyone goes to `ClickHouse/ClickHouse` as a
   pull request; it lives here only until it is released upstream.
2. **One commit per change**, prefixed `murasil:` and listed in `PATCHES.md`, so a
   rebase onto the next upstream release is a list of known conflicts, not an
   archaeology.
3. **Settings before code.** ClickHouse has a setting for most behaviours
   (`max_rows_to_read`, `async_insert`, merge and pool sizes, log retention): a change
   that a setting can express is a line in `config.d/`, not a patch.
4. **Measured.** A patch ships with the query or workload it speeds up and the before
   and after numbers from `system.query_log`, the way the platform's own fixes do.

## Rebasing onto a new upstream release

```bash
git fetch upstream --tags
git checkout murasil
git rebase --onto v26.11.X.Y-stable v26.10.2.103-stable
# resolve conflicts patch by patch (PATCHES.md is the checklist), then
murasil/build/builder-droplet.sh
```

## Building

```bash
murasil/build/builder-droplet.sh            # the murasil branch
murasil/build/builder-droplet.sh <ref>      # any tag or commit
```

The binary lands in `murasil/out/clickhouse`; `murasil/docker/build.sh` turns it
into the `murasil/clickhouse-server` image the platform's compose file runs.

---

### بالعربية

هذا هو ClickHouse الخاص بمنصّة مرسِل: نسخة مبنية من هذا الـfork بإعدادات مرسِل
وتعديلاتها. الفرع `murasil` هو ما يُنشر، وأساسه دائماً أحدث إصدار مستقر من upstream
(حالياً v26.10.2.103) يُعاد التأسيس عليه مع كل إصدار شهري. كل تعديل في المحرّك
يُسجَّل في `PATCHES.md` ويُقدَّم إلى upstream أولاً إن كان يفيد الجميع؛ وما يمكن
التعبير عنه بإعداد يبقى إعداداً في `config.d/` لا تعديلاً في الكود.
