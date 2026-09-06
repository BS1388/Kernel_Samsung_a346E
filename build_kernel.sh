#!/bin/bash
# ==============================================================================
# Build script for Samsung A346E kernel (MediaTek mt6877, kernel-6.6)
# Refactored & hardened - handles bazel sandbox, casing, FDO, and compat fixes
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Globals & Setup
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
export PATH="${ROOT_DIR}/bin:${PATH}"
export TMPDIR=/tmp

# Colors for log
RED='\033[1;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; GREEN='\033[1;32m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[$(date +%H:%M:%S)] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK] $*${NC}"; }
warn() { echo -e "\n${YELLOW}[WARN] $*${NC}" >&2; }
die()  { echo -e "\n${RED}[ERROR] $*${NC}" >&2; exit 1; }

ensure_dir() { mkdir -p "$1"; }

# Detect real kernel dir (case-insensitive)
detect_kernel_dir() {
  if [ -d "${ROOT_DIR}/Kernel-6.6" ] && [ -f "${ROOT_DIR}/Kernel-6.6/Makefile" ]; then
    echo "${ROOT_DIR}/Kernel-6.6"
  elif [ -d "${ROOT_DIR}/kernel-6.6" ] && [ -f "${ROOT_DIR}/kernel-6.6/Makefile" ]; then
    echo "${ROOT_DIR}/kernel-6.6"
  else
    die "Could not find kernel-6.6 or Kernel-6.6 with Makefile in ${ROOT_DIR}"
  fi
}

