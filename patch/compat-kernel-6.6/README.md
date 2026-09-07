# Kernel 6.6 Compatibility Patches

These patches fix build errors when building Samsung A346E (MediaTek mt6877) device modules
against a newer kernel-6.6 (common-android15-6.6).

## Why?

Samsung's device modules were written for an older kernel and use APIs that changed in 6.6:
- `MAX`/`MIN` macros moved to `linux/minmax.h` and now collide with driver-local defines
- `struct loop_device` moved out of `linux/loop.h`
- `get_current_cred_module` renamed to `get_current_cred`
- `modules.order` now contains duplicate same-path entries for `sec_thermistor`

Instead of editing files manually each time you update `kernel-6.6`, these patches can be
re-applied automatically.

## Auto-apply

`build_kernel.sh` → `apply_compat_patches()` runs on every build:
```bash
for p in patch/compat-kernel-6.6/*.patch; do
  patch -p1 --forward --batch < "$p" || true
done
```
If already applied, `--forward` skips it.

## Manual apply
```bash
git apply patch/compat-kernel-6.6/*.patch
# or
for p in patch/compat-kernel-6.6/*.patch; do patch -p1 < "$p"; done
```

## List (84 files total, no file missed — `0000` = all)
- `0001` — `modules-check.sh` dedup (`kernel-6.6/scripts/modules-check.sh`)
- `0002` — `loop.h` restore (`kernel-6.6/include/linux/loop.h`)
- `0003-0007` — `MAX`/`MIN` guards vendor (stp_uart, btmtk x2, mali_malisw vendor, mtk-mae)
- `0008-0009` — `cred` fixes vendor Mali (`mali_kbase_js.c`, `mali_csf_scheduler.c`)
- `0010` — remaining 75 files: all `kernel/kernel_device_modules-6.6` MAX/MIN batch (zsmalloc, stmmac VLA, rpmb, cpufreq, ged_dvfs, gpufreq, drm, 30+ thermal tscpu/tspmic, mdpm, blocktag, etc.) + Samsung PM (`Kconfig` SEC_PM, `Makefile`, `sec_wakeup_cpu_allocator.c` power.h), UFS (`ufs-sec-feature.c`), wlan `sha256/sha512-internal.c` (gen4m/s1), `disable_module_sig.config`, and `kernel/.../mali_malisw.h` kernel copy
- `0000` — consolidated single-file version of all 84 files (auto-skipped when splits exist — see `build_kernel.sh:apply_compat_patches`)

## Updating
When you bump `kernel-6.6`, test build. If it fails, fix the file, then:
```bash
git diff 8c2413e78..HEAD -- kernel-6.6/ kernel/ vendor/ > patch/compat-kernel-6.6/0011-my-new-fix.patch
git add patch/compat-kernel-6.6/0011-my-new-fix.patch
# Or regenerate the consolidated 0000:
git diff 8c2413e78..HEAD -- kernel-6.6/ kernel/ vendor/ > patch/compat-kernel-6.6/0000-all-kernel-compat.patch
```

Current set was generated from `8c2413e78..c16b631e4` — 84 files, 75KB (see `0000`), no file left.
