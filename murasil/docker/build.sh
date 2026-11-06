#!/usr/bin/env bash
# Builds the murasil/clickhouse-server image from a built binary.
#
#   murasil/docker/build.sh [binary] [tag]
#
# binary: default murasil/out/clickhouse-stripped, else murasil/out/clickhouse (the
#         builder droplet leaves both). tag: default murasil-<version the binary reports>.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/murasil/out"
BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  if [[ -x "$OUT/clickhouse-stripped" ]]; then BIN="$OUT/clickhouse-stripped"; else BIN="$OUT/clickhouse"; fi
fi
[[ -x "$BIN" ]] || { echo "no binary at $BIN: run murasil/build/builder-droplet.sh first" >&2; exit 1; }

# A small context: docker sends the whole context to the daemon, and the repository
# is 1.6 GB of sources the image does not need.
CTX="$OUT/context"
rm -rf "$CTX"
mkdir -p "$CTX/config.d" "$CTX/users.d"
cp "$BIN" "$CTX/clickhouse"
cp "$ROOT/docker/server/entrypoint.sh" "$ROOT/docker/server/docker_related_config.xml" "$CTX/"
cp "$ROOT/murasil/config.d/"*.xml "$CTX/config.d/"
cp "$ROOT/murasil/users.d/"*.xml "$CTX/users.d/"

# The binary is Linux x86_64. On another host docker reads its version through
# emulation; when that is unavailable the tag falls back to the git ref.
version=$(docker run --rm --platform linux/amd64 -v "$CTX/clickhouse:/clickhouse:ro" ubuntu:22.04 /clickhouse --version 2>/dev/null \
  | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)
tag="${2:-murasil-${version:-$(git -C "$ROOT" describe --tags --always)}}"

echo "==> murasil/clickhouse-server:$tag from $(basename "$BIN") ($(du -h "$BIN" | cut -f1))"
docker build --platform linux/amd64 -f "$ROOT/murasil/docker/Dockerfile" -t "murasil/clickhouse-server:$tag" "$CTX"
echo "==> smoke: SELECT version()"
docker run --rm --platform linux/amd64 "murasil/clickhouse-server:$tag" clickhouse local -q "SELECT version()"
rm -rf "$CTX"
echo "==> murasil/clickhouse-server:$tag"
