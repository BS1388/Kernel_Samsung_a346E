#!/bin/bash
# Kernel build for Samsung A346E (MediaTek mt6877, kernel-6.6).
#
# Options (env vars, set by .github/workflows/build_kernel.yml):
#   PERMISSIVE=true           apply Permissive/selinux-make-permissive.patch
#   CUSTOM_PATCH=true         also apply patch/*.patch
#   KSU_VERSION, KSU_GIT_TAG  KernelSU-Next version, used when no git checkout is found
#
# kernel-6.6/ stays pristine upstream. Device fixes are patches in
# kernel/patches-kernel-6.6/, applied on every build
# (manual use: kernel/patches-kernel-6.6/apply.sh [--check|--revert]).
set -Eeuo pipefail

# ---- Globals ----------------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${ROOT_DIR}/bin:${PATH}"
export TMPDIR=/tmp

PRODUCT="a34x"
DEVICE_MODULES_DIR="kernel_device_modules-6.6"
OUT_BASE="${ROOT_DIR}/out/target/product/${PRODUCT}/obj"
OUT_BASE_REL="../out/target/product/${PRODUCT}/obj"   # relative to kernel/
DEFCONFIG_OVERLAYS="mt6877_overlay.config mt6877_teegris_5_overlay.config disable_module_sig.config"
SIG_FRAGMENT="${DEVICE_MODULES_DIR}/kernel/configs/disable_module_sig.config"
IDENT='[a-zA-Z_][a-zA-Z0-9_]*'

# ---- Helpers ----------------------------------------------------------------

