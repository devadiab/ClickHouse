#!/usr/bin/env bash
# A build profiled on Murasil's own workload, on a throwaway DigitalOcean droplet.
#
#   murasil/build/pgo-droplet.sh up [ref]     create the droplet, start the instrumented build
#   murasil/build/pgo-droplet.sh status       how far it is
#   murasil/build/pgo-droplet.sh instrumented fetch the instrumented binary to murasil/out
#   murasil/build/pgo-droplet.sh final <dir>  merge the *.profraw in <dir>, start the final build
#   murasil/build/pgo-droplet.sh fetch        fetch the final binary to murasil/out
#   murasil/build/pgo-droplet.sh down         delete the droplet
#   murasil/build/pgo-droplet.sh build <profdata.zst> [ref]
#                                             a fresh droplet, the final build straight from a
#                                             profile kept from an earlier run (the code since
#                                             then is unprofiled where it changed), and the
#                                             examples binary with the merge selector replay
#
# Between `instrumented` and `final`, run the instrumented binary under the platform's own
# load with LLVM_PROFILE_FILE set, and stop it cleanly: it writes its profile on exit. The
# final build is ThinLTO with that profile. See README.md for what it measured.
set -euo pipefail

REPO_URL="${MURASIL_CH_REPO:-$(git -C "$(dirname "$0")/../.." remote get-url origin)}"
NAME="murasil-ch-pgo"
REGIONS="${MURASIL_BUILDER_REGIONS:-fra1 ams3 lon1 nyc3 nyc1 sfo3}"
# The biggest dedicated-CPU machines DigitalOcean sells, tried in order per region: the build is
# 17,500 parallel steps and a 60-core box does it in a little over half the time of a c-32.
SIZES="${MURASIL_BUILDER_SIZE:-c5-60vcpu-120gb-intel c2-60vcpu-120gb-intel c-60-intel g5-64vcpu-256gb-80gb c-48 c-32}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/out"
SSH_KEY_FILE="${MURASIL_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-i "$SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o LogLevel=ERROR)

ip_of() { doctl compute droplet list --format Name,PublicIPv4 --no-header | awk -v n="$NAME" '$1 == n {print $2}'; }
r() { ssh "${SSH_OPTS[@]}" "root@$(ip_of)" "$@"; }

cmd_up() {
  local ref="${1:-murasil}" key_id created="" ip=""
  key_id=$(doctl compute ssh-key list --format ID,FingerPrint --no-header |
    awk -v fp="$(ssh-keygen -lf "$SSH_KEY_FILE.pub" -E md5 | awk '{print $2}' | sed 's/^MD5://')" '$2 == fp {print $1}')
  [[ -n "$key_id" ]] || { echo "the SSH key is not registered in DigitalOcean" >&2; exit 1; }
  for size in $SIZES; do
    for region in $REGIONS; do
      if doctl compute droplet create "$NAME" --region "$region" --size "$size" --image ubuntu-24-04-x64 \
           --ssh-keys "$key_id" --tag-name murasil-builder --wait >/dev/null 2>/tmp/murasil-pgo-create.err; then
        created="$region ($size)"
        break 2
      fi
      echo "    no $size in $region: $(tail -1 /tmp/murasil-pgo-create.err | cut -c1-100)"
    done
  done
  [[ -n "$created" ]] || { echo "no region took any of: $SIZES" >&2; exit 1; }
  for _ in $(seq 1 30); do ip=$(ip_of); [[ -n "$ip" && "$ip" != "<nil>" ]] && break; sleep 5; done
  echo "==> $NAME at $ip in $created"
  for _ in $(seq 1 36); do ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null && break; sleep 10; done

  r bash -s -- "$REPO_URL" "$ref" <<'REMOTE'
set -euo pipefail
repo=$1 ref=$2
export DEBIAN_FRONTEND=noninteractive
# cloud-init's own apt run holds the lock for a minute after boot.
while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done
apt-get -qq update && apt-get -qq install -y docker.io git zstd >/dev/null
apt-get -qq install -y docker-buildx >/dev/null 2>&1 || true
mkdir -p /out /profiles
cat > /root/configure.sh <<'SH'
# configure.sh <build dir> <extra cmake flags>: upstream's "amd_binary" configuration.
set -eu
llvm=$(sed -n 's/.*LLVM_VERSION=\([0-9][0-9]*\).*/\1/p' /src/ci/docker/fasttest/Dockerfile | head -1)
dir=$1; shift
cmake -DCMAKE_BUILD_TYPE=None -DSANITIZE= \
  -DBUILD_STRIPPED_BINARY=1 -DENABLE_CLICKHOUSE_SELF_EXTRACTING=0 \
  -DCMAKE_C_COMPILER=clang-$llvm -DCMAKE_CXX_COMPILER=clang++-$llvm \
  -DCMAKE_TOOLCHAIN_FILE=/src/cmake/linux/toolchain-x86_64.cmake \
  -DENABLE_TESTS=0 -DENABLE_UTILS=0 -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
  "$@" -S /src -B "$dir"
ninja -C "$dir" clickhouse clickhouse-stripped
"$dir/programs/clickhouse-stripped" --version
SH
cat > /root/instrumented.sh <<SH
set -eux
git clone -q --depth 1 --branch "$ref" "$repo" /src
cd /src
git submodule update --init --depth 1 --jobs 16
git log -1 --oneline
export DOCKER_BUILDKIT=1
docker build -q -t murasil/ch-toolchain --build-arg TARGETARCH=amd64 -f ci/docker/fasttest/Dockerfile ci/docker/fasttest
docker run --rm -v /src:/src -v /root:/root -w /src murasil/ch-toolchain bash /root/configure.sh /src/build-gen -DENABLE_THINLTO=0 -DENABLE_CLICKHOUSE_PGO_GENERATE=ON
cp /src/build-gen/programs/clickhouse-stripped /out/clickhouse-instrumented
zstd -T0 -3 -q -f /out/clickhouse-instrumented
echo INSTRUMENTED_DONE
SH
nohup bash /root/instrumented.sh > /root/instrumented.log 2>&1 &
REMOTE
  echo "==> instrumented build started: $0 status"
}

