# Patch Directory

This directory contains patches for the Samsung A346E kernel build.

## Structure

- `compat-kernel-6.6/` — **Auto-applied** compatibility patches for kernel-6.6 vs device modules / vendor.
  These fix build errors when using a newer kernel (6.6) with older device modules:
  - `0001-modules-check-dedup-sec_thermistor.patch` — Fixes duplicate `sec_thermistor.ko` same-path conflict in `modules.order`
  - `0002-loop_h-restore-for-zram.patch` — Restores `include/linux/loop.h` removed in 6.6 but needed by `zram_ext.c`
  - `0003-stp_uart-MAX-MIN-guard.patch` — Guards `MAX`/`MIN` redefinition in `stp_uart.c`
  - `0004-btmtk_define-MAX-MIN-guard-linux_v2.patch` — Guards `MAX`/`MIN` in `btmtk_define.h` (linux_v2)
  - `0005-btmtk_define-MAX-MIN-guard-mt66xx.patch` — Guards `MAX`/`MIN` in `btmtk_define.h` (mt66xx)
  - `0006-mali_malisw-MAX-MIN-guard.patch` — Guards `MAX`/`MIN` in `mali_malisw.h`
  - `0007-mtk-mae-MAX-MIN-guard.patch` — Guards `MAX`/`MIN` in `mtk-mae-isp8.c`
  - `0008-mali_kbase_js-cred-fix.patch` — Fixes `get_current_cred_module` → `get_current_cred` in Mali driver
  - `0009-mali_csf_scheduler-cred-fix.patch` — Same cred fix for CSF scheduler
  - `0000-all-kernel-compat.patch` — Consolidated patch with all above (alternative)

  **These are applied automatically** by `build_kernel.sh:apply_compat_patches()` on every build,
  even without `custom_patches=true`. When you update `kernel-6.6` to a newer version,
  just re-apply this folder: `git apply patch/compat-kernel-6.6/*.patch` or enable the auto-apply.

- `*.patch` (root of `patch/`) — **Custom patches** applied only when `custom_patches=true` is enabled
  in the GitHub Actions workflow. Place your own `.patch` files here.

## Usage

### Automatic (compat patches)
No action needed. `build_kernel.sh` will automatically apply `patch/compat-kernel-6.6/*.patch`
during `apply_compat_fixes` before building. If a patch is already applied, it is skipped (`--forward`).

### Manual / Custom
1. Place your `.patch` files in `patch/` (e.g., `patch/my-feature.patch`)
2. In GitHub Actions, set `custom_patches: true` when dispatching the workflow
3. Or locally: `bash build_kernel.sh` will ask or you can set `CUSTOM_PATCH=true`

### When updating kernel-6.6
1. Replace `kernel-6.6/` with the new version
2. Run: `for p in patch/compat-kernel-6.6/*.patch; do patch -p1 --forward < "$p" || echo "Skip $p"; done`
3. If a patch fails, update it and commit the new version.

## Generating new compat patches
After fixing a new build error, generate a patch:
```bash
git diff 8c2413e78..HEAD -- kernel-6.6/ vendor/ > patch/compat-kernel-6.6/0010-my-fix.patch
```