RED='\033[1;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; GREEN='\033[1;32m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[$(date +%H:%M:%S)] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK] $*${NC}"; }
warn() { echo -e "\n${YELLOW}[WARN] $*${NC}" >&2; }
die()  { echo -e "\n${RED}[ERROR] $*${NC}" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Kernel source dir (Kernel-6.6 or kernel-6.6)
detect_kernel_dir() {
  local d
  for d in Kernel-6.6 kernel-6.6; do
    if [ -f "${ROOT_DIR}/${d}/Makefile" ]; then
      echo "${ROOT_DIR}/${d}"
      return 0
    fi
  done
  die "Could not find kernel-6.6 or Kernel-6.6 with Makefile in ${ROOT_DIR}"
}

# Print the first existing directory among the arguments
first_dir() {
  local d
  for d in "$@"; do
    if [ -d "$d" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

# Real copy of src into dst (symlinks resolved); a symlinked dst is replaced
mirror_dir() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then rm -f "$dst"; fi
  mkdir -p "$dst"
  if have rsync && rsync -a --copy-links --delete "${src}/" "${dst}/"; then
    return 0
  fi
  cp -rL "${src}/." "${dst}/"
}

download() {
  local url="$1" out="$2"
  if have curl && curl -fsSL --retry 3 --retry-delay 5 -o "$out" "$url" && [ -s "$out" ]; then
    return 0
  fi
  if have wget && wget -q -O "$out" "$url" && [ -s "$out" ]; then
    return 0
  fi
  rm -f "$out"
  return 1
}

# add_include <file> <header>: add "#include <header>" unless already present
add_include() {
  local file="$1" header="$2"
  if grep -q "$header" "$file"; then
    return 0
  fi
  if grep -q '#include <linux/kernel.h>' "$file"; then
    sed -i "s|#include <linux/kernel.h>|&\n#include <${header}>|" "$file"
  else
    sed -i "1i #include <${header}>" "$file"
  fi
}

# each_source <dir> <command...>: run <command...> <file> for every .c/.h under dir
each_source() {
  local dir="$1" f
  shift
  while IFS= read -r -d '' f; do
    "$@" "$f"
  done < <(find "$dir" \( -name '*.c' -o -name '*.h' \) -type f -print0)
}

macro_re() {
  printf '^#define[[:space:]]*%s[[:space:]]*(%s[[:space:]]*,[[:space:]]*%s)' "$1" "$IDENT" "$IDENT"
}

# True if "#define <name>(" in file sits right under an "#ifndef <name>"
macro_guarded() {
  grep -B2 "^#define[[:space:]]*$2[[:space:]]*(" "$1" | grep "#ifndef $2" >/dev/null
}

# Drop custom MAX(a,b)/MIN(a,b) macros that clash with linux/minmax.h
strip_minmax_macros() {
  local skip_guarded=false file max_re min_re
  if [ "${1:-}" = "--skip-guarded" ]; then
    skip_guarded=true
    shift
  fi
  file="$1"
  max_re="$(macro_re MAX)"
  min_re="$(macro_re MIN)"

  grep -q -e "$max_re" -e "$min_re" "$file" || return 0
  if $skip_guarded && macro_guarded "$file" MAX && macro_guarded "$file" MIN; then
    return 0
  fi

  log "Cleaning MIN/MAX in $file"
  sed -i -e "/${max_re}/d" -e "/${min_re}/d" "$file"
  add_include "$file" linux/minmax.h
}

# ---- Host setup & sources ---------------------------------------------------

setup_system() {
  log "ROOT_DIR=${ROOT_DIR}"
  mkdir -p "${ROOT_DIR}/bin"
  ulimit -n 4096 2>/dev/null || warn "ulimit -n 4096 failed"

  # GitHub Actions installs these in the workflow
  if [ -z "${GITHUB_ACTIONS:-}" ] && have apt-get; then
    log "Installing host dependencies"
    sudo apt-get update -y || warn "apt-get update failed"
    sudo apt-get install -y curl wget unzip python3 python3-pip git rsync \
      bc bison flex build-essential libssl-dev libelf-dev libncurses-dev \
      dwarves lz4 zstd cpio libxml2-utils xsltproc || warn "apt install partially failed"
  fi

  git config --global user.email "builder@example.com" || true
  git config --global user.name "Builder" || true
  git config --global --add safe.directory "*" || true

  { df -h; nproc; free -h; } || true
}

download_repo_tool() {
  local dest="${ROOT_DIR}/bin/repo" url

  if [ -s "$dest" ] && head -n 5 "$dest" | grep -q "repo"; then
    chmod a+x "$dest"
    log "repo tool already present"
    return 0
  fi

  log "Downloading repo tool"
  for url in "https://storage.googleapis.com/git-repo-downloads/repo" \
             "https://raw.githubusercontent.com/GerritCodeReview/git-repo/main/repo"; do
    if download "$url" "$dest"; then
      chmod a+x "$dest"
      return 0
    fi
    warn "Download failed: $url"
  done

  warn "Mirrors failed, trying apt"
  sudo apt-get install -y repo || true
  if have repo; then
    cp "$(command -v repo)" "$dest" || true
    chmod a+x "$dest" || true
  fi
  [ -s "$dest" ] || die "repo tool not available at $dest"
}

sync_aosp_kernel() {
  local dir="${ROOT_DIR}/aosp-kernel"
  local manifest="https://android.googlesource.com/kernel/manifest"
  local attempt

  log "Syncing aosp-kernel (common-android15-6.6)"
  mkdir -p "$dir"
  pushd "$dir" >/dev/null

  if [ ! -d .repo ]; then
    repo init -u "$manifest" -b common-android15-6.6 --depth=1 --no-clone-bundle \
        --repo-url=https://gerrit.googlesource.com/git-repo \
      || repo init -u "$manifest" -b common-android15-6.6 --depth=1 --no-clone-bundle \
      || warn "repo init failed"
  fi

  for attempt in 1 2 3; do
    log "repo sync attempt ${attempt}/3"
    if repo sync -c -j2 --force-sync --no-clone-bundle --no-tags; then
      ok "repo sync succeeded"
      break
    fi
    [ "$attempt" -lt 3 ] || die "repo sync failed after 3 attempts"
    warn "repo sync failed, retrying"
    sleep 10
  done

  popd >/dev/null
}

link_prebuilts() {
  local src="${ROOT_DIR}/aosp-kernel/prebuilts"
  local dst="${ROOT_DIR}/kernel/prebuilts"
  local ext

  log "Linking prebuilts"
  [ -d "$src" ] || die "aosp-kernel/prebuilts not found at $src"

  rm -rf "$dst"
  ln -sfn "$src" "$dst"
  ok "Linked $dst -> $src"

  for ext in zopfli pigz; do
    src="${ROOT_DIR}/aosp-kernel/external/${ext}"
    dst="${ROOT_DIR}/kernel/external/${ext}"
    if [ -d "$src" ] && [ ! -e "$dst" ]; then
      if ln -sfn "$src" "$dst"; then
        ok "Linked $dst -> $src"
      else
        warn "Failed to link $ext"
      fi
    fi
  done
}

# ---- Source-tree patches ----------------------------------------------------

# kernel/patches-kernel-6.6/*.patch: always applied, idempotent
apply_kernel66_patches() {
  local kdir applier="${ROOT_DIR}/kernel/patches-kernel-6.6/apply.sh"
  kdir="$(detect_kernel_dir)"

  if [ ! -f "$applier" ]; then
    warn "$applier not found - kernel-6.6 stays unpatched"
    return 0
  fi

  log "Applying kernel-6.6 patches to $kdir"
  bash "$applier" "$kdir" || die "kernel-6.6 patches failed to apply to $kdir"
  ok "kernel-6.6 patches applied"
}

# PERMISSIVE / CUSTOM_PATCH build options
apply_optional_patches() {
  local kdir patch_file p patch_log=/tmp/permissive.log
  local -a extra
  kdir="$(detect_kernel_dir)"

  if [ "${PERMISSIVE:-false}" = "true" ]; then
    patch_file="${ROOT_DIR}/Permissive/selinux-make-permissive.patch"
    [ -f "$patch_file" ] || die "PERMISSIVE=true but $patch_file not found"
    log "PERMISSIVE=true -> applying $(basename "$patch_file")"
    if patch -p1 -d "$kdir" --forward --batch < "$patch_file" >"$patch_log" 2>&1; then
      ok "SELinux permissive patch applied"
    elif grep -q "Reversed (or previously applied)" "$patch_log"; then
      ok "SELinux permissive patch already applied"
    else
      cat "$patch_log" >&2
      die "PERMISSIVE=true but the permissive patch failed to apply"
    fi
  else
    log "PERMISSIVE=false -> SELinux stays enforcing"
  fi

  if [ "${CUSTOM_PATCH:-false}" = "true" ]; then
    shopt -s nullglob
    extra=("${ROOT_DIR}/patch"/*.patch)
    shopt -u nullglob
    if [ ${#extra[@]} -eq 0 ]; then
      warn "CUSTOM_PATCH=true but patch/ has no *.patch files"
    else
      log "CUSTOM_PATCH=true -> applying ${#extra[@]} patch(es)"
      for p in "${extra[@]}"; do
        patch -p1 -d "$kdir" --forward --batch < "$p" \
          || warn "$(basename "$p") failed or was already applied"
      done
    fi
  fi
}

# ---- Compat fixes: kernel-6.6 vs device modules (run from kernel/) ----------

# struct loop_device moved out of <linux/loop.h>, but zram_ext.c still needs it
restore_loop_header() {
  local header="kernel-6.6/include/linux/loop.h" d

  if [ ! -f "$header" ]; then
    log "Creating $header"
    mkdir -p "$(dirname "$header")"
    cat > "$header" <<'LOOP_EOF'
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
    ok "Created $header"
  fi

  # Keep the source trees in sync so later rsyncs carry it over
  for d in kernel-6.6 Kernel-6.6; do
    if [ -d "${ROOT_DIR}/${d}" ] && [ ! -f "${ROOT_DIR}/${d}/include/linux/loop.h" ]; then
      mkdir -p "${ROOT_DIR}/${d}/include/linux"
      cp -v "$header" "${ROOT_DIR}/${d}/include/linux/loop.h" || true
    fi
  done
}

# Old drivers define their own MAX/MIN, which now collide with minmax.h
fix_minmax_redefinitions() {
  local vendor_dir

  log "Fixing MIN/MAX redefinitions"
  if [ -d "${DEVICE_MODULES_DIR}/drivers" ]; then
    each_source "${DEVICE_MODULES_DIR}/drivers" strip_minmax_macros
  fi

  if vendor_dir="$(first_dir "${ROOT_DIR}/vendor/mediatek/kernel_modules" \
                             "vendor/mediatek/kernel_modules" \
                             "${ROOT_DIR}/vendor")"; then
    each_source "$vendor_dir" strip_minmax_macros --skip-guarded
  fi
}

patch_cred_file() {
  local file="$1"
  if grep -q "get_current_cred_module\|put_cred_module" "$file"; then
    log "Patching cred helpers in $file"
    sed -i -e 's/get_current_cred_module()/get_current_cred()/g' \
           -e 's/put_cred_module(/put_cred(/g' "$file"
    add_include "$file" linux/cred.h
  fi
}

# get_current_cred_module()/put_cred_module() no longer exist
fix_mali_cred() {
  local dir
  dir="$(first_dir "${ROOT_DIR}/vendor/mediatek/kernel_modules/gpu" \
                   "vendor/mediatek/kernel_modules/gpu" \
                   "${ROOT_DIR}/vendor")" || return 0
  each_source "$dir" patch_cred_file
}

# max_t() in an array size is a VLA under -Werror=vla
fix_stmmac_vla() {
  local file="${DEVICE_MODULES_DIR}/drivers/net/ethernet/stmicro/stmmac/stmmac_main.c"
  if [ -f "$file" ] && grep -q "status\[max_t" "$file"; then
    log "Patching $file (VLA)"
    sed -i 's/int status\[max_t(u32, MTL_MAX_TX_QUEUES, MTL_MAX_RX_QUEUES)\];/int status[MTL_MAX_TX_QUEUES > MTL_MAX_RX_QUEUES ? MTL_MAX_TX_QUEUES : MTL_MAX_RX_QUEUES];/' "$file"
  fi
}

# sec_thermistor / sec_pm_debug / sec_wakeup_cpu_allocator failed to build:
# missing SEC_PM Kconfig, sec_thermistor/ not in the Makefile, private power.h include
fix_samsung_pm() {
  local pm_dir="${DEVICE_MODULES_DIR}/drivers/samsung/pm"
  local kconfig="${pm_dir}/Kconfig"
  local makefile="${pm_dir}/Makefile"
  local wakeup="${pm_dir}/sec_wakeup_cpu_allocator.c"
  local sec_pm_block tmp

  sec_pm_block=$'config SEC_PM\n\ttristate "Samsung PM core"\n\tdefault y\n\thelp\n\t  Samsung Power Management core. Required for sec_pm_debug,\n\t  sec_wakeup_cpu_allocator and sec_thermistor.\n'

  if [ -f "$kconfig" ]; then
    if ! grep -q "^config SEC_PM$" "$kconfig"; then
      log "Adding SEC_PM to $kconfig"
      tmp="$(mktemp)"
      {
        head -n 7 "$kconfig"
        printf '%s\n' "$sec_pm_block"
        tail -n +8 "$kconfig"
      } > "$tmp"
      mv "$tmp" "$kconfig"
    fi
    if ! grep -q 'sec_thermistor/Kconfig' "$kconfig"; then
      echo 'source "$(KCONFIG_EXT_PREFIX)drivers/samsung/pm/sec_thermistor/Kconfig"' >> "$kconfig"
    fi
  fi

  if [ -f "$makefile" ] && ! grep -q "sec_thermistor" "$makefile"; then
    log "Adding sec_thermistor/ to $makefile"
    printf 'obj-$(CONFIG_SEC_PM_THERMISTOR)\t+= sec_thermistor/\n' >> "$makefile"
  fi

  if [ -f "$wakeup" ]; then
    if grep -q 'kernel/power/power.h' "$wakeup"; then
      log "Removing private power.h include from $wakeup"
      sed -i -e '/^\/\* #include ".*kernel\/power\/power.h" \*\//d' \
             -e 's|^#include ".*kernel/power/power.h"|/* compat: removed private power.h for kernel-6.6 */|' "$wakeup"
    fi
    # PM_POST_SUSPEND / register_pm_notifier came in through power.h
    if ! grep -q 'linux/suspend.h' "$wakeup"; then
      if grep -q 'uapi/linux/sched/types.h' "$wakeup"; then
        sed -i '/#include <uapi\/linux\/sched\/types.h>/a #include <linux\/suspend.h>\n#include <linux\/pm.h>' "$wakeup"
      elif grep -q 'trace/events/power.h' "$wakeup"; then
        sed -i '/#include <trace\/events\/power.h>/a #include <linux\/suspend.h>' "$wakeup"
      else
        sed -i '1i #include <linux/suspend.h>\n#include <linux/pm.h>' "$wakeup"
      fi
    fi
  fi
}

# UFS_CMD_ERR was removed upstream
fix_ufs_cmd_err() {
  local file="${DEVICE_MODULES_DIR}/drivers/ufs/vendor/ufs-sec-feature.c"

  if [ -f "$file" ] && grep -q "UFS_CMD_ERR" "$file" && ! grep -q "#define UFS_CMD_ERR" "$file"; then
    log "Patching $file (UFS_CMD_ERR)"
    if grep -q "ufs-sec-sysfs.h" "$file"; then
      sed -i '/#include "ufs-sec-sysfs.h"/a \\n/* Compat fix: UFS_CMD_ERR removed in new kernel */\n#ifndef UFS_CMD_ERR\n#define UFS_CMD_ERR UFS_TM_ERR\n#endif' "$file"
    else
      sed -i '1i /* Compat fix: UFS_CMD_ERR removed */\n#ifndef UFS_CMD_ERR\n#define UFS_CMD_ERR UFS_TM_ERR\n#endif' "$file"
    fi
  fi
}

apply_compat_fixes() {
  log "Applying compat fixes"
  restore_loop_header
  fix_minmax_redefinitions
  fix_mali_cred
  fix_stmmac_vla
  fix_samsung_pm
  fix_ufs_cmd_err
}

# ---- Workspace: kernel/ (bazel rejects symlinks pointing outside it) --------

# rsync --copy-links turns drivers/kernelsu into a plain copy, so Kbuild can no
# longer read the git version and falls back to "v0.0.1 (1)". Write the real one.
stamp_ksu_version() {
  local kbuild="${ROOT_DIR}/kernel/kernel-6.6/drivers/kernelsu/Kbuild"
  local code="" tag="" src="" d

  if [ ! -f "$kbuild" ]; then
    log "No kernelsu Kbuild in workspace - skipping KSU version stamp"
    return 0
  fi
  if ! grep -q "KSU_VERSION_FALLBACK" "$kbuild"; then
    log "kernelsu Kbuild has no KSU_VERSION_FALLBACK - skipping KSU version stamp"
    return 0
  fi

  for d in "${ROOT_DIR}/kernel-6.6/KernelSU-Next" \
           "${ROOT_DIR}/Kernel-6.6/KernelSU-Next" \
           "${ROOT_DIR}/aosp-kernel/common/KernelSU-Next"; do
    if [ -d "$d/.git" ]; then
      src="$d"
      break
    fi
  done

  if [ -n "$src" ]; then
    code=$((30000 + $(git -C "$src" rev-list --count HEAD 2>/dev/null || echo 0)))
    tag="$(git -C "$src" describe --tags --abbrev=0 2>/dev/null || echo dev)"
  elif [ -n "${KSU_VERSION:-}" ] && [ -n "${KSU_GIT_TAG:-}" ]; then
    code="$KSU_VERSION"
    tag="$KSU_GIT_TAG"
  else
    warn "Could not determine KernelSU-Next version - manager may show v0.0.1 (1)"
    return 0
  fi

  sed -i -e "s|^KSU_VERSION_FALLBACK := .*|KSU_VERSION_FALLBACK := ${code}|" \
         -e "s|^KSU_VERSION_TAG_FALLBACK := .*|KSU_VERSION_TAG_FALLBACK := ${tag}|" "$kbuild"
  ok "KernelSU-Next version stamped: ${tag} (${code})"
}

sync_kernel_tree() {
  local real_dir
  real_dir="$(detect_kernel_dir)"

  log "Syncing $real_dir -> kernel/kernel-6.6"
  mirror_dir "$real_dir" kernel-6.6

  if [ "$(basename "$real_dir")" = "Kernel-6.6" ] && [ ! -d "${ROOT_DIR}/kernel-6.6" ]; then
    log "Creating ${ROOT_DIR}/kernel-6.6 from $real_dir"
    mirror_dir "$real_dir" "${ROOT_DIR}/kernel-6.6" || warn "Could not create ${ROOT_DIR}/kernel-6.6"
  fi
}

sync_bazel_rules() {
  local src="${ROOT_DIR}/build/bazel_common_rules"

  if [ -d "$src" ]; then
    log "Syncing build/bazel_common_rules"
    mirror_dir "$src" build/bazel_common_rules
  else
    warn "Source $src not found"
  fi
}

# //Google-FDO:kernel.afdo is resolved from the workspace root
sync_fdo() {
  local src size

  if [ -d "${ROOT_DIR}/Google-FDO" ]; then
    src="${ROOT_DIR}/Google-FDO"
  elif [ -d "${ROOT_DIR}/google-FDO" ]; then
    src="${ROOT_DIR}/google-FDO"
    warn "Using old google-FDO name, prefer Google-FDO"
  else
    warn "Google-FDO not found in ${ROOT_DIR}"
    return 0
  fi

  log "Syncing $src -> kernel/Google-FDO"
  mirror_dir "$src" Google-FDO

  if [ ! -f Google-FDO/kernel.afdo ]; then
    warn "Google-FDO/kernel.afdo missing after sync"
    return 0
  fi
  size="$(stat -c%s Google-FDO/kernel.afdo 2>/dev/null || echo 0)"
  if [ "$size" -lt 1000000 ]; then
    warn "Google-FDO/kernel.afdo too small (${size} bytes), may be invalid"
  else
    ok "Google-FDO/kernel.afdo valid (${size} bytes)"
  fi
}

setup_bazel_wrapper() {
  local p

  log "Setting up WORKSPACE and bazel wrapper"
  ln -sfn "build/bazel_mgk_rules/kleaf/bazel.WORKSPACE" WORKSPACE
  ln -sfn "../build/kernel/kleaf/bazel.sh" tools/bazel
  chmod +x build/kernel/kleaf/bazel.sh tools/bazel || true

  for p in kernel-6.6 WORKSPACE tools/bazel build/bazel_common_rules; do
    [ -e "$p" ] || die "Required path $p missing after prepare_workspace"
  done
}

# Same module listed twice in modules.order must not count as a name conflict
fix_modules_check() {
  local script="kernel-6.6/scripts/modules-check.sh"

  if [ -f "$script" ] && grep -q "Check uniqueness of module names" "$script"; then
    log "Patching $script"
    cat > "$script" <<'MODCHECK_EOF'
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

set -e

if [ $# != 1 ]; then
	echo "Usage: $0 <modules.order>" >&2
	exit 1
fi

exit_code=0

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
MODCHECK_EOF
    chmod +x "$script"
  fi
}

link_mkbootimg() {
  local aosp="${ROOT_DIR}/aosp-kernel"

  if [ ! -e "${ROOT_DIR}/system/tools/mkbootimg" ] && [ -d "${aosp}/system/tools/mkbootimg" ]; then
    mkdir -p "${ROOT_DIR}/system/tools"
    ln -sfn "${aosp}/system/tools/mkbootimg" "${ROOT_DIR}/system/tools/mkbootimg"
    ok "Linked system/tools/mkbootimg"
  fi

  if [ ! -e tools/mkbootimg ]; then
    if [ -f "${aosp}/prebuilts/build-tools/path/linux-x86/mkbootimg" ]; then
      ln -sfn "${aosp}/prebuilts/build-tools/path/linux-x86/mkbootimg" tools/mkbootimg
      ok "Linked tools/mkbootimg"
    else
      warn "tools/mkbootimg missing and no prebuilt found"
    fi
  fi
}

# sign-file fails in the bazel sandbox (mtk_signing_key.pem not found), so make
# sure the key is everywhere it is looked up and turn module signing off
setup_module_signing() {
  local key="" candidate dest opt gki mtk_defconfig

  for candidate in \
    "${ROOT_DIR}/kernel/${DEVICE_MODULES_DIR}/certs/mtk_signing_key.pem" \
    "${ROOT_DIR}/kernel-6.6/certs/mtk_signing_key.pem" \
    "${ROOT_DIR}/Kernel-6.6/certs/mtk_signing_key.pem" \
    "${ROOT_DIR}/kernel/kernel-6.6/certs/mtk_signing_key.pem"; do
    if [ -f "$candidate" ]; then
      key="$candidate"
      break
    fi
  done

  if [ -n "$key" ]; then
    log "Found MTK signing key at $key"
    for dest in "${ROOT_DIR}/kernel-6.6/certs" "${ROOT_DIR}/Kernel-6.6/certs" \
                "kernel-6.6/certs" "${DEVICE_MODULES_DIR}/certs"; do
      [ -d "$(dirname "$dest")" ] || continue
      mkdir -p "$dest"
      [ "$key" -ef "${dest}/mtk_signing_key.pem" ] || cp "$key" "${dest}/"
    done
  else
    warn "MTK signing key not found, module signing may fail"
  fi

  gki="kernel-6.6/arch/arm64/configs/gki_defconfig"
  if [ -f "$gki" ]; then
    for opt in MODULE_SIG MODULE_SIG_FORCE MODULE_SIG_ALL MODULE_SIG_SHA512 MODULE_SIG_PROTECT; do
      sed -i "s/^CONFIG_${opt}[[:space:]]*=.*/# CONFIG_${opt} is not set/" "$gki"
    done
    if ! grep -q "CONFIG_MODULE_SIG" "$gki"; then
      echo "# CONFIG_MODULE_SIG is not set" >> "$gki"
    fi
  fi

  mtk_defconfig="${DEVICE_MODULES_DIR}/arch/arm64/configs/mediatek-bazel_defconfig"
  if [ -f "$mtk_defconfig" ]; then
    sed -i 's|CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"|' "$mtk_defconfig"
  fi

  mkdir -p "$(dirname "$SIG_FRAGMENT")"
  cat > "$SIG_FRAGMENT" <<'SIG_EOF'
# Disable module signing for custom kernel builds - fixes bazel sandbox sign-file failure
CONFIG_MODULE_SIG=n
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODULE_SIG_ALL is not set
# CONFIG_MODULE_SIG_SHA512 is not set
CONFIG_MODULE_SIG_HASH=""
CONFIG_MODULE_SIG_KEY=""
CONFIG_SYSTEM_TRUSTED_KEYRING=n
SIG_EOF
  ok "Module signing disabled via $SIG_FRAGMENT"
}

prepare_workspace() {
  log "Preparing kernel/ workspace"

  # Patch the source tree first so the copy below carries the patches
  apply_kernel66_patches
  apply_optional_patches

  pushd "${ROOT_DIR}/kernel" >/dev/null
  sync_kernel_tree
  stamp_ksu_version
  sync_bazel_rules
  sync_fdo
  setup_bazel_wrapper
  fix_modules_check
  link_mkbootimg
  setup_module_signing
  apply_compat_fixes
  popd >/dev/null

  ok "Workspace prepared"
}

# ---- Build ------------------------------------------------------------------

# Stop the kleaf stamp from adding "-maybe-dirty", and fix Samsung scripts that
# have an SPDX line before the shebang (run by /bin/sh -> "source: not found")
patch_stamp() {
  local stamp bs tmp

  log "Patching stamp.bzl and script shebangs"
  for stamp in "${ROOT_DIR}/kernel/build/kernel/kleaf/impl/stamp.bzl" \
               "${ROOT_DIR}/aosp-kernel/build/kernel/kleaf/impl/stamp.bzl"; do
    if [ -f "$stamp" ]; then
      sed -i -e "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo ''\"/g" \
             -e 's/-maybe-dirty//g' "$stamp"
    else
      warn "$stamp not found, skipping"
    fi
  done

  for bs in \
    "${ROOT_DIR}/kernel/${DEVICE_MODULES_DIR}/build.sh" \
    "${ROOT_DIR}/kernel/${DEVICE_MODULES_DIR}/build_abi.sh" \
    "${ROOT_DIR}/kernel-6.6/${DEVICE_MODULES_DIR}/build.sh" \
    "${ROOT_DIR}/Kernel-6.6/${DEVICE_MODULES_DIR}/build.sh" \
    "${ROOT_DIR}/kernel-6.6/build/kernel/kleaf/bazel.sh" \
    "${ROOT_DIR}/Kernel-6.6/build/kernel/kleaf/bazel.sh"; do
    if [ -f "$bs" ] && head -n1 "$bs" | grep -q "SPDX"; then
      log "Fixing shebang order in $bs"
      tmp="$(mktemp)"
      {
        echo "#!/bin/bash"
        grep -v "^#!/bin/bash" "$bs" || true
      } > "$tmp"
      mv "$tmp" "$bs"
      chmod +x "$bs"
    fi
  done
}

generate_build_config() {
  local gen_script="${DEVICE_MODULES_DIR}/scripts/gen_build_config.py"

  log "Generating build.config"
  mkdir -p "${OUT_BASE}/KERNEL_OBJ" "${OUT_BASE}/KLEAF_OBJ"

  # gen_build_config.py derives kernel_dir from the cwd, so it must run from kernel/
  pushd "${ROOT_DIR}/kernel" >/dev/null
  [ -f "$gen_script" ] || die "gen_build_config.py not found at $gen_script (pwd=$(pwd))"

  python3 "$gen_script" \
    --kernel-defconfig mediatek-bazel_defconfig \
    --kernel-defconfig-overlays "$DEFCONFIG_OVERLAYS" \
    --kernel-build-config-overlays "" \
    -m user \
    -o "${OUT_BASE_REL}/KERNEL_OBJ/build.config"
  popd >/dev/null

  ok "Generated ${OUT_BASE}/KERNEL_OBJ/build.config"
  cat "${OUT_BASE}/KERNEL_OBJ/build.config"
}

run_kernel_build() {
  local build_sh="./${DEVICE_MODULES_DIR}/build.sh"

  # bazel wrapper must be run from kernel/
  pushd "${ROOT_DIR}/kernel" >/dev/null

  SOURCE_DATE_EPOCH="$(date +%s)"
  export DEVICE_MODULES_DIR DEFCONFIG_OVERLAYS SOURCE_DATE_EPOCH
  export BUILD_CONFIG="${OUT_BASE_REL}/KERNEL_OBJ/build.config"
  export OUT_DIR="${OUT_BASE_REL}/KLEAF_OBJ"
  export DIST_DIR="${OUT_BASE_REL}/KLEAF_OBJ/dist"
  export PROJECT="mgk_64_k66"
  export MODE="user"
  export KERNEL_VERSION="kernel-6.6"
  export KBUILD_BUILD_USER="builder"
  export KBUILD_BUILD_HOST="github"
  export BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
  export SANDBOX=0
  export BUILD_CONFIG_FRAGMENTS=""

  [ -f "$build_sh" ] || die "build.sh not found at $build_sh"
  { [ -e tools/bazel ] && [ -e build/kernel/kleaf/bazel.sh ]; } || die "bazel wrapper missing"

  { df -h; free -h; } || true

  # Always run through bash: Samsung's build.sh has SPDX before the shebang
  log "Starting kernel build (~50 min)"
  if have stdbuf; then
    stdbuf -oL -eL bash "$build_sh"
  else
    bash "$build_sh"
  fi

  popd >/dev/null
  ok "Kernel build finished"
}

collect_image() {
  local primary="${OUT_BASE}/KLEAF_OBJ/dist/${DEVICE_MODULES_DIR}/mgk_64_k66_kernel_aarch64.user/Image"
  local dest="${ROOT_DIR}/Image" src

  log "Collecting Image"
  if [ -f "$primary" ]; then
    src="$primary"
  else
    warn "Image not found at $primary, searching out/"
    src="$(find "${ROOT_DIR}/out" -name Image -type f -print -quit 2>/dev/null || true)"
    [ -n "$src" ] || die "Image not found! Build failed."
  fi

  cp -v "$src" "$dest"
  ls -lh "$dest"
  sha256sum "$dest"
  ok "تمام! فایل Image در $dest آماده است."
}

# ---- Main -------------------------------------------------------------------

main() {
  log "=== A346E Kernel Build Started ($(date)) ==="

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

trap 'die "Build failed at line $LINENO (exit code $?)"' ERR

main "$@"