cmd_status() {
  r 'for f in /root/instrumented.log /root/final.log; do [ -f "$f" ] && { echo "== $f"; grep -E "^\[[0-9]+/[0-9]+\]" "$f" | tail -1 | cut -c1-90; tail -2 "$f" | cut -c1-140; }; done; uptime | cut -c30-; ls -la /out | tail -4 | cut -c20-'
}

cmd_instrumented() {
  mkdir -p "$OUT"
  scp "${SSH_OPTS[@]}" "root@$(ip_of):/out/clickhouse-instrumented.zst" "$OUT/clickhouse-instrumented.zst"
  ls -la "$OUT/clickhouse-instrumented.zst"
}

cmd_final() {
  local dir=$1
  r 'rm -rf /profiles/raw && mkdir -p /profiles/raw'
  scp -q "${SSH_OPTS[@]}" "$dir"/*.profraw* "root@$(ip_of):/profiles/raw/"
  r bash -s <<'REMOTE'
set -eu
cd /profiles/raw
for f in *.zst; do [ -e "$f" ] && zstd -d -q --rm "$f"; done
cat > /root/final.sh <<'SH'
set -eux
llvm=$(sed -n 's/.*LLVM_VERSION=\([0-9][0-9]*\).*/\1/p' /src/ci/docker/fasttest/Dockerfile | head -1)
docker run --rm -v /profiles:/profiles murasil/ch-toolchain bash -c "llvm-profdata-$llvm merge -output=/profiles/murasil.profdata /profiles/raw/*.profraw && ls -la /profiles/murasil.profdata"
docker run --rm -v /src:/src -v /root:/root -v /profiles:/profiles -w /src murasil/ch-toolchain bash /root/configure.sh /src/build-final -DENABLE_THINLTO=1 -DCLICKHOUSE_PGO_PROFILE_PATH=/profiles/murasil.profdata
cp /src/build-final/programs/clickhouse-stripped /out/clickhouse
sha256sum /out/clickhouse
echo FINAL_DONE
SH
nohup bash /root/final.sh > /root/final.log 2>&1 &
REMOTE
  echo "==> final build started: $0 status"
}

cmd_fetch() {
  mkdir -p "$OUT"
  scp "${SSH_OPTS[@]}" "root@$(ip_of):/out/clickhouse" "$OUT/clickhouse-pgo"
  scp "${SSH_OPTS[@]}" "root@$(ip_of):/profiles/murasil.profdata" "$OUT/murasil.profdata"
  chmod 755 "$OUT/clickhouse-pgo"
  ls -la "$OUT/clickhouse-pgo" "$OUT/murasil.profdata"
}