# ------------------------------------------------------------------------------
# 1. System setup
# ------------------------------------------------------------------------------
setup_system() {
  log "ROOT_DIR=${ROOT_DIR}"
  log "SCRIPT_DIR=${SCRIPT_DIR}"
  ensure_dir "${ROOT_DIR}/bin"
  ulimit -n 4096 2>/dev/null || warn "ulimit -n 4096 failed"

  # Only install deps if not in GitHub Actions (where workflow already did)
  if [ -z "${GITHUB_ACTIONS:-}" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      log "Installing host dependencies (local build)"
      sudo apt-get update -y || warn "apt-get update failed"
      sudo apt-get install -y curl wget unzip python3 python3-pip git rsync \
        bc bison flex build-essential libssl-dev libelf-dev libncurses-dev \
        dwarves lz4 zstd cpio libxml2-utils xsltproc || warn "apt install partial fail"
    fi
  else
    log "Running in GitHub Actions - skipping apt install (handled by workflow)"
  fi

  git config --global user.email "builder@example.com" || true
  git config --global user.name "Builder" || true
  git config --global --add safe.directory "*" || true

  df -h || true
  nproc || true
  free -h || true
}

# ------------------------------------------------------------------------------
# 2. repo tool
# ------------------------------------------------------------------------------
download_repo_tool() {
  local dest="${ROOT_DIR}/bin/repo"
  if [ -f "$dest" ] && [ -s "$dest" ] && head -n 5 "$dest" | grep -q "repo"; then
    log "repo tool already present at $dest"
    chmod a+x "$dest"
    return 0
  fi

  log "Downloading repo tool to $dest"
  local urls=(
    "https://storage.googleapis.com/git-repo-downloads/repo"
    "https://raw.githubusercontent.com/GerritCodeReview/git-repo/main/repo"
  )
  for url in "${urls[@]}"; do
    log "Trying $url"
    if command -v curl >/dev/null 2>&1; then
      curl -L --retry 3 --retry-delay 5 -fsSL -o "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && return 0 || rm -f "$dest"
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$dest" "$url" && [ -s "$dest" ] && chmod a+x "$dest" && return 0 || rm -f "$dest"
    fi
  done

  warn "Failed to download repo from mirrors, trying apt"
  sudo apt-get install -y repo || true
  if command -v repo >/dev/null 2>&1; then
    cp "$(command -v repo)" "$dest" || true
    chmod a+x "$dest" || true
  fi

  [ -f "$dest" ] && [ -s "$dest" ] || die "repo tool not available at $dest"
  ls -lh "$dest"
  "$dest" --version || true
}

# ------------------------------------------------------------------------------
# 3. AOSP kernel sync
# ------------------------------------------------------------------------------
sync_aosp_kernel() {
  log "Syncing aosp-kernel (common-android15-6.6)"
  local aosp_dir="${ROOT_DIR}/aosp-kernel"
  ensure_dir "$aosp_dir"
  pushd "$aosp_dir" >/dev/null

  if [ ! -d .repo ]; then
    log "repo init"
    if ! repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle --repo-url=https://gerrit.googlesource.com/git-repo; then
      log "First repo init failed, retrying without repo-url"
      repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6 --depth=1 --no-clone-bundle || warn "repo init failed"
    fi
  fi

  log "repo sync (up to 3 attempts, -j2)"
  local attempt
  for attempt in 1 2 3; do
    df -h || true
    if repo sync -c -j2 --force-sync --no-clone-bundle --no-tags; then
      ok "repo sync succeeded on attempt $attempt"
      df -h
      du -sh . || true
      break
    fi
    warn "repo sync failed attempt $attempt"
    sleep 10
    [ "$attempt" -eq 3 ] && die "repo sync failed after 3 attempts"
  done

  popd >/dev/null
}

# ------------------------------------------------------------------------------
# 4. Link prebuilts & externals
# ------------------------------------------------------------------------------
link_prebuilts() {
  log "Linking prebuilts"
  local aosp_prebuilts="${ROOT_DIR}/aosp-kernel/prebuilts"
  local kernel_prebuilts="${ROOT_DIR}/kernel/prebuilts"

  if [ ! -d "$aosp_prebuilts" ]; then
    ls -la "${ROOT_DIR}/aosp-kernel/" >&2 || true
    die "aosp-kernel/prebuilts not found at $aosp_prebuilts"
  fi

  # Ensure kernel/prebuilts is a symlink to aosp-kernel/prebuilts
  rm -rf "$kernel_prebuilts" || true
  ln -sfn "$aosp_prebuilts" "$kernel_prebuilts"
  ok "Linked $kernel_prebuilts -> $aosp_prebuilts"

  # Optional external tools
  for ext in zopfli pigz; do
    local src="${ROOT_DIR}/aosp-kernel/external/${ext}"
    local dst="${ROOT_DIR}/kernel/external/${ext}"
    if [ -d "$src" ] && [ ! -e "$dst" ]; then
      ln -sfn "$src" "$dst" || warn "Failed to link $ext"
      ok "Linked $dst -> $src"
    fi
  done
}

# ------------------------------------------------------------------------------
# 5a. Compatibility fixes (kernel-6.6 update vs device modules)
# ------------------------------------------------------------------------------
apply_compat_fixes() {
  log "Applying compatibility fixes for kernel-6.6 vs device_modules-6.6"

  # --- Fix 1: Restore include/linux/loop.h which was removed in new kernel ---
  # New kernel moved struct loop_device to drivers/block/loop.c (private),
  # but zram_ext.c still includes <linux/loop.h> and accesses lo->lo_backing_file
  # Error: zram_ext.c:541:16 error: incomplete definition of type 'struct loop_device'
  # Solution: restore old header from de924f856 if missing
  local loop_headers=(
    "kernel-6.6/include/linux/loop.h"
    "${ROOT_DIR}/kernel-6.6/include/linux/loop.h"
    "${ROOT_DIR}/Kernel-6.6/include/linux/loop.h"
  )
  for lh in "${loop_headers[@]}"; do
    # Check if file exists in workspace or root
    if [ ! -f "$lh" ]; then
      log "loop.h missing at $lh, will create after rsync"
    fi
  done

  # This function is called from inside kernel/ workspace after rsync,
  # so we handle both root and workspace paths
  local target_loop="kernel-6.6/include/linux/loop.h"
  if [ ! -f "$target_loop" ]; then
    log "Creating $target_loop from embedded old version"
    ensure_dir "$(dirname "$target_loop")"
    cat > "$target_loop" <<'LOOP_EOF'
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_LOOP_H
#define _LINUX_LOOP_H

#include <linux/blkdev.h>
#include <linux/blk-mq.h>
#include <linux/bio.h>
#include <linux/mutex.h>
#include <linux/workqueue.h>
#include <uapi/linux/loop.h>

struct loop_func_table;

struct loop_device {
	int		lo_number;
	loff_t		lo_offset;
	loff_t		lo_sizelimit;
	int		lo_flags;
	char		lo_file_name[LO_NAME_SIZE];
	char		lo_crypt_name[LO_NAME_SIZE];
	char		lo_encrypt_key[LO_KEY_SIZE];
	int		lo_encrypt_key_size;
	struct loop_func_table *lo_encryption;
	__u32           lo_init[2];
	uid_t		lo_key_owner;
	int		(*ioctl)(struct loop_device *, int cmd,
				 unsigned long arg);

	struct file *	lo_backing_file;
	struct block_device *lo_device;
	void		*key_data;

	gfp_t		old_gfp_mask;

	spinlock_t		lo_lock;
	int			lo_state;
	struct kthread_worker	queue_worker;
	struct kthread_work		rootcg_work;
	struct kthread_work		free_work;
	struct task_struct	*worker_task;
	bool			use_dio;
	bool			sysfs_inited;

	struct request_queue	*lo_queue;
	struct blk_mq_tag_set	tag_set;
	struct gendisk		*lo_disk;
	struct mutex		lo_mutex;
	bool			idr_visible;
};

static inline bool is_loop_device(struct file *file)
{
	struct inode *i = file->f_mapping->host;
	return S_ISBLK(i->i_mode) && MAJOR(i->i_rdev) == LOOP_MAJOR;
}

#endif /* _LINUX_LOOP_H */
LOOP_EOF
    ok "Created $target_loop"
  else
    ok "loop.h exists at $target_loop"
  fi

  # Also ensure root copy exists for future rsyncs
  local root_loop="${ROOT_DIR}/kernel-6.6/include/linux/loop.h"
  local root_loop_cap="${ROOT_DIR}/Kernel-6.6/include/linux/loop.h"
  if [ -d "${ROOT_DIR}/kernel-6.6" ] && [ ! -f "$root_loop" ]; then
    log "Copying loop.h to $root_loop"
    ensure_dir "$(dirname "$root_loop")"
    cp -v "$target_loop" "$root_loop" || true
  fi
  if [ -d "${ROOT_DIR}/Kernel-6.6" ] && [ ! -f "$root_loop_cap" ]; then
    log "Copying loop.h to $root_loop_cap"
    ensure_dir "$(dirname "$root_loop_cap")"
    cp -v "$target_loop" "$root_loop_cap" || true
  fi

  # --- Fix 2: zsmalloc.c and other drivers MAX/MIN redefinition ---
  # Error: zsmalloc.c:122:9 error: 'MAX' macro redefined [-Werror,-Wmacro-redefined]
  # Error: rpmb-mtk.c:171:9 error: 'MIN' macro redefined
  # New kernel's include/linux/minmax.h defines MIN/MAX, old drivers define their own
  # Solution: remove custom MIN/MAX and include minmax.h
  log "Fixing MIN/MAX redefinition in device modules"
  local minmax_files=(
    "kernel_device_modules-6.6/drivers/mm/zsmalloc.c"
    "kernel_device_modules-6.6/drivers/char/rpmb/rpmb-mtk.c"
  )
  for zf in "${minmax_files[@]}"; do
    if [ -f "$zf" ]; then
      if grep -q "^#define[[:space:]]*MAX[[:space:]]*(" "$zf" || grep -q "^#define[[:space:]]*MIN[[:space:]]*(" "$zf"; then
        log "Patching $zf to remove custom MIN/MAX macros"
        sed -i '/^#define[[:space:]]*MAX[[:space:]]*(/d' "$zf" || true
        sed -i '/^#define[[:space:]]*MIN[[:space:]]*(/d' "$zf" || true
        if ! grep -q "#include <linux/minmax.h>" "$zf"; then
          sed -i 's|#include <linux/kernel.h>|#include <linux/kernel.h>\n#include <linux/minmax.h>|' "$zf" || \
          sed -i '1i #include <linux/minmax.h>' "$zf"
        fi
        ok "Patched $zf"
      else
        ok "$zf already fixed (no custom MIN/MAX)"
      fi
    fi
  done

  # Broader fix: remove MIN/MAX from all .c/.h files in device_modules that cause redefinition
  # This is a safety net for other drivers (cpufreq_limit, ged_dvfs.h, etc.)
  # Old drivers defined MAX(x,y) MIN(x,y) or MAX(a,b) MIN(a,b) which collides with new kernel's minmax.h
  log "Broad MIN/MAX cleanup in drivers/"
  find "kernel_device_modules-6.6/drivers" \( -name "*.c" -o -name "*.h" \) -type f | while read -r f; do
    if grep -q "^#define[[:space:]]*MAX[[:space:]]*(" "$f" 2>/dev/null || \
       grep -q "^#define[[:space:]]*MIN[[:space:]]*(" "$f" 2>/dev/null; then
      # Avoid deleting MAX_BW_PROFILE etc - only delete macros with 2 args like MAX(x,y) or MAX(a,b)
      if grep -q "^#define[[:space:]]*MAX[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)" "$f" || \
         grep -q "^#define[[:space:]]*MIN[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)" "$f"; then
        log "Cleaning $f"
        sed -i '/^#define[[:space:]]*MAX[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
        sed -i '/^#define[[:space:]]*MIN[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
        if ! grep -q "linux/minmax.h" "$f"; then
          sed -i '1i #include <linux/minmax.h>' "$f" || true
        fi
      fi
    fi
  done

  # --- Fix 2a: stmmac VLA error with max_t ---
  # Error: stmmac_main.c:2855:13: error: variable length array used [-Werror,-Wvla]
  # int status[max_t(u32, MTL_MAX_TX_QUEUES, MTL_MAX_RX_QUEUES)];
  # max_t expands to statement expression, not constant, causing VLA
  local stmmac_file="kernel_device_modules-6.6/drivers/net/ethernet/stmicro/stmmac/stmmac_main.c"
  if [ -f "$stmmac_file" ]; then
    if grep -q "status\[max_t" "$stmmac_file"; then
      log "Patching $stmmac_file for VLA compat"
      sed -i 's/int status\[max_t(u32, MTL_MAX_TX_QUEUES, MTL_MAX_RX_QUEUES)\];/int status[MTL_MAX_TX_QUEUES > MTL_MAX_RX_QUEUES ? MTL_MAX_TX_QUEUES : MTL_MAX_RX_QUEUES];/' "$stmmac_file" || true
      ok "Patched $stmmac_file"
    fi
  fi

  # --- Fix 2c: Samsung PM drivers - sec_thermistor Makefile missing and power.h private include + missing SEC_PM Kconfig ---
  # Error: Unable to find sec_thermistor.ko, sec_pm_debug.ko, sec_wakeup_cpu_allocator.ko
  # Root cause: drivers/samsung/pm/Makefile missing sec_thermistor/ subdirectory
  # And sec_wakeup_cpu_allocator.c includes private kernel/power/power.h
  # And drivers/samsung/pm/Kconfig missing config SEC_PM (depends on SEC_PM fails)
  local pm_kconfig="kernel_device_modules-6.6/drivers/samsung/pm/Kconfig"
  if [ -f "$pm_kconfig" ]; then
    if ! grep -q "^config SEC_PM$" "$pm_kconfig"; then
      log "Patching $pm_kconfig to add missing SEC_PM core config"
      # Insert at top after header
      tmp_kc=$(mktemp)
      {
        head -n 7 "$pm_kconfig"
        cat <<'KCEOF'
config SEC_PM
	tristate "Samsung PM core"
	default y
	help
	  Samsung Power Management core. Required for sec_pm_debug,
	  sec_wakeup_cpu_allocator and sec_thermistor.

KCEOF
        tail -n +8 "$pm_kconfig"
      } > "$tmp_kc"
      mv "$tmp_kc" "$pm_kconfig"
      ok "Patched $pm_kconfig with SEC_PM"
      cat "$pm_kconfig" | head -n 20
    else
      ok "SEC_PM already in $pm_kconfig"
    fi
    if ! grep -q 'sec_thermistor/Kconfig' "$pm_kconfig"; then
      log "Adding sec_thermistor Kconfig source to $pm_kconfig"
      echo 'source "$(KCONFIG_EXT_PREFIX)drivers/samsung/pm/sec_thermistor/Kconfig"' >> "$pm_kconfig"
      ok "Added sec_thermistor Kconfig source"
    fi
  fi

  local pm_makefile="kernel_device_modules-6.6/drivers/samsung/pm/Makefile"
  if [ -f "$pm_makefile" ]; then
    if ! grep -q "sec_thermistor" "$pm_makefile"; then
      log "Patching $pm_makefile to include sec_thermistor/"
      echo 'obj-$(CONFIG_SEC_PM_THERMISTOR)	+= sec_thermistor/' >> "$pm_makefile"
      ok "Patched $pm_makefile"
    fi
  fi

  local wakeup_file="kernel_device_modules-6.6/drivers/samsung/pm/sec_wakeup_cpu_allocator.c"
  if [ -f "$wakeup_file" ]; then
    if grep -q 'kernel/power/power.h' "$wakeup_file"; then
      log "Patching $wakeup_file to remove private power.h include"
      # Use ^ anchor to avoid matching inside already-commented line /* #include ... */
      sed -i 's|^#include "../../../kernel/power/power.h"|/* compat: removed private power.h for kernel-6.6 */|' "$wakeup_file" || true
      sed -i 's|^#include ".*kernel/power/power.h"|/* compat: removed private power.h for kernel-6.6 */|' "$wakeup_file" || true
      # Also remove the second commented line if it exists from previous patch (avoid nested /*)
      sed -i '/^\/\* #include ".*kernel\/power\/power.h" \*\//d' "$wakeup_file" || true
      ok "Patched $wakeup_file"
      # Verify no nested comment remains
      if grep -q '/\*.*/\*.*power.h' "$wakeup_file"; then
        warn "Nested comment still in $wakeup_file, cleaning"
        sed -i '/power.h/d' "$wakeup_file" || true
        echo '/* compat: removed private power.h for kernel-6.6 */' >> "$wakeup_file.tmp" || true
      fi
    fi
    # Ensure suspend.h is included for PM_POST_SUSPEND and register_pm_notifier (lost with power.h)
    if ! grep -q 'linux/suspend.h' "$wakeup_file"; then
      log "Adding missing suspend.h to $wakeup_file"
      if grep -q 'uapi/linux/sched/types.h' "$wakeup_file"; then
        sed -i '/#include <uapi\/linux\/sched\/types.h>/a #include <linux\/suspend.h>\n#include <linux\/pm.h>' "$wakeup_file" || true
      elif grep -q 'trace/events/power.h' "$wakeup_file"; then
        sed -i '/#include <trace\/events\/power.h>/a #include <linux\/suspend.h>' "$wakeup_file" || true
      else
        sed -i '1i #include <linux/suspend.h>\n#include <linux/pm.h>' "$wakeup_file" || true
      fi
      ok "Added suspend.h to $wakeup_file"
    fi
  fi

  # --- Fix 2b: UFS_CMD_ERR removed in new kernel ---
  # Error: ufs-sec-feature.c:1489:44: error: use of undeclared identifier 'UFS_CMD_ERR'
  # Old kernel had UFS_CMD_SEND, UFS_CMD_COMP, UFS_CMD_ERR, UFS_DEV_COMP
  # New kernel has only UFS_CMD_SEND, UFS_CMD_COMP, UFS_DEV_COMP (no ERR)
  # Solution: define UFS_CMD_ERR as UFS_TM_ERR if missing
  local ufs_file="kernel_device_modules-6.6/drivers/ufs/vendor/ufs-sec-feature.c"
  if [ -f "$ufs_file" ]; then
    if grep -q "UFS_CMD_ERR" "$ufs_file" && ! grep -q "#define UFS_CMD_ERR" "$ufs_file"; then
      log "Patching $ufs_file for UFS_CMD_ERR compat"
      # Insert compat define after ufs-sec-sysfs.h include
      if grep -q "ufs-sec-sysfs.h" "$ufs_file"; then
        sed -i '/#include "ufs-sec-sysfs.h"/a \\n/* Compat fix: UFS_CMD_ERR removed in new kernel */\n#ifndef UFS_CMD_ERR\n#define UFS_CMD_ERR UFS_TM_ERR\n#endif' "$ufs_file" || true
      else
        sed -i '1i /* Compat fix: UFS_CMD_ERR removed */\n#ifndef UFS_CMD_ERR\n#define UFS_CMD_ERR UFS_TM_ERR\n#endif' "$ufs_file" || true
      fi
      ok "Patched $ufs_file"
    else
      ok "$ufs_file already fixed or no UFS_CMD_ERR"
    fi
  fi

  # --- Fix 3: Ensure Google-FDO exists and is valid ---
  if [ -d "Google-FDO" ]; then
    if [ -f "Google-FDO/kernel.afdo" ]; then
      local size
      size=$(stat -c%s "Google-FDO/kernel.afdo" 2>/dev/null || stat -f%z "Google-FDO/kernel.afdo" 2>/dev/null || echo 0)
      if [ "$size" -lt 1000000 ]; then
        warn "Google-FDO/kernel.afdo too small ($size bytes), may be invalid"
      else
        ok "Google-FDO/kernel.afdo valid ($size bytes)"
      fi
    else
      warn "Google-FDO/kernel.afdo missing in workspace"
    fi
  fi
}

# ------------------------------------------------------------------------------
# 5. Prepare kernel/ workspace (fix bazel sandbox symlink issues)
# ------------------------------------------------------------------------------
prepare_workspace() {
  log "Preparing kernel/ workspace (fix bazel sandbox)"

  local real_kernel_dir
  real_kernel_dir="$(detect_kernel_dir)"
  log "Real kernel dir detected: $real_kernel_dir"
  local real_kernel_basename
  real_kernel_basename="$(basename "$real_kernel_dir")"

  pushd "${ROOT_DIR}/kernel" >/dev/null

  # --- kernel-6.6: must be real dir, not symlink outside workspace ---
  # Newer bazel rejects symlinks pointing outside workspace
  if [ -L "kernel-6.6" ] || [ ! -d "kernel-6.6" ]; then
    log "Recreating kernel/kernel-6.6 as real directory from $real_kernel_dir"
    rm -rf "kernel-6.6" || true
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links "${real_kernel_dir}/" "kernel-6.6/" || cp -r "${real_kernel_dir}" "kernel-6.6"
    else
      cp -r "${real_kernel_dir}" "kernel-6.6"
    fi
  else
    log "Syncing $real_kernel_dir -> kernel/kernel-6.6"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links --delete "${real_kernel_dir}/" "kernel-6.6/" || cp -r "${real_kernel_dir}/." "kernel-6.6/"
    else
      cp -r "${real_kernel_dir}/." "kernel-6.6/" || true
    fi
  fi

  # If original was Kernel-6.6 (capital), also ensure lowercase exists for bazel
  if [ "$real_kernel_basename" = "Kernel-6.6" ]; then
    log "Original is Kernel-6.6 (capital), ensuring kernel-6.6 exists"
    if [ ! -d "${ROOT_DIR}/kernel-6.6" ]; then
      log "Creating ${ROOT_DIR}/kernel-6.6 as copy of ${real_kernel_dir}"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --copy-links "${real_kernel_dir}/" "${ROOT_DIR}/kernel-6.6/" || true
      else
        cp -r "${real_kernel_dir}" "${ROOT_DIR}/kernel-6.6" || true
      fi
    fi
  fi

  # --- build/bazel_common_rules: same issue ---
  if [ -L "build/bazel_common_rules" ] || [ ! -d "build/bazel_common_rules" ]; then
    log "Recreating build/bazel_common_rules as real directory"
    rm -rf "build/bazel_common_rules" || true
    if [ -d "${ROOT_DIR}/build/bazel_common_rules" ]; then
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --copy-links "${ROOT_DIR}/build/bazel_common_rules/" "build/bazel_common_rules/" || cp -r "${ROOT_DIR}/build/bazel_common_rules" "build/bazel_common_rules"
      else
        cp -r "${ROOT_DIR}/build/bazel_common_rules" "build/bazel_common_rules"
      fi
    else
      warn "Source ${ROOT_DIR}/build/bazel_common_rules not found"
    fi
  else
    log "Syncing build/bazel_common_rules"
    if [ -d "${ROOT_DIR}/build/bazel_common_rules" ]; then
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --copy-links --delete "${ROOT_DIR}/build/bazel_common_rules/" "build/bazel_common_rules/" || true
      else
        cp -r "${ROOT_DIR}/build/bazel_common_rules/." "build/bazel_common_rules/" || true
      fi
    fi
  fi

  # --- Google-FDO: external FDO profile must be inside kernel/ workspace for bazel ---
  # The label //Google-FDO:kernel.afdo is resolved from workspace root (kernel/), so we need kernel/Google-FDO
  # Support both Google-FDO (new) and google-FDO (old) naming
  local fdo_src=""
  if [ -d "${ROOT_DIR}/Google-FDO" ]; then
    fdo_src="${ROOT_DIR}/Google-FDO"
  elif [ -d "${ROOT_DIR}/google-FDO" ]; then
    fdo_src="${ROOT_DIR}/google-FDO"
    warn "Found old google-FDO naming, using it but prefer Google-FDO"
  fi

  if [ -n "$fdo_src" ] && [ -d "$fdo_src" ]; then
    log "Syncing $fdo_src to kernel/Google-FDO for bazel"
    rm -rf "Google-FDO" || true
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --copy-links "${fdo_src}/" "Google-FDO/" || cp -r "${fdo_src}" "Google-FDO"
    else
      cp -r "${fdo_src}" "Google-FDO"
    fi
    ls -lh "Google-FDO/" || true
    if [ ! -f "Google-FDO/kernel.afdo" ]; then
      warn "kernel.afdo missing after sync"
    fi
  else
    warn "Google-FDO not found at ${ROOT_DIR}/Google-FDO nor google-FDO"
  fi

  # Standard symlinks required by kleaf
  log "Setting up WORKSPACE and bazel wrapper"
  ln -sfn "build/bazel_mgk_rules/kleaf/bazel.WORKSPACE" "WORKSPACE"
  ln -sfn "../build/kernel/kleaf/bazel.sh" "tools/bazel"
  chmod +x "build/kernel/kleaf/bazel.sh" "tools/bazel" || true

  # Verify critical paths
  for p in "kernel-6.6" "WORKSPACE" "tools/bazel" "build/bazel_common_rules"; do
    if [ ! -e "$p" ]; then
      die "Required path $p missing after prepare_workspace"
    fi
    ok "Verified $p -> $(ls -ld "$p" | awk '{print $NF}')"
  done

  # --- mkbootimg fix ---
  if [ ! -e "tools/mkbootimg" ] || { [ -L "tools/mkbootimg" ] && [ ! -e "$(readlink -f "tools/mkbootimg" 2>/dev/null || echo "")" ]; }; then
    warn "tools/mkbootimg missing/broken, attempting fix"
    ls -la "tools/" || true
    # Try to link from aosp-kernel
    if [ -f "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg/mkbootimg.py" ]; then
      ensure_dir "${ROOT_DIR}/system/tools"
      ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" || true
      ok "Linked system/tools/mkbootimg"
    fi
    # Try prebuilt mkbootimg binary
    if [ -f "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
      ln -sfn "${ROOT_DIR}/aosp-kernel/prebuilts/build-tools/path/linux-x86/mkbootimg" "tools/mkbootimg" || true
      ok "Linked tools/mkbootimg from aosp prebuilts"
    elif [ -f "prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
      ln -sfn "../../prebuilts/build-tools/path/linux-x86/mkbootimg" "tools/mkbootimg" || true
      ok "Linked tools/mkbootimg from kernel prebuilts"
    fi
  fi

  # Ensure system/tools/mkbootimg exists for bazel
  if [ ! -e "${ROOT_DIR}/system/tools/mkbootimg" ] && [ -d "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" ]; then
    ensure_dir "${ROOT_DIR}/system/tools"
    ln -sfn "${ROOT_DIR}/aosp-kernel/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg" || true
    ok "Ensured ${ROOT_DIR}/system/tools/mkbootimg"
  fi

  # --- MTK signing key & module sig fix ---
  # The build fails with sign-file: ../kernel_device_modules-6.6/certs/mtk_signing_key.pem No such file
  # Root cause: bazel sandbox doesn't have mtk_signing_key.pem at expected relative path
  # Fix 1: ensure key exists in all certs locations
  # Fix 2: patch defconfigs to disable module signing (robust workaround for custom kernels)
  log "Ensuring mtk_signing_key.pem and module sig workaround"
  local mtk_key_src=""
  # Search in order of preference
  for candidate in \
    "${ROOT_DIR}/kernel/kernel_device_modules-6.6/certs/mtk_signing_key.pem" \
    "$(pwd)/kernel_device_modules-6.6/certs/mtk_signing_key.pem" \
    "${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem" \
    "${ROOT_DIR}/Kernel-6.6/certs/mtk_signing_key.pem" \
    "kernel-6.6/certs/mtk_signing_key.pem"; do
    if [ -f "$candidate" ]; then
      mtk_key_src="$candidate"
      break
    fi
  done

  if [ -n "$mtk_key_src" ] && [ -f "$mtk_key_src" ]; then
    log "Found MTK key at $mtk_key_src"
    ensure_dir "${ROOT_DIR}/kernel-6.6/certs"
    cp -v "$mtk_key_src" "${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem" 2>/dev/null || true
    if [ -d "${ROOT_DIR}/Kernel-6.6" ]; then
      ensure_dir "${ROOT_DIR}/Kernel-6.6/certs"
      cp -v "$mtk_key_src" "${ROOT_DIR}/Kernel-6.6/certs/mtk_signing_key.pem" 2>/dev/null || true
    fi
    ensure_dir "kernel-6.6/certs"
    cp -v "$mtk_key_src" "kernel-6.6/certs/mtk_signing_key.pem" 2>/dev/null || true
    ensure_dir "kernel_device_modules-6.6/certs"
    cp -v "$mtk_key_src" "kernel_device_modules-6.6/certs/mtk_signing_key.pem" 2>/dev/null || true
  else
    warn "MTK signing key not found in any location, module signing may fail"
    ls -lh "kernel-6.6/certs/" "kernel_device_modules-6.6/certs/" 2>&1 | head -n 20 || true
  fi

  # Fix 2: patch gki_defconfig to disable module sig (if not already)
  if [ -f "kernel-6.6/arch/arm64/configs/gki_defconfig" ]; then
    log "Patching gki_defconfig to disable MODULE_SIG"
    # Disable all module sig options robustly
    sed -i 's/^CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/' "kernel-6.6/arch/arm64/configs/gki_defconfig" || true
    sed -i 's/^CONFIG_MODULE_SIG_FORCE=y/# CONFIG_MODULE_SIG_FORCE is not set/' "kernel-6.6/arch/arm64/configs/gki_defconfig" || true
    sed -i 's/^CONFIG_MODULE_SIG_ALL=y/# CONFIG_MODULE_SIG_ALL is not set/' "kernel-6.6/arch/arm64/configs/gki_defconfig" || true
    sed -i 's/^CONFIG_MODULE_SIG_SHA512=y/# CONFIG_MODULE_SIG_SHA512 is not set/' "kernel-6.6/arch/arm64/configs/gki_defconfig" || true
    sed -i 's/^CONFIG_MODULE_SIG_PROTECT=y/# CONFIG_MODULE_SIG_PROTECT is not set/' "kernel-6.6/arch/arm64/configs/gki_defconfig" || true
    # Also handle =y with possible spaces
    sed -i 's/^CONFIG_MODULE_SIG[[:space:]]*=.*/# CONFIG_MODULE_SIG is not set/' "kernel-6.6/arch/arm64/configs/gki_defconfig" || true
    # Ensure it's disabled at end if not present
    if ! grep -q "CONFIG_MODULE_SIG" "kernel-6.6/arch/arm64/configs/gki_defconfig"; then
      echo "# CONFIG_MODULE_SIG is not set" >> "kernel-6.6/arch/arm64/configs/gki_defconfig"
    fi
  fi

  # Patch mediatek-bazel_defconfig to use auto-generated key
  for defconfig_path in "kernel_device_modules-6.6/arch/arm64/configs/mediatek-bazel_defconfig"; do
    if [ -f "$defconfig_path" ]; then
      log "Patching $defconfig_path to use certs/signing_key.pem"
      sed -i 's|CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"|' "$defconfig_path" || true
      # Also disable sig if needed (will be overridden by overlay)
      # sed -i 's/^CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/' "$defconfig_path" || true
    fi
  done

  # Create disable_module_sig.config fragment if not exists or incomplete
  local disable_sig_fragment="kernel_device_modules-6.6/kernel/configs/disable_module_sig.config"
  log "Ensuring $disable_sig_fragment"
  ensure_dir "$(dirname "$disable_sig_fragment")"
  cat > "$disable_sig_fragment" <<'EOF'
# Disable module signing for custom kernel builds - fixes bazel sandbox sign-file failure
CONFIG_MODULE_SIG=n
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODULE_SIG_ALL is not set
# CONFIG_MODULE_SIG_SHA512 is not set
CONFIG_MODULE_SIG_HASH=""
CONFIG_MODULE_SIG_KEY=""
CONFIG_SYSTEM_TRUSTED_KEYRING=n
EOF
  ok "Created $disable_sig_fragment"
  cat "$disable_sig_fragment"

  ls -lh "kernel-6.6/certs/mtk_signing_key.pem" "kernel_device_modules-6.6/certs/mtk_signing_key.pem" "$disable_sig_fragment" 2>&1 || true

  # Apply compatibility fixes (loop.h, zsmalloc, etc.)
  apply_compat_fixes

  # List critical files for debug
  ls -lh "kernel-6.6/build.config.common" 2>/dev/null || warn "kernel-6.6/build.config.common not found"
  ls -lh "prebuilts" 2>/dev/null || true
  ls -lh "Google-FDO/kernel.afdo" 2>/dev/null || warn "Google-FDO/kernel.afdo not found"

  popd >/dev/null
  ok "Workspace prepared"
}

# ------------------------------------------------------------------------------
# 6. Patch stamp.bzl and fix build.sh shebang (Samsung bug: SPDX before #!/bin/bash)
# ------------------------------------------------------------------------------
patch_stamp() {
  log "Patching stamp.bzl to avoid git dirty version"

  local stamp_files=(
    "${ROOT_DIR}/kernel/build/kernel/kleaf/impl/stamp.bzl"
    "${ROOT_DIR}/aosp-kernel/build/kernel/kleaf/impl/stamp.bzl"
  )

  for stamp in "${stamp_files[@]}"; do
    if [ -f "$stamp" ]; then
      log "Patching $stamp"
      cp "$stamp" "${stamp}.bak" 2>/dev/null || true
      # Replace stable_scmversion_cmd with echo ''
      sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" "$stamp" || warn "sed failed for $stamp"
      sed -i 's/-maybe-dirty//g' "$stamp" || true
      head -n 20 "$stamp" | tail -n 10 || true
    else
      warn "$stamp not found, skipping"
    fi
  done

  # Fix Samsung's broken shebang: SPDX line before #!/bin/bash causes /bin/sh to be used -> source: not found
  log "Fixing kernel_device_modules-6.6/build.sh shebang"
  local build_scripts=(
    "${ROOT_DIR}/kernel/kernel_device_modules-6.6/build.sh"
    "${ROOT_DIR}/kernel/kernel_device_modules-6.6/build_abi.sh"
    "${ROOT_DIR}/kernel-6.6/kernel_device_modules-6.6/build.sh"
    "${ROOT_DIR}/Kernel-6.6/kernel_device_modules-6.6/build.sh"
    "${ROOT_DIR}/kernel-6.6/build/kernel/kleaf/bazel.sh"
    "${ROOT_DIR}/Kernel-6.6/build/kernel/kleaf/bazel.sh"
  )
  for bs in "${build_scripts[@]}"; do
    if [ -f "$bs" ]; then
      log "Checking $bs (first line: $(head -n1 "$bs"))"
      if head -n1 "$bs" | grep -q "SPDX"; then
        log "Fixing shebang order in $bs (SPDX before shebang)"
        local tmp
        tmp=$(mktemp)
        {
          echo "#!/bin/bash"
          # Keep original content without any shebang lines
          grep -v "^#!/bin/bash" "$bs" || true
        } > "$tmp"
        mv "$tmp" "$bs"
        chmod +x "$bs"
        ok "Fixed $bs"
        head -n 3 "$bs"
      else
        ok "$bs shebang OK (first line is shebang)"
      fi
    fi
  done
}

# ------------------------------------------------------------------------------
# 7. Generate build.config
# ------------------------------------------------------------------------------
generate_build_config() {
  log "Generating build.config"

  # gen_build_config.py calculates kernel_dir based on cwd, so must run from kernel/ dir
  # to get correct relative path (kernel_device_modules-6.6 not kernel/kernel_device_modules-6.6)
  pushd "${ROOT_DIR}/kernel" >/dev/null

  local out_base="${ROOT_DIR}/out/target/product/a34x/obj"
  ensure_dir "${out_base}/KERNEL_OBJ"
  ensure_dir "${out_base}/KLEAF_OBJ"

  local gen_script="kernel_device_modules-6.6/scripts/gen_build_config.py"
  if [ ! -f "$gen_script" ]; then
    die "gen_build_config.py not found at $gen_script (pwd=$(pwd))"
  fi

  log "Running $gen_script from $(pwd)"
  local overlays="mt6877_overlay.config mt6877_teegris_5_overlay.config"
  if [ -f "kernel_device_modules-6.6/kernel/configs/disable_module_sig.config" ]; then
    overlays="$overlays disable_module_sig.config"
    log "Including disable_module_sig.config in overlays: $overlays"
  fi
  python3 "$gen_script" \
    --kernel-defconfig mediatek-bazel_defconfig \
    --kernel-defconfig-overlays "$overlays" \
    --kernel-build-config-overlays "" \
    -m user \
    -o "../out/target/product/a34x/obj/KERNEL_OBJ/build.config"

  ok "Generated ${out_base}/KERNEL_OBJ/build.config"
  cat "${out_base}/KERNEL_OBJ/build.config"

  popd >/dev/null
}

# ------------------------------------------------------------------------------
# 8. Run bazel build
# ------------------------------------------------------------------------------
run_kernel_build() {
  log "Setting up build environment"

  # Must run from kernel/ directory for bazel wrapper
  pushd "${ROOT_DIR}/kernel" >/dev/null

  export DEVICE_MODULES_DIR="kernel_device_modules-6.6"
  export BUILD_CONFIG="../out/target/product/a34x/obj/KERNEL_OBJ/build.config"
  export OUT_DIR="../out/target/product/a34x/obj/KLEAF_OBJ"
  export DIST_DIR="../out/target/product/a34x/obj/KLEAF_OBJ/dist"
  export DEFCONFIG_OVERLAYS="mt6877_overlay.config mt6877_teegris_5_overlay.config"
  export PROJECT="mgk_64_k66"
  export MODE="user"
  export KERNEL_VERSION="kernel-6.6"
  export SOURCE_DATE_EPOCH="$(date +%s)"
  export KBUILD_BUILD_USER="builder"
  export KBUILD_BUILD_HOST="github"
  export BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
  export SANDBOX=0
  export BUILD_CONFIG_FRAGMENTS=""

  log "ENV:"
  echo "  DEVICE_MODULES_DIR=$DEVICE_MODULES_DIR"
  echo "  BUILD_CONFIG=$BUILD_CONFIG (exists: $([ -f "$BUILD_CONFIG" ] && echo yes || echo no))"
  echo "  OUT_DIR=$OUT_DIR"
  echo "  DIST_DIR=$DIST_DIR"
  echo "  PROJECT=$PROJECT MODE=$MODE KERNEL_VERSION=$KERNEL_VERSION"
  echo "  SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

  local build_sh="./kernel_device_modules-6.6/build.sh"
  if [ ! -x "$build_sh" ]; then
    chmod +x "$build_sh" || true
  fi
  [ -f "$build_sh" ] || die "build.sh not found at $build_sh"

  log "Checking bazel wrapper"
  ls -lh "tools/bazel" "build/kernel/kleaf/bazel.sh" || die "bazel wrapper missing"
  df -h
  free -h || true

  log "Starting kernel build (this takes ~50min)"
  # Use bash explicitly - Samsung's build.sh has broken shebang (SPDX before #!/bin/bash) causing /bin/sh to be used -> source: not found
  # Always call with bash
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL bash "$build_sh"
  else
    bash "$build_sh"
  fi

  popd >/dev/null
  ok "Kernel build finished"
}

# ------------------------------------------------------------------------------
# 9. Collect Image
# ------------------------------------------------------------------------------
collect_image() {
  log "Collecting Image"
  pushd "${ROOT_DIR}" >/dev/null

  log "Searching for Image in out/"
  find out -name "Image" -type f 2>/dev/null | head -n 20 || true
  ls -lh "out/target/product/a34x/obj/KLEAF_OBJ/dist/" 2>/dev/null || true

  local primary_src="out/target/product/a34x/obj/KLEAF_OBJ/dist/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/Image"
  local dest="${ROOT_DIR}/Image"

  if [ -f "$primary_src" ]; then
    cp -v "$primary_src" "$dest"
    ok "Copied primary $primary_src -> $dest"
  else
    warn "Primary Image not found at $primary_src, searching fallback"
    local found
    found=$(find out -name "Image" -type f 2>/dev/null | grep -v ".*\.d$" | head -n 1 || true)
    if [ -n "$found" ] && [ -f "$found" ]; then
      cp -v "$found" "$dest"
      ok "Copied fallback $found -> $dest"
    else
      die "Image not found! Checked $primary_src and searched out/. Build failed."
    fi
  fi

  ls -lh "$dest"
  sha256sum "$dest" || true
  ok "تمام! فایل Image در $dest آماده است."

  popd >/dev/null
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log "=== A346E Kernel Build Started ==="
  log "Date: $(date)"
  log "User: $(whoami) Host: $(hostname) PWD: $(pwd)"

  setup_system
  download_repo_tool
  sync_aosp_kernel
  link_prebuilts
  prepare_workspace
  patch_stamp
  generate_build_config
  run_kernel_build
  collect_image

  log "=== Build Completed Successfully ==="
}

# Trap errors
trap 'die "Build failed at line $LINENO (exit code $?)"' ERR

main "$@"
