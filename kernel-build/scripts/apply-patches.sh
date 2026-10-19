#!/bin/bash
# Apply, in order matching Wild Kernels' build pipeline exactly:
#   1. Reset kernel tree
#   2. KernelSU-Next setup (drops drivers/kernelsu into the tree)
#   3. Wild's KSU<->SUSFS integration patch (disables syscall hooks that
#      crash Android 16 mediaswcodec)
#   4. Copy SUSFS source files into kernel tree
#   5. Sublevel-specific pre-SUSFS sed fixes
#   6. Apply SUSFS kernel patch (|| true; sublevel fixes may already absorb)
#   7. Revert the pre-SUSFS sed fixes
#   8. Our anti-emulator source customizations
#
# After this, the kernel source tree is ready for build.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT}/sources/kernel"
KSU_DIR="${ROOT}/sources/kernelsu"
SUSFS_DIR="${ROOT}/sources/susfs"
WILD_DIR="${ROOT}/sources/wild-patches"

if [[ ! -d "${KERNEL_DIR}" ]]; then
    echo "ERROR: ${KERNEL_DIR} not found. Run scripts/fetch-sources.sh first." >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# 1. Reset kernel tree
# ----------------------------------------------------------------------------
echo "==> Resetting kernel tree to clean state"
( cd "${KERNEL_DIR}" \
    && git reset --hard HEAD >/dev/null \
    && git clean -fdx >/dev/null )

cd "${KERNEL_DIR}"
SUBLEVEL=$(grep -m1 '^SUBLEVEL' Makefile | awk '{print $3}')
echo "==> Kernel sublevel: ${SUBLEVEL}"

# ----------------------------------------------------------------------------
# 2. KernelSU-Next
# setup.sh ignores any pre-existing KSU_DIR and clones fresh into
# $(pwd)/KernelSU-Next (= ${KERNEL_DIR}/KernelSU-Next). We pass the pinned
# commit so it checks that one out instead of "latest tagged release".
# ----------------------------------------------------------------------------
KSU_COMMIT="5a4a71874caaad06aa126f761c93391de1d32361"
echo "==> Integrating KernelSU-Next @ ${KSU_COMMIT:0:12}"
bash "${KSU_DIR}/kernel/setup.sh" "${KSU_COMMIT}"

# ----------------------------------------------------------------------------
# 3. Wild's KSU<->SUSFS integration patch
# This patch disables KSU-Next's aggressive syscall hooks (lsm_hook,
# syscall_event_bridge, tp_marker, arm64/syscall_hook, etc.) that crash
# mediaswcodec on Android 16. Keeps only the setuid hook + extras.
# ----------------------------------------------------------------------------
WILD_KSU_PATCH="${WILD_DIR}/wild/ksun-5a4a718-susfs-f7ae19ef-gki-android14-6.1.patch"
if [[ ! -f "${WILD_KSU_PATCH}" ]]; then
    echo "ERROR: ${WILD_KSU_PATCH} missing -- re-run fetch-sources.sh" >&2
    exit 1
fi
echo "==> Applying Wild KSU<->SUSFS integration patch"
( cd drivers/kernelsu && patch -p2 -F 3 -N --no-backup-if-mismatch \
    -r /tmp/wild-ksu.rej -i "${WILD_KSU_PATCH}" )

echo "==> Ensuring linux/compat.h is included for x86_64 compat_uptr_t"
sed -i "1i #include <linux/compat.h>" drivers/kernelsu/runtime/ksud.h
echo "==> Suppressing unused-result warnings in KernelSU"
echo "ccflags-y += -Wno-unused-result -Wno-error=unused-result" >> drivers/kernelsu/Kbuild
sed -i "s/strncpy_from_user(path, \*filename_user, sizeof(path));/(void)strncpy_from_user(path, *filename_user, sizeof(path));/" drivers/kernelsu/feature/sucompat.c
echo "==> Fixing TIF_SECCOMP for x86_64 Linux 6.6"
sed -i "s/if (likely(test_thread_flag(TIF_SECCOMP)))/if (1)/" drivers/kernelsu/policy/app_profile.c
echo "==> Fixing kallsyms_lookup_name for selinux_hide.c"
sed -i "1i #include <linux/kallsyms.h>\nextern unsigned long kallsyms_lookup_name(const char *name);" drivers/kernelsu/feature/selinux_hide.c
sed -i "s/-Wno-error=unused-result/-Wno-error=unused-result -Wno-error=implicit-function-declaration/" drivers/kernelsu/Kbuild

