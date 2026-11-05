#!/usr/bin/env bash
# Builds the murasil/clickhouse-server image from the binary in murasil/out.
#
#   murasil/docker/build.sh [tag]      default tag: the version the binary reports
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/murasil/out/clickhouse"
[[ -x "$BIN" ]] || { echo "no binary at $BIN: run murasil/build/builder-droplet.sh first" >&2; exit 1; }

# The binary is Linux x86_64; on a Mac docker still reads its version through emulation,
# so the tag falls back to the git ref when that is unavailable.
version=$(docker run --rm --platform linux/amd64 -v "$BIN:/clickhouse:ro" ubuntu:22.04 /clickhouse --version 2>/dev/null \
  | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)
tag="${1:-murasil-${version:-$(git -C "$ROOT" describe --tags --always)}}"

echo "==> murasil/clickhouse-server:$tag"
docker build --platform linux/amd64 -f "$ROOT/murasil/docker/Dockerfile" -t "murasil/clickhouse-server:$tag" "$ROOT"
echo "==> smoke: SELECT version()"
docker run --rm --platform linux/amd64 "murasil/clickhouse-server:$tag" clickhouse local -q "SELECT version()"
