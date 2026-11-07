#!/usr/bin/env bash
# The build box: the biggest dedicated-CPU droplet DigitalOcean has, with the sources, the toolchain
# image and the build directory on a volume that outlives it, so a build after the first one is
# incremental, minutes for a patch plus the ThinLTO link. The droplet costs while it exists; the
# volume keeps the state between sessions.
#
#   murasil/build/build-box.sh up            create the volume if needed, the droplet, mount, provision
#   murasil/build/build-box.sh build [ref]   fetch <ref> (default: murasil), build clickhouse, examples
#                                            and the stripped binary into /work/out, with the kept
#                                            profile (murasil/out/murasil.profdata.zst) if present
#   murasil/build/build-box.sh status        the last lines of the build log
#   murasil/build/build-box.sh fetch <name>  copy /work/out/clickhouse-stripped to murasil/out/<name>
#   murasil/build/build-box.sh ssh           a shell on the box
#   murasil/build/build-box.sh down          delete the droplet; the volume stays
set -euo pipefail

REPO_URL="${MURASIL_CH_REPO:-$(git -C "$(dirname "$0")/../.." remote get-url origin)}"
NAME="murasil-build"
VOLUME="murasil-build"
VOLUME_GB="${MURASIL_BUILD_VOLUME_GB:-300}"
REGIONS="${MURASIL_BUILDER_REGIONS:-fra1 ams3 lon1 nyc3 nyc1 sfo3}"
SIZES="${MURASIL_BUILDER_SIZE:-c5-60vcpu-120gb-intel c2-60vcpu-120gb-intel c-60-intel g5-64vcpu-256gb-80gb c-48 c-32}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/out"
SSH_KEY_FILE="${MURASIL_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-i "$SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)

ip_of() { doctl compute droplet list --format Name,PublicIPv4 --no-header | awk -v n="$NAME" '$1 == n {print $2}'; }
r() { ssh "${SSH_OPTS[@]}" "root@$(ip_of)" "$@"; }
volume_id() { doctl compute volume list --format ID,Name --no-header | awk -v n="$VOLUME" '$2 == n {print $1}'; }
volume_region() { doctl compute volume list --format Name,Region --no-header | awk -v n="$VOLUME" '$1 == n {print $2}'; }