# ----------------------------------------------------------------------------
# 4. Stage SUSFS source files
# ----------------------------------------------------------------------------
echo "==> Staging SUSFS files into kernel tree"
cp -v "${SUSFS_DIR}/kernel_patches/fs/"*.c                fs/
cp -v "${SUSFS_DIR}/kernel_patches/include/linux/"*.h     include/linux/

# ----------------------------------------------------------------------------
# 5. Pre-SUSFS sed fixes (Wild's "Fake Patches" for android15-6.6)
# These add temporary #include directives so the SUSFS kernel patch's
# context lines match across sublevels.
# ----------------------------------------------------------------------------
echo "==> Pre-SUSFS sublevel-specific fixes"
if [ "${SUBLEVEL}" -le 92 ] 2>/dev/null; then
    echo "  - sublevel<=92: add dma-buf.h to fs/proc/base.c"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
fi
if [ "${SUBLEVEL}" -le 57 ] 2>/dev/null; then
    echo "  - sublevel<=57: add zswap.h to mm/memory.c"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
fi
# kernel-fixes: sublevel<=58 needs <trace/hooks/fs.h> in fs/namespace.c
if [ "${SUBLEVEL}" -le 58 ] 2>/dev/null; then
    if ! grep -qxF '#include <trace/hooks/fs.h>' fs/namespace.c; then
        echo "  - sublevel<=58: add <trace/hooks/fs.h> to fs/namespace.c"
        sed -i '/^#include <trace\/hooks\/blk.h>$/a #include <trace\/hooks\/fs.h>' fs/namespace.c
    fi
fi

# ----------------------------------------------------------------------------
# 6. Apply SUSFS kernel patch
# ----------------------------------------------------------------------------
SUSFS_KERNEL_PATCH=$(ls "${SUSFS_DIR}/kernel_patches"/*.patch 2>/dev/null | head -1)
if [[ -z "${SUSFS_KERNEL_PATCH}" ]]; then
    echo "ERROR: no .patch file in ${SUSFS_DIR}/kernel_patches/" >&2
    exit 1
fi
echo "==> Applying SUSFS kernel patch: ${SUSFS_KERNEL_PATCH##*/}"
patch -p1 -F 3 -N --no-backup-if-mismatch -r /tmp/susfs.rej \
    -i "${SUSFS_KERNEL_PATCH}" || true

# ----------------------------------------------------------------------------
# 7. Revert the pre-SUSFS sed fixes (Wild does this too)
# ----------------------------------------------------------------------------
echo "==> Reverting pre-SUSFS sed fixes"
if [ "${SUBLEVEL}" -le 92 ] 2>/dev/null; then
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
fi
if [ "${SUBLEVEL}" -le 57 ] 2>/dev/null; then
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
fi

# ----------------------------------------------------------------------------
# 8. Module-version bypass hack (Wild's "Bypass" variant).
# Forces kernel/module/version.c::check_version to return 1 instead of 0 on
# vermagic mismatch -- so the AVD's pre-built .ko files (which carry the
# original kernel's vermagic) actually load. Without this, mediaswcodec's
# dependency chain (drm/audio/etc. modules) never comes up and the apex
# SIGABRTs. This is what the "Bypass-AnyKernel3" variant does.
# ----------------------------------------------------------------------------
echo "==> Applying module vermagic bypass hack"
sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' \
    kernel/module/version.c
if grep -A 5 "bad_version:" kernel/module/version.c | grep -q "return 1;"; then
    echo "  - bypass hack applied to kernel/module/version.c"
else
    echo "ERROR: bypass hack didn't apply" >&2
    grep -A 10 "bad_version:" kernel/module/version.c
    exit 1
fi

# Wipe the GKI protected-exports list. Otherwise modules like
# virtio_pci_modern_dev.ko fail to load with "exports protected symbol".
echo "==> Emptying GKI protected-exports list"
if ls android/abi_gki_protected_exports_* >/dev/null 2>&1; then
    for f in android/abi_gki_protected_exports_*; do
        : > "$f"
        echo "  - emptied $f"
    done
fi

# ----------------------------------------------------------------------------
# 9. Our anti-emulator source customizations
# ----------------------------------------------------------------------------
echo "==> Customizing kernel source for AVD anti-detection"
bash "${ROOT}/scripts/customize-kernel.sh" "${KERNEL_DIR}"

touch "${KERNEL_DIR}/.avd-patches-applied"
echo
echo "==> All patches applied successfully."
echo "    Next: scripts/build.sh"
