#!/bin/bash
# Build the AOSP common-android15-6.6 kernel with our patches applied.
# Output:
#   arm64:  sources/kernel/arch/arm64/boot/Image.gz
#   x86_64: sources/kernel/arch/x86/boot/bzImage
#
# Re-run safe: incremental builds work via ccache.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT}/sources/kernel"

if [[ ! -f "${KERNEL_DIR}/.avd-patches-applied" ]]; then
    echo "ERROR: patches not yet applied. Run scripts/apply-patches.sh first." >&2
    exit 1
fi

cd "${KERNEL_DIR}"

TARGET_ARCH="${TARGET_ARCH:-x86_64}"
echo "==> Target Architecture: ${TARGET_ARCH}"

if [ "${TARGET_ARCH}" = "x86_64" ]; then
    export ARCH=x86_64
    export CROSS_COMPILE=""
else
    export ARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-
fi

export LLVM=1
export LLVM_IAS=1
# ccache wraps via /usr/lib/ccache symlinks already on PATH
export CC=clang
export HOSTCC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip

JOBS="${JOBS:-$(nproc)}"

echo "==> defconfig (${ARCH})"
make -j "${JOBS}" gki_defconfig

# Append config overrides:
#  - KernelSU + every SUSFS feature
#  - LSM stack without baseband_guard
#  - LOCALVERSION/host so the kernel banner matches Pixel specs
cat >> .config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,selinux,smack,tomoyo,apparmor,bpf"
CONFIG_LOCALVERSION="-android16-5-Pixel10Pro"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_DEFAULT_HOSTNAME="localhost"
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
EOF
make -j "${JOBS}" olddefconfig

OUTDIR="${ROOT}/out"
mkdir -p "${OUTDIR}"

if [ "${TARGET_ARCH}" = "x86_64" ]; then
    echo "==> Build bzImage (parallel jobs=${JOBS})"
    time make -j "${JOBS}" bzImage
    echo
    echo "==> Build complete"
    ls -la arch/x86/boot/bzImage | sed 's|^|    |'
    cp -fv arch/x86/boot/bzImage "${OUTDIR}/bzImage"
    cp -fv arch/x86/boot/bzImage "${OUTDIR}/kernel-ranchu"
    echo "==> Copied bzImage and kernel-ranchu to ${OUTDIR}"
    echo "Kernel build version banner:"
    ( strings arch/x86/boot/bzImage || true ) | grep -m1 "Linux version" | sed 's|^|    |' || true
else
    echo "==> Build Image/Image.gz (parallel jobs=${JOBS})"
    time make -j "${JOBS}" Image Image.gz
    echo
    echo "==> Build complete"
    ls -la arch/arm64/boot/Image* | sed 's|^|    |'
    cp -fv arch/arm64/boot/Image    "${OUTDIR}/Image"
    cp -fv arch/arm64/boot/Image.gz "${OUTDIR}/Image.gz"
    echo "==> Copied Image and Image.gz to ${OUTDIR}"
    echo "Kernel build version banner:"
    ( strings arch/arm64/boot/Image || true ) | grep -m1 "Linux version" | sed 's|^|    |' || true
fi
