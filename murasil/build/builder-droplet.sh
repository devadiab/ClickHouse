#!/usr/bin/env bash
# Builds the Murasil ClickHouse Linux binary on a throwaway DigitalOcean droplet.
#
#   murasil/build/builder-droplet.sh            build HEAD of the murasil branch
#   murasil/build/builder-droplet.sh v26.10.2.103-stable  build a given ref
#
# A ClickHouse build wants 16+ cores and 32+ GB of RAM: that is a c-32 droplet
# (32 vCPU / 64 GB, about $1 an hour) for roughly 60-120 minutes, so a build costs a
# couple of dollars. The toolchain is upstream's own image for the same source, so
# the binary is built the way upstream builds its releases, PGO/BOLT aside. The droplet is deleted at the end, whatever happened. The
# binary lands in murasil/out/clickhouse and the image is built from it by
# murasil/docker/Dockerfile.
set -euo pipefail

REF="${1:-murasil}"
REPO_URL="${MURASIL_CH_REPO:-$(git -C "$(dirname "$0")/../.." remote get-url origin)}"
NAME="murasil-ch-builder-$(date +%Y%m%d%H%M)"
REGION="${MURASIL_REGION:-fra1}"
SIZE="${MURASIL_BUILDER_SIZE:-c-32}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/out"
SSH_KEY_FILE="${MURASIL_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-i "$SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)

key_id=$(doctl compute ssh-key list --format ID,FingerPrint --no-header |
  awk -v fp="$(ssh-keygen -lf "$SSH_KEY_FILE.pub" -E md5 | awk '{print $2}' | sed 's/^MD5://')" '$2 == fp {print $1}')
[[ -n "$key_id" ]] || { echo "the SSH key is not registered in DigitalOcean" >&2; exit 1; }

cleanup() {
  echo "==> Deleting $NAME"
  doctl compute droplet delete "$NAME" --force || true
}
trap cleanup EXIT

echo "==> Creating $NAME ($SIZE in $REGION)"
doctl compute droplet create "$NAME" --region "$REGION" --size "$SIZE" --image ubuntu-24-04-x64 \
  --ssh-keys "$key_id" --tag-name murasil-builder --wait >/dev/null
ip=$(doctl compute droplet get "$NAME" --format PublicIPv4 --no-header)
echo "    $ip"

for _ in $(seq 1 30); do
  ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null && break
  sleep 10
done

echo "==> Building $REF from $REPO_URL (this is the long part)"
ssh "${SSH_OPTS[@]}" "root@$ip" bash -s -- "$REPO_URL" "$REF" "${MURASIL_THINLTO:-0}" <<'REMOTE'
set -euo pipefail
repo=$1 ref=$2 thinlto=$3
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq install -y docker.io git >/dev/null
git clone -q --filter=blob:none "$repo" /src
cd /src
git checkout -q "$ref"
git submodule update --init --depth 1 --jobs 16

# Upstream's own toolchain image for this exact source (clang, cmake, ninja, rust):
# ci/docker/fasttest/Dockerfile is what their build jobs start from.
docker build -q -t murasil/ch-toolchain -f ci/docker/fasttest/Dockerfile ci/docker/fasttest
llvm=$(sed -n 's/.*LLVM_VERSION=\([0-9][0-9]*\).*/\1/p' ci/docker/fasttest/Dockerfile | head -1)

# The configuration of upstream's "amd_binary" build (ci/jobs/build_clickhouse.py), minus
# the CI-only knobs. THINLTO=1 is their "amd_release": a faster binary for roughly
# twice the build time and memory; MURASIL_THINLTO=1 asks for it.
docker run --rm -v /src:/src -w /src murasil/ch-toolchain bash -euxc "
  cmake -DCMAKE_BUILD_TYPE=None -DENABLE_THINLTO=$thinlto -DSANITIZE= \
        -DBUILD_STRIPPED_BINARY=1 -DENABLE_CLICKHOUSE_SELF_EXTRACTING=0 \
        -DCMAKE_C_COMPILER=clang-$llvm -DCMAKE_CXX_COMPILER=clang++-$llvm \
        -DCMAKE_TOOLCHAIN_FILE=/src/cmake/linux/toolchain-x86_64.cmake \
        -DENABLE_TESTS=0 -DENABLE_UTILS=0 -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
        -S /src -B /src/build
  ninja -C /src/build clickhouse-bundle
  /src/build/programs/clickhouse --version
"
mkdir -p /out && cp /src/build/programs/clickhouse /out/clickhouse
ls -la /out
REMOTE

mkdir -p "$OUT"
echo "==> Fetching the binary"
scp "${SSH_OPTS[@]}" "root@$ip:/out/clickhouse" "$OUT/clickhouse"
chmod 755 "$OUT/clickhouse"
"$OUT/clickhouse" --version 2>/dev/null || true
echo "==> Done: $OUT/clickhouse"
