#!/bin/bash
# ==============================================================================
# Build script for Samsung A346E kernel (MediaTek mt6877, kernel-6.6)
# Refactored & hardened -- handles bazel sandbox, casing, FDO, and compat fixes
#
# Sections:
#   0. Globals & helpers
#   1. setup_system           -- host deps & git config
#   2. download_repo_tool     -- fetch `repo`
#   3. sync_aosp_kernel       -- sync common-android15-6.6
#   4. link_prebuilts         -- prebuilts & external tools
#   5. prepare_workspace      -- fix bazel sandbox (rsync, FDO, sig)
#      5a-0. apply_optional_patches -- PERMISSIVE / CUSTOM_PATCH build options
#      5a.   apply_compat_patches   -- auto-apply patch/compat-kernel-6.6/*.patch
#      5b.   apply_compat_fixes     -- inline sed/header fixes (loop.h, MAX/MIN...)
#      5c.   stamp_ksu_version      -- embed real KernelSU-Next version (not v0.0.1)
#   6. patch_stamp            -- stamp.bzl & shebang fixes
#   7. generate_build_config  -- gen_build_config.py
#   8. run_kernel_build       -- bazel build
#   9. collect_image          -- gather Image
#
# Build options (env vars, set by .github/workflows/build_kernel.yml):
#   PERMISSIVE=true|false     apply Permissive/selinux-make-permissive.patch
#   CUSTOM_PATCH=true|false   also apply patch/*.patch (top level)
#   KSU_VAR                   informational only; the workflow installs KSU
#
# kernel-6.6/ is kept PRISTINE in git: never edit it, add a patch to
# patch/compat-kernel-6.6/ instead (see that folder's README.md).
#
# Compat patches:
#   Patches in patch/compat-kernel-6.6/ are auto-applied via
#   apply_compat_patches() before the inline fixes, so a fresh kernel-6.6
#   checkout can be fixed by just enabling the patch dir. Use:
#     patch -p1 --forward < patch/compat-kernel-6.6/*.patch
#   See patch/README.md and patch/compat-kernel-6.6/README.md.
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
    # NOTE: `[ x ] && die` as the last statement of the loop body would make
    # the body return 1 on attempts 1 and 2 -> `set -e` + ERR trap would abort
    # the whole build instead of retrying. Use a real if.
    if [ "$attempt" -eq 3 ]; then
      die "repo sync failed after 3 attempts"
    fi
    sleep 10
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
# 5a-0. Optional patches driven by the build options (CI inputs / env vars):
#         PERMISSIVE=true    -> Permissive/selinux-make-permissive.patch
#         CUSTOM_PATCH=true  -> patch/*.patch (top level only)
#       patch/compat-kernel-6.6/*.patch is ALWAYS applied, see 5a below.
#
#       These are applied to the SOURCE tree (kernel-6.6/) before it is copied
#       into the bazel workspace. Previously the workflow did this in a separate
#       job, on a runner that was thrown away afterwards, so `permissive: true`
#       silently produced an ENFORCING kernel. Doing it here means the flag
#       works the same in CI and in a local build.
# ------------------------------------------------------------------------------
apply_optional_patches() {
  local kdir
  kdir="$(detect_kernel_dir)"

  if [ "${PERMISSIVE:-false}" = "true" ]; then
    local pp="${ROOT_DIR}/Permissive/selinux-make-permissive.patch"
    [ -f "$pp" ] || die "PERMISSIVE=true but $pp not found"
    log "PERMISSIVE=true -> applying $(basename "$pp") to $kdir"
    if patch -p1 -d "$kdir" --forward --batch < "$pp" >/tmp/permissive.log 2>&1; then
      ok "SELinux permissive patch applied"
    elif grep -q "Reversed (or previously applied)" /tmp/permissive.log; then
      ok "SELinux permissive patch already applied"
    else
      cat /tmp/permissive.log >&2
      die "PERMISSIVE=true but the permissive patch failed to apply"
    fi
    grep -n "selinux_enforcing_boot" "${kdir}/security/selinux/hooks.c" | head -n 3 || true
  else
    log "PERMISSIVE=false -> SELinux stays enforcing"
  fi

  if [ "${CUSTOM_PATCH:-false}" = "true" ]; then
    shopt -s nullglob
    local extra=("${ROOT_DIR}/patch"/*.patch)
    shopt -u nullglob
    if [ ${#extra[@]} -eq 0 ]; then
      warn "CUSTOM_PATCH=true but patch/ has no *.patch files (patch/compat-kernel-6.6/ is applied anyway)"
    else
      log "CUSTOM_PATCH=true -> applying ${#extra[@]} extra patch(es) to $kdir"
      local p
      for p in "${extra[@]}"; do
        log "Applying $(basename "$p")"
        patch -p1 -d "$kdir" --forward --batch < "$p" || warn "$(basename "$p") failed or was already applied"
      done
    fi
  fi
}

# ------------------------------------------------------------------------------
# 5a. Auto-apply compat patches from patch/compat-kernel-6.6/
#      These are the persistent patches for kernel-6.6 update breakage.
#      They are also committed directly to the tree, but applying them here
#      lets a fresh kernel-6.6 checkout be fixed automatically.
# ------------------------------------------------------------------------------
apply_compat_patches() {
  log "Applying compat patches from patch/compat-kernel-6.6/ (if any)"

  local compat_dirs=(
    "${ROOT_DIR}/patch/compat-kernel-6.6"
    "patch/compat-kernel-6.6"
    "../patch/compat-kernel-6.6"
  )
  local compat_dir=""
  for d in "${compat_dirs[@]}"; do
    if [ -d "$d" ]; then
      compat_dir="$d"
      break
    fi
  done

  if [ -z "$compat_dir" ] || [ ! -d "$compat_dir" ]; then
    log "No compat patch dir found, skipping auto-apply"
    return 0
  fi

  log "Using compat patch dir: $compat_dir"
  shopt -s nullglob
  local patches=("$compat_dir"/*.patch)
  # Exclude the consolidated 0000-all* to avoid double-apply when split patches exist
  # (if only 0000 exists it will still be applied)
  local filtered=()
  for p in "${patches[@]}"; do
    local base
    base="$(basename "$p")"
    if [[ "$base" == 0000-* ]] && [ ${#patches[@]} -gt 1 ]; then
      log "Skipping consolidated $base (split patches present)"
      continue
    fi
    filtered+=("$p")
  done
  shopt -u nullglob

  if [ ${#filtered[@]} -eq 0 ]; then
    log "No compat patches to apply"
    return 0
  fi

  log "Found ${#filtered[@]} compat patches:"
  printf "  - %s\n" "${filtered[@]}"

  for p in "${filtered[@]}"; do
    log "Applying $(basename "$p")"
    if patch -p1 --forward --batch < "$p" 2>&1 | tee /tmp/compat_patch.log; then
      ok "Applied $(basename "$p")"
    else
      # patch --forward returns non-zero if already applied or fails
      if grep -q "Skipping patch\|already applied\|Reversed (or previously applied) patch detected" /tmp/compat_patch.log 2>/dev/null; then
        log "Skipped $(basename "$p") (already applied)"
      else
        warn "Compat patch $(basename "$p") may have failed - see log"
        cat /tmp/compat_patch.log || true
        # Don't fail build for compat patches - inline fixes below will handle it
      fi
    fi
  done
  ok "Compat patches done"
}

# ------------------------------------------------------------------------------
# 5b. Compatibility fixes (kernel-6.6 update vs device modules)
# ------------------------------------------------------------------------------
apply_compat_fixes() {
  log "Applying compatibility fixes for kernel-6.6 vs device_modules-6.6"

  # First try auto-applying patch files (idempotent)
  apply_compat_patches

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

  # --- Fix 2d: vendor/mediatek MAX/MIN redefinition (stp_uart.c, btmtk_define.h, etc.) ---
  # Error: vendor/mediatek/kernel_modules/connectivity/common/common_main/linux/stp_uart.c:47:9 error: 'MAX' macro redefined
  # And btmtk_define.h MAX/MIN redefined
  # New kernel's include/linux/minmax.h defines MIN/MAX, vendor drivers define their own
  # Solution: remove bare custom MIN/MAX and include minmax.h (or guard). Use broad scan over vendor.
  log "Broad MIN/MAX cleanup in vendor/mediatek"
  local vendor_dirs=(
    "${ROOT_DIR}/vendor/mediatek/kernel_modules"
    "../vendor/mediatek/kernel_modules"
    "vendor/mediatek/kernel_modules"
    "${ROOT_DIR}/vendor"
    "../vendor"
  )
  for vd in "${vendor_dirs[@]}"; do
    if [ -d "$vd" ]; then
      log "Scanning $vd for MIN/MAX redefinition"
      find "$vd" \( -name "*.c" -o -name "*.h" \) -type f | while read -r f; do
        if grep -q "^#define[[:space:]]*MAX[[:space:]]*(" "$f" 2>/dev/null || \
           grep -q "^#define[[:space:]]*MIN[[:space:]]*(" "$f" 2>/dev/null; then
          if grep -q "^#define[[:space:]]*MAX[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)" "$f" || \
             grep -q "^#define[[:space:]]*MIN[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)" "$f"; then
            # Skip files already guarded with #ifndef MAX/MIN (our committed fix)
            if grep -B2 "^#define[[:space:]]*MAX[[:space:]]*(" "$f" | grep -q "#ifndef MAX" 2>/dev/null; then
              # Check if both MAX and MIN are guarded; if so skip
              if grep -B2 "^#define[[:space:]]*MIN[[:space:]]*(" "$f" | grep -q "#ifndef MIN" 2>/dev/null; then
                continue
              fi
            fi
            log "Cleaning $f"
            sed -i '/^#define[[:space:]]*MAX[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
            sed -i '/^#define[[:space:]]*MIN[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*)/d' "$f" || true
            # Clean up orphaned guards left after deleting inner defines (e.g., #ifndef MAX / #endif empty blocks)
            # Remove empty #ifndef MAX ... #endif blocks with no content
            # This is a best-effort cleanup; leave if not empty
            if ! grep -q "linux/minmax.h" "$f"; then
              if grep -q "#include <linux/kernel.h>" "$f"; then
                sed -i 's|#include <linux/kernel.h>|#include <linux/kernel.h>\n#include <linux/minmax.h>|' "$f" || true
              else
                sed -i '1i #include <linux/minmax.h>' "$f" || true
              fi
            fi
          fi
        fi
      done
      # Only scan first found vendor dir to avoid duplicate work
      break
    fi
  done

  # --- Fix 2e: gpu mali cred module functions removed in kernel 6.6 ---
  # Error: mali_kbase_js.c:158:28: error: call to undeclared function 'get_current_cred_module'
  # And put_cred_module. New kernel 6.6 uses get_current_cred()/put_cred() with <linux/cred.h>
  log "Fixing gpu mali cred module functions"
  for vd in "${ROOT_DIR}/vendor/mediatek/kernel_modules/gpu" "../vendor/mediatek/kernel_modules/gpu" "vendor/mediatek/kernel_modules/gpu" "${ROOT_DIR}/vendor" "../vendor"; do
    if [ -d "$vd" ]; then
      find "$vd" \( -name "*.c" -o -name "*.h" \) -type f | while read -r f; do
        if grep -q "get_current_cred_module\|put_cred_module" "$f" 2>/dev/null; then
          log "Patching $f for cred module compat"
          sed -i 's/get_current_cred_module()/get_current_cred()/g' "$f" || true
          sed -i 's/put_cred_module(/put_cred(/g' "$f" || true
          if ! grep -q "linux/cred.h" "$f"; then
            if grep -q "#include" "$f"; then
              sed -i '0,/#include.*/s//#include <linux\/cred.h>\n&/' "$f" 2>/dev/null || sed -i '1i #include <linux/cred.h>' "$f" || true
            else
              sed -i '1i #include <linux/cred.h>' "$f" || true
            fi
          fi
        fi
      done
      break
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
# 5c. KernelSU-Next version stamp (fix manager showing "v0.0.1" / version "1")
#     prepare_workspace()'s rsync --copy-links dereferences the
#     drivers/kernelsu -> ../KernelSU-Next/kernel symlink into a plain copy
#     inside the outer repo, so at compile time KernelSU-Next/kernel/Kbuild
#     cannot detect its own git repo and falls back to:
#       KSU_VERSION_FALLBACK     := 1       (manager shows version "1")
#       KSU_VERSION_TAG_FALLBACK := v0.0.1 (manager shows tag "v0.0.1")
#     Fix: write the real values (30000 + commit count, latest tag) into the
#     fallback lines of the Kbuild copy that actually gets compiled.
# ------------------------------------------------------------------------------
stamp_ksu_version() {
  local ws_kbuild="kernel/kernel-6.6/drivers/kernelsu/Kbuild"
  if [ ! -f "$ws_kbuild" ]; then
    log "No kernelsu Kbuild in workspace (NO-ROOT build?) - skipping KSU version stamp"
    return 0
  fi
  if ! grep -q "KSU_VERSION_FALLBACK" "$ws_kbuild"; then
    log "kernelsu Kbuild has no KSU_VERSION_FALLBACK (older KSU layout) - skipping stamp"
    return 0
  fi

  local code="" tag="" src_ksu="" d count
  for d in "${ROOT_DIR}/kernel-6.6/KernelSU-Next" \
           "${ROOT_DIR}/Kernel-6.6/KernelSU-Next" \
           "${ROOT_DIR}/aosp-kernel/common/KernelSU-Next"; do
    if [ -d "$d/.git" ]; then
      src_ksu="$d"
      break
    fi
  done

  if [ -n "$src_ksu" ]; then
    log "Reading KernelSU-Next version from $src_ksu"
    count=$(git -C "$src_ksu" rev-list --count HEAD 2>/dev/null || echo 0)
    code=$((30000 + count))
    tag=$(git -C "$src_ksu" describe --tags --abbrev=0 2>/dev/null || echo "dev")
  elif [ -n "${KSU_VERSION:-}" ] && [ -n "${KSU_GIT_TAG:-}" ]; then
    log "Using KSU version from environment: ${KSU_GIT_TAG} (${KSU_VERSION})"
    code="${KSU_VERSION}"
    tag="${KSU_GIT_TAG}"
  fi

  if [ -z "$code" ] || [ -z "$tag" ]; then
    warn "Could not determine KernelSU-Next version (no git repo / env) - manager may show v0.0.1 (1)"
    return 0
  fi

  local cur_code cur_tag
  cur_code=$(grep -E '^KSU_VERSION_FALLBACK :=' "$ws_kbuild" | awk '{print $3}' || true)
  cur_tag=$(grep -E '^KSU_VERSION_TAG_FALLBACK :=' "$ws_kbuild" | awk '{print $3}' || true)

  if [ "$code" = "$cur_code" ] && [ "$tag" = "$cur_tag" ]; then
    ok "KSU version already stamped in workspace: ${tag} (${code})"
    return 0
  fi

  log "Stamping KernelSU-Next version ${tag} (${code}) into $ws_kbuild (was: ${cur_tag:-?} (${cur_code:-?}))"
  if [ -n "$code" ]; then
    sed -i "s|^KSU_VERSION_FALLBACK := .*|KSU_VERSION_FALLBACK := ${code}|" "$ws_kbuild"
  fi
  if [ -n "$tag" ]; then
    sed -i "s|^KSU_VERSION_TAG_FALLBACK := .*|KSU_VERSION_TAG_FALLBACK := ${tag}|" "$ws_kbuild"
  fi
  grep -n "KSU_VERSION_FALLBACK\|KSU_VERSION_TAG_FALLBACK" "$ws_kbuild" || true
  ok "KernelSU-Next version stamped: ${tag} (${code})"
}

# ------------------------------------------------------------------------------
# 5. Prepare kernel/ workspace (fix bazel sandbox symlink issues)
# ------------------------------------------------------------------------------
prepare_workspace() {
  log "Preparing kernel/ workspace (fix bazel sandbox)"

  # Build-option patches (permissive / extra) go on the SOURCE tree first,
  # so the copy below carries them into the bazel workspace.
  apply_optional_patches

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

  # --- KernelSU-Next: stamp real version into the compiled Kbuild (fix v0.0.1 (1)) ---
  stamp_ksu_version

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

  # --- Fix modules-check.sh for duplicate same-path handling (sec_thermistor) ---
  if [ -f "kernel-6.6/scripts/modules-check.sh" ]; then
    if grep -q "Check uniqueness of module names" "kernel-6.6/scripts/modules-check.sh"; then
      log "Patching kernel-6.6/scripts/modules-check.sh for duplicate handling"
      cat > "kernel-6.6/scripts/modules-check.sh" <<'MCEOF'
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

set -e

if [ $# != 1 ]; then
	echo "Usage: $0 <modules.order>" >&2
	exit 1
fi

exit_code=0

# Deduplicate modules.order to handle Kbuild bug where same entry appears twice
if [ -f "$1" ]; then
	tmp_sorted=$(mktemp)
	sort -u "$1" -o "$tmp_sorted" 2>/dev/null || cp "$1" "$tmp_sorted"
	mv "$tmp_sorted" "$1" 2>/dev/null || true
fi

# Check uniqueness of module names (only error if different paths share same basename)
check_same_name_modules()
{
	for m in $(sed 's:.*/::' "$1" | sort | uniq -d)
	do
		paths=$(sed -n "/\/$m/s:^\(.*\)\.o$:\1:p" "$1" | sort -u)
		num_paths=$(echo "$paths" | wc -l)
		if [ "$num_paths" -gt 1 ]; then
			echo "error: the following would cause module name conflict:" >&2
			sed -n "/\/$m/s:^\(.*\)\.o$:  \1.ko:p" "$1" >&2
			exit_code=1
		else
			echo "warning: duplicate $m with same path, deduplicated" >&2
		fi
	done
}

check_same_name_modules "$1"

exit $exit_code
MCEOF
      chmod +x "kernel-6.6/scripts/modules-check.sh"
      ok "Patched modules-check.sh in workspace"
    fi
  fi

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
