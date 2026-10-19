#!/usr/bin/env bash
# Standalone OrangeFox klee builder for a VPS (mirrors .github/workflows/build.yml).
#
# Usage:
#   ./build-vps.sh              # sync sources if missing, then build (incremental on reruns)
#   ./build-vps.sh --sync-only  # prepare sources only, no build
#   ./build-vps.sh --fresh      # wipe synced sources, re-sync from scratch, build
#   ./build-vps.sh --skip-deps  # do not require root for missing apt packages
#
# Root is only used for one-time apt package install (+ optional swap creation).
# No root on your account? Run the printed apt-get command once via your
# provider's root console, then rerun this script as your normal user.
#
# Tunables (env):
#   ORANGEFOX_TOP      source tree location (default: $HOME/fox_14.1)
#   ORANGEFOX_OUT_DIR  where the final image lands (default: $HOME/orangefox-klee-out)
#
# Rebuilds are incremental: the synced source tree is reused unless --fresh is passed.
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ORANGEFOX_TOP="${ORANGEFOX_TOP:-$HOME/fox_14.1}"
OUT_COLLECT="${ORANGEFOX_OUT_DIR:-$HOME/orangefox-klee-out}"
IMAGE_NAME="OrangeFox-R12.0-Unofficial-klee-system-compatible.img"
ORANGEFOX_SYNC_REVISION='11e4406b2bd1de939a26b6bfbad7e371cc3b1fa7'

FRESH=0
SYNC_ONLY=0
SKIP_DEPS=0
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=1 ;;
        --sync-only) SYNC_ONLY=1 ;;
        --skip-deps) SKIP_DEPS=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ ! -f "$DEVICE_DIR/device.mk" ]; then
    echo "error: run this script from inside the device tree clone" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Host capacity
# ---------------------------------------------------------------------------
CORES="$(nproc)"
MEM_GIB=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) / 1024 / 1024 ))
SWAP_KB="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
DISK_GIB="$(df -Pk "$HOME" | awk 'NR==2 { print int($4/1024/1024) }')"
echo "host: ${CORES} cores, ${MEM_GIB}G RAM, $((SWAP_KB/1024/1024))G swap, ${DISK_GIB}G disk free"

if [ "$DISK_GIB" -lt 45 ]; then
    echo "error: need >= 45G free disk (shallow sync ~35G + out/ ~15G); found ${DISK_GIB}G" >&2
    exit 1
elif [ "$DISK_GIB" -lt 65 ]; then
    echo "warning: disk is tight (${DISK_GIB}G free); build may struggle near the end"
fi

# Root is optional: used only for one-time package install (+ optional swap).
SUDO=""
HAVE_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
    HAVE_ROOT=1
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    SUDO="sudo"
    HAVE_ROOT=1
fi

# ---------------------------------------------------------------------------
# Host packages (same list as CI)
# ---------------------------------------------------------------------------
PKGS=(
    bc bison build-essential ccache cpio curl flex g++-multilib gcc-multilib
    git git-lfs gnupg gperf imagemagick lib32ncurses-dev lib32readline-dev
    lib32z1-dev libelf-dev liblz4-tool libncurses-dev libsdl1.2-dev libssl-dev
    libxml2 libxml2-utils lz4 openjdk-17-jdk-headless pngcrush python-is-python3
    python3 ripgrep rsync schedtool squashfs-tools unzip xsltproc zip
    zlib1g-dev device-tree-compiler
)
missing=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ "${#missing[@]}" -gt 0 ]; then
    if [ "$HAVE_ROOT" -eq 1 ]; then
        echo "installing packages: ${missing[*]}"
        $SUDO apt-get update
        $SUDO apt-get install -y --no-install-recommends "${missing[@]}"
    elif [ "$SKIP_DEPS" -eq 1 ]; then
        echo "warning: ${#missing[@]} packages missing, continuing anyway (--skip-deps)"
    else
        {
            echo "error: ${#missing[@]} build packages are missing and no root is available."
            echo
            echo "Run this ONCE as root (provider console / root login), then rerun this script:"
            echo
            echo "  apt-get update && apt-get install -y --no-install-recommends \\"
            for p in "${missing[@]}"; do echo "    $p \\"; done
            echo "    "
            echo
            echo "Or rerun with --skip-deps if you know these are already provided another way."
        } >&2
        exit 1
    fi
fi
if command -v javac >/dev/null; then
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    export JAVA_HOME
fi