cmd_build() {
  local profdata=$1 ref="${2:-murasil}" key_id created="" ip=""
  [[ -f "$profdata" ]] || { echo "no profile at $profdata" >&2; exit 1; }
  key_id=$(doctl compute ssh-key list --format ID,FingerPrint --no-header |
    awk -v fp="$(ssh-keygen -lf "$SSH_KEY_FILE.pub" -E md5 | awk '{print $2}' | sed 's/^MD5://')" '$2 == fp {print $1}')
  [[ -n "$key_id" ]] || { echo "the SSH key is not registered in DigitalOcean" >&2; exit 1; }
  for size in $SIZES; do
    for region in $REGIONS; do
      if doctl compute droplet create "$NAME" --region "$region" --size "$size" --image ubuntu-24-04-x64 \
           --ssh-keys "$key_id" --tag-name murasil-builder --wait >/dev/null 2>/tmp/murasil-pgo-create.err; then
        created="$region ($size)"
        break 2
      fi
      echo "    no $size in $region: $(tail -1 /tmp/murasil-pgo-create.err | cut -c1-100)"
    done
  done
  [[ -n "$created" ]] || { echo "no region took any of: $SIZES" >&2; exit 1; }
  for _ in $(seq 1 30); do ip=$(ip_of); [[ -n "$ip" && "$ip" != "<nil>" ]] && break; sleep 5; done
  echo "==> $NAME at $ip in $created"
  for _ in $(seq 1 36); do ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null && break; sleep 10; done
  r 'mkdir -p /out /profiles'
  scp -q "${SSH_OPTS[@]}" "$profdata" "root@$ip:/profiles/murasil.profdata.zst"
  scp -q "${SSH_OPTS[@]}" "$(dirname "$0")/../bench/dlr_events_20261107T2020.tsv" "root@$ip:/root/parts.tsv"

  r bash -s -- "$REPO_URL" "$ref" <<'REMOTE'
set -euo pipefail
repo=$1 ref=$2
export DEBIAN_FRONTEND=noninteractive
# cloud-init's own apt run holds the lock for a minute after boot.
while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done
apt-get -qq update && apt-get -qq install -y docker.io git zstd >/dev/null
apt-get -qq install -y docker-buildx >/dev/null 2>&1 || true
zstd -d -q -f /profiles/murasil.profdata.zst -o /profiles/murasil.profdata
cat > /root/configure.sh <<'SH'
set -eu
llvm=$(sed -n 's/.*LLVM_VERSION=\([0-9][0-9]*\).*/\1/p' /src/ci/docker/fasttest/Dockerfile | head -1)
dir=$1; shift
cmake -DCMAKE_BUILD_TYPE=None -DSANITIZE= \
  -DBUILD_STRIPPED_BINARY=1 -DENABLE_CLICKHOUSE_SELF_EXTRACTING=0 \
  -DCMAKE_C_COMPILER=clang-$llvm -DCMAKE_CXX_COMPILER=clang++-$llvm \
  -DCMAKE_TOOLCHAIN_FILE=/src/cmake/linux/toolchain-x86_64.cmake \
  -DENABLE_TESTS=0 -DENABLE_UTILS=0 -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
  "$@" -S /src -B "$dir"
SH
cat > /root/build.sh <<SH
set -eux
git clone -q --depth 1 --branch "$ref" "$repo" /src
cd /src
git submodule update --init --depth 1 --jobs 16
git log -1 --oneline
export DOCKER_BUILDKIT=1
docker build -q -t murasil/ch-toolchain --build-arg TARGETARCH=amd64 -f ci/docker/fasttest/Dockerfile ci/docker/fasttest
docker run --rm -v /src:/src -v /root:/root -v /profiles:/profiles -w /src murasil/ch-toolchain bash /root/configure.sh /src/build-final -DENABLE_THINLTO=1 -DENABLE_EXAMPLES=1 -DCLICKHOUSE_PGO_PROFILE_PATH=/profiles/murasil.profdata
docker run --rm -v /src:/src -v /root:/root -v /profiles:/profiles -w /src murasil/ch-toolchain ninja -C /src/build-final clickhouse-examples
ex=/src/build-final/src/Examples/clickhouse-examples
for recheck in 0 1; do for tail in 1 0; do echo "RECHECK=\$recheck RIGHT_TAIL=\$tail: \$(BASE=10 SMALL_MIN_COUNT=30 RIGHT_TAIL=\$tail RECHECK=\$recheck \$ex merge_selector_murasil < /root/parts.tsv)"; done; done | tee /out/selector_replay.txt
echo SELECTOR_DONE
docker run --rm -v /src:/src -v /root:/root -v /profiles:/profiles -w /src murasil/ch-toolchain ninja -C /src/build-final clickhouse clickhouse-stripped
cp /src/build-final/programs/clickhouse-stripped /out/clickhouse
/out/clickhouse --version
sha256sum /out/clickhouse
echo FINAL_DONE
SH
nohup bash /root/build.sh > /root/final.log 2>&1 &
REMOTE
  echo "==> build started: $0 status"
}

cmd_down() { doctl compute droplet delete "$NAME" --force; }

case "${1:-}" in
  up) cmd_up "${2:-}" ;;
  status) cmd_status ;;
  instrumented) cmd_instrumented ;;
  final) cmd_final "$2" ;;
  fetch) cmd_fetch ;;
  down) cmd_down ;;
  build) cmd_build "$2" "${3:-}" ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