cmd_up() {
  local key_id created="" ip="" regions="$REGIONS"
  key_id=$(doctl compute ssh-key list --format ID,FingerPrint --no-header |
    awk -v fp="$(ssh-keygen -lf "$SSH_KEY_FILE.pub" -E md5 | awk '{print $2}' | sed 's/^MD5://')" '$2 == fp {print $1}')
  [[ -n "$key_id" ]] || { echo "the SSH key is not registered in DigitalOcean" >&2; exit 1; }
  # A volume lives in one region, so the droplet goes where the volume is.
  if [[ -n "$(volume_id)" ]]; then regions=$(volume_region); fi
  for region in $regions; do
    for size in $SIZES; do
      local vol_args=()
      if [[ -z "$(volume_id)" ]]; then
        doctl compute volume create "$VOLUME" --region "$region" --size "${VOLUME_GB}GiB" --fs-type ext4 >/dev/null 2>/tmp/murasil-vol.err || { echo "    no volume in $region: $(tail -1 /tmp/murasil-vol.err)"; continue 2; }
      fi
      vol_args=(--volumes "$(volume_id)")
      if doctl compute droplet create "$NAME" --region "$region" --size "$size" --image ubuntu-24-04-x64 \
           --ssh-keys "$key_id" --tag-name murasil-builder "${vol_args[@]}" --wait >/dev/null 2>/tmp/murasil-build-create.err; then
        created="$region ($size)"
        break 2
      fi
      echo "    no $size in $region: $(tail -1 /tmp/murasil-build-create.err | cut -c1-100)"
    done
  done
  [[ -n "$created" ]] || { echo "no region took any of: $SIZES" >&2; exit 1; }
  for _ in $(seq 1 30); do ip=$(ip_of); [[ -n "$ip" && "$ip" != "<nil>" ]] && break; sleep 5; done
  echo "==> $NAME at $ip in $created, volume $VOLUME"
  for _ in $(seq 1 36); do ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null && break; sleep 10; done
  [[ -f "$OUT/murasil.profdata.zst" ]] && scp -q "${SSH_OPTS[@]}" "$OUT/murasil.profdata.zst" "root@$ip:/root/murasil.profdata.zst"
  r bash -s -- "$REPO_URL" <<'REMOTE'
set -euo pipefail
repo=$1
export DEBIAN_FRONTEND=noninteractive
while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done
apt-get -qq update >/dev/null && apt-get -qq install -y docker.io git zstd >/dev/null
apt-get -qq install -y docker-buildx >/dev/null 2>&1 || true
dev=$(ls /dev/disk/by-id/scsi-0DO_Volume_* | head -1)
mkdir -p /work
grep -q " /work " /proc/mounts || mount -o discard,defaults "$dev" /work
grep -q " /work " /etc/fstab || echo "$dev /work ext4 discard,defaults,nofail 0 2" >> /etc/fstab
mkdir -p /work/out /work/profiles /work/docker
# Docker's images on the volume too, so the toolchain image survives the droplet.
if ! grep -q '"data-root"' /etc/docker/daemon.json 2>/dev/null; then
  systemctl stop docker
  echo '{"data-root": "/work/docker"}' > /etc/docker/daemon.json
  systemctl start docker
fi
[[ -f /root/murasil.profdata.zst ]] && { mv /root/murasil.profdata.zst /work/profiles/; zstd -d -q -f /work/profiles/murasil.profdata.zst -o /work/profiles/murasil.profdata; }
if [[ ! -d /work/src/.git ]]; then
  git clone -q --branch murasil "$repo" /work/src
  cd /work/src && git submodule update --init --depth 1 --jobs 32
fi
cd /work/src && git log -1 --oneline
if ! docker image inspect murasil/ch-toolchain >/dev/null 2>&1; then
  DOCKER_BUILDKIT=1 docker build -q -t murasil/ch-toolchain --build-arg TARGETARCH=amd64 -f ci/docker/fasttest/Dockerfile ci/docker/fasttest
fi
cat > /work/configure.sh <<'SH'
set -eu
llvm=$(sed -n 's/.*LLVM_VERSION=\([0-9][0-9]*\).*/\1/p' /work/src/ci/docker/fasttest/Dockerfile | head -1)
profile=""
[[ -f /work/profiles/murasil.profdata ]] && profile="-DCLICKHOUSE_PGO_PROFILE_PATH=/work/profiles/murasil.profdata"
cmake -DCMAKE_BUILD_TYPE=None -DSANITIZE= -DENABLE_THINLTO=1 -DENABLE_EXAMPLES=1 \
  -DBUILD_STRIPPED_BINARY=1 -DENABLE_CLICKHOUSE_SELF_EXTRACTING=0 \
  -DCMAKE_C_COMPILER=clang-$llvm -DCMAKE_CXX_COMPILER=clang++-$llvm \
  -DCMAKE_TOOLCHAIN_FILE=/work/src/cmake/linux/toolchain-x86_64.cmake \
  -DENABLE_TESTS=0 -DENABLE_UTILS=0 -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
  $profile -S /work/src -B /work/build
SH
echo PROVISIONED
nproc; free -g | sed -n 2p; df -h /work | tail -1
REMOTE
}

cmd_build() {
  local ref="${1:-murasil}"
  r bash -s -- "$ref" <<'REMOTE'
set -euo pipefail
ref=$1
cat > /work/build.sh <<SH
set -eux
cd /work/src
git fetch -q origin "$ref"
git checkout -q FETCH_HEAD
git submodule update --init --depth 1 --jobs 32
git log -1 --oneline
docker run --rm -v /work:/work -w /work/src murasil/ch-toolchain bash /work/configure.sh
docker run --rm -v /work:/work -w /work/src murasil/ch-toolchain ninja -C /work/build clickhouse-examples clickhouse clickhouse-stripped
cp /work/build/programs/clickhouse-stripped /work/out/clickhouse-stripped
/work/out/clickhouse-stripped --version
sha256sum /work/out/clickhouse-stripped
echo BUILD_DONE
SH
nohup bash /work/build.sh > /work/build.log 2>&1 &
echo "==> building $ref: build-box.sh status"
REMOTE
}

cmd_status() { r 'grep -E "^\[[0-9]+/[0-9]+\]" /work/build.log | tail -1 | cut -c1-100; tail -c 1500 /work/build.log | grep -E "BUILD_DONE|build stopped|^FAILED|sha256|version" | tail -4; uptime'; }
cmd_fetch() { mkdir -p "$OUT"; r 'cd /work/out && zstd -T0 -3 -q -f clickhouse-stripped -o clickhouse-stripped.zst' && scp -q "${SSH_OPTS[@]}" "root@$(ip_of):/work/out/clickhouse-stripped.zst" "$OUT/$1.zst" && (cd "$OUT" && zstd -d -q -f "$1.zst" -o "$1" && chmod 755 "$1" && ls -la "$1"); }
cmd_down() { doctl compute droplet delete "$NAME" --force; echo "deleted $NAME; volume $VOLUME kept"; }

case "${1:-}" in
  up) cmd_up ;;
  build) cmd_build "${2:-}" ;;
  status) cmd_status ;;
  fetch) cmd_fetch "${2:?name}" ;;
  ssh) ssh "${SSH_OPTS[@]}" "root@$(ip_of)" ;;
  down) cmd_down ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