# ---------------------------------------------------------------------------
# repo tool
# ---------------------------------------------------------------------------
if ! command -v repo >/dev/null; then
    install -d "$HOME/bin"
    curl --fail --location --retry 5 --retry-all-errors \
        https://storage.googleapis.com/git-repo-downloads/repo \
        --output "$HOME/bin/repo"
    chmod +x "$HOME/bin/repo"
    export PATH="$HOME/bin:$PATH"
fi

# ---------------------------------------------------------------------------
# Swap guard (build-lowmem expects some breathing room)
# ---------------------------------------------------------------------------
if [ "$SWAP_KB" -lt $((8 * 1024 * 1024)) ]; then
    if [ "$HAVE_ROOT" -eq 1 ]; then
        echo "creating swap via .github/scripts/setup-swap.sh"
        $SUDO bash "$DEVICE_DIR/.github/scripts/setup-swap.sh"
    else
        echo "note: no swap and no root to create one - harmless with ${MEM_GIB}G RAM"
    fi
fi

# ---------------------------------------------------------------------------
# Isolated git config (file:// manifest + flaky-network resilience, like CI).
# Rewritten every run: GIT_CONFIG_GLOBAL replaces the user's ~/.gitconfig
# entirely, so this file MUST carry a committer identity or repo init dies
# with "Committer identity unknown".
# ---------------------------------------------------------------------------
GITCFG="$HOME/.orangefox-ci-gitconfig"
cat > "$GITCFG" <<'EOF'
[protocol "file"]
	allow = always
[http]
	lowSpeedLimit = 1
	lowSpeedTime = 600
[user]
	name = KazeTheLight
	email = dianpermadib@gmail.com
EOF
export GIT_CONFIG_GLOBAL="$GITCFG"

# ---------------------------------------------------------------------------
# Sync OrangeFox sources (shallow, pinned; skipped when tree exists)
# ---------------------------------------------------------------------------
MANIFEST_SRC="$DEVICE_DIR/manifests/orangefox-fox_14.1-pinned.xml"
if [ ! -f "$MANIFEST_SRC" ]; then
    echo "error: missing pinned manifest: $MANIFEST_SRC" >&2
    exit 1
fi

if [ "$FRESH" -eq 1 ]; then
    echo "wiping $ORANGEFOX_TOP"
    rm -rf "$ORANGEFOX_TOP"
fi

if [ ! -f "$ORANGEFOX_TOP/build/envsetup.sh" ]; then
    echo "syncing OrangeFox sources (shallow) -> $ORANGEFOX_TOP"
    MANIFEST_REPO="$HOME/.orangefox-manifest"
    rm -rf "$MANIFEST_REPO"
    mkdir -p "$MANIFEST_REPO"
    cp "$MANIFEST_SRC" "$MANIFEST_REPO/default.xml"
    git -C "$MANIFEST_REPO" init --initial-branch=main --quiet
    git -C "$MANIFEST_REPO" add default.xml
    git -C "$MANIFEST_REPO" \
        -c user.name="OrangeFox CI" -c user.email="orangefox-ci@localhost" \
        commit --quiet -m "Pinned OrangeFox 14.1 manifest"

    mkdir -p "$ORANGEFOX_TOP"
    cd "$ORANGEFOX_TOP"
    repo init --depth=1 -u "file://$MANIFEST_REPO" -b main -m default.xml
    SYNC_JOBS="$CORES"
    [ "$SYNC_JOBS" -gt 8 ] && SYNC_JOBS=8
    repo sync -c -j"$SYNC_JOBS" --retry-fetches=3 \
        --no-clone-bundle --no-tags --optimized-fetch
else
    echo "reusing synced sources at $ORANGEFOX_TOP"
fi

if [ "$SYNC_ONLY" -eq 1 ]; then
    echo "sync-only done"
    exit 0
fi

# ---------------------------------------------------------------------------
# OrangeFox sync module (pinned revision)
# ---------------------------------------------------------------------------
SYNC_DIR="$HOME/.orangefox-sync"
if [ ! -d "$SYNC_DIR/.git" ]; then
    git clone --filter=blob:none https://gitlab.com/OrangeFox/sync.git "$SYNC_DIR"
fi
if ! git -C "$SYNC_DIR" cat-file -e "$ORANGEFOX_SYNC_REVISION^{commit}" 2>/dev/null; then
    git -C "$SYNC_DIR" fetch --all --quiet
fi
git -C "$SYNC_DIR" checkout --quiet --detach "$ORANGEFOX_SYNC_REVISION"
if [ "$(git -C "$SYNC_DIR" rev-parse HEAD)" != "$ORANGEFOX_SYNC_REVISION" ]; then
    echo "error: orangefox sync checkout mismatch" >&2
    exit 1
fi

boardconfig="$ORANGEFOX_TOP/vendor/twrp/config/BoardConfigSoong.mk"
if ! grep -qx 'include bootable/recovery/orangefox_soong.mk' "$boardconfig"; then
    sed -i '/SOONG_CONFIG_NAMESPACES += twrpVarsPlugin/i include bootable/recovery/orangefox_soong.mk' \
        "$boardconfig"
fi

# ---------------------------------------------------------------------------
# Install this device tree clone
# ---------------------------------------------------------------------------
echo "installing device tree -> $ORANGEFOX_TOP/device/xiaomi/klee"
mkdir -p "$ORANGEFOX_TOP/device/xiaomi/klee"
rsync -a --delete \
    --exclude .git \
    --exclude images \
    "$DEVICE_DIR/" \
    "$ORANGEFOX_TOP/device/xiaomi/klee/"

# ---------------------------------------------------------------------------
# Source patches
# ---------------------------------------------------------------------------
"$ORANGEFOX_TOP/device/xiaomi/klee/tools/apply-orangefox-patches.sh" "$ORANGEFOX_TOP"

# ---------------------------------------------------------------------------
# Build, tuned per memory tier
#   big  : >= 32G RAM
#   mid  : 16-31G RAM
#   low  : < 16G RAM (same profile as the GitHub-hosted runner CI)
# OF_LOW_MEMORY_BUILD stays 1 on every tier (known-good CI parity);
# the heavy knobs (jobs, heaps) are scaled here instead.
# ---------------------------------------------------------------------------
if [ "$MEM_GIB" -ge 32 ]; then
    MEM_TIER="big"
    BUILD_JOBS="$CORES"
    HEAP_OPTS=(GOMEMLIMIT=12GiB _JAVA_OPTIONS=-Xmx8g NINJA_HIGHMEM_NUM_JOBS="$BUILD_JOBS")
elif [ "$MEM_GIB" -ge 16 ]; then
    MEM_TIER="mid"
    BUILD_JOBS="$CORES"
    HEAP_OPTS=(GOMEMLIMIT=8GiB _JAVA_OPTIONS=-Xmx4g NINJA_HIGHMEM_NUM_JOBS="$((BUILD_JOBS / 2 + 1))")
else
    MEM_TIER="low"
    BUILD_JOBS="$CORES"
    [ "$BUILD_JOBS" -gt 4 ] && BUILD_JOBS=4
    HEAP_OPTS=(GOMEMLIMIT=3GiB _JAVA_OPTIONS=-Xmx3g NINJA_HIGHMEM_NUM_JOBS=1)
fi

export OF_LOW_MEMORY_BUILD=1
export OF_BUILD_JOBS="$BUILD_JOBS"
export NINJA_ARGS="-j${BUILD_JOBS} -l${BUILD_JOBS}"
export SOONG_UI_NINJA_ARGS="$NINJA_ARGS"
export GOMAXPROCS="$BUILD_JOBS"
for kv in "${HEAP_OPTS[@]}"; do
    export "$kv"
done

echo "build profile: ${MEM_TIER} tier, ${BUILD_JOBS} jobs, ${_JAVA_OPTIONS}"

bash "$ORANGEFOX_TOP/device/xiaomi/klee/build-lowmem.sh" vendorbootimage

# ---------------------------------------------------------------------------
# Collect artifact
# ---------------------------------------------------------------------------
PRODUCT_DIR="$ORANGEFOX_TOP/out/target/product/klee"
IMG="$PRODUCT_DIR/$IMAGE_NAME"
if [ ! -f "$IMG" ]; then
    echo "error: expected image not found: $IMG" >&2
    exit 1
fi

mkdir -p "$OUT_COLLECT"
cp -fp "$IMG" "$OUT_COLLECT/"
(
    cd "$OUT_COLLECT"
    sha256sum "$IMAGE_NAME" > "$IMAGE_NAME.sha256"
)
cat > "$OUT_COLLECT/build-info.md" <<EOF
OrangeFox klee VPS build ($(date -u +%FT%TZ))

- device-tree commit: $(git -C "$DEVICE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
- OrangeFox branch: 14.1 (pinned sync)
- host: ${CORES} cores / ${MEM_GIB}G RAM / ${MEM_TIER} profile

Flash with:
  fastboot flash vendor_boot ${OUT_COLLECT}/${IMAGE_NAME}
EOF

echo
echo "BUILD OK"
echo "image  : $OUT_COLLECT/$IMAGE_NAME"
echo "sha256 : $(cat "$OUT_COLLECT/$IMAGE_NAME.sha256")"
echo "info   : $OUT_COLLECT/build-info.md"
