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

## Golden rule: `kernel-6.6/` stays PRISTINE

`kernel-6.6/` in this repo is a **verbatim, unmodified upstream tree (6.6.142)** — it is kept
byte-identical to `A346E:kernel-6.6`. **Never edit it directly.** Every change we need lives
in this folder as a `.patch` file and is applied at build time by
`build_kernel.sh → apply_compat_patches()`, which runs *after* the tree has been copied into
the bazel workspace (`kernel/kernel-6.6/`). So the patched files only ever exist in the build
copy; the repo copy stays clean.

Why: when you bump/replace `kernel-6.6` with a newer upstream tree, you just drop the new tree
in and rebuild — no merge conflicts, no lost fixes, nothing to remember.

New fix needed? Do it like this:
```bash
# edit the file inside the *build copy* or the repo copy, then:
git diff -- kernel-6.6/ > patch/compat-kernel-6.6/00NN-short-name.patch
git checkout -- kernel-6.6/            # <-- put the tree back to pristine
```

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
- `0011` — *(removed)* zram `default_compressor` quoting. The pristine 6.6.142 tree already has
  the correct upstream line `static const char *default_compressor = CONFIG_ZRAM_DEF_COMP;`,
  so the fix is only needed if someone hand-edits `zram_drv.c` again (the old broken line was
  `= lzo-rle;` without quotes → `error: use of undeclared identifier 'lzo'`).
- `0012` — **Samsung KDP (Knox) cred compat symbols** (`kernel-6.6/kernel/cred.c`, `kernel-6.6/include/linux/cred.h`).
  Samsung's stock kernel is built with `CONFIG_KDP_CRED=y`, so the inline helpers in their
  `<linux/cred.h>` (`get_cred()`, `get_cred_rcu()`, `put_cred()`, `get_new_cred()`) call
  `kdp_usecount_inc()` / `kdp_usecount_inc_not_zero()` / `kdp_usecount_dec_and_test()` /
  `kdp_set_cred_non_rcu()` instead of touching `cred->usage` and `cred->non_rcu` directly.
  Every **prebuilt stock module** that takes a cred reference therefore has undefined
  references to those symbols; on a plain GKI kernel they do not exist and the module is
  rejected:
  ```
  bluetooth: Unknown symbol kdp_set_cred_non_rcu (err -2)
  bluetooth: Unknown symbol kdp_usecount_inc (err -2)
  bluetooth: Unknown symbol kdp_usecount_dec_and_test (err -2)
  bt_drv_6877: Unknown symbol hci_register_dev (err -2)     <- cascade
  ```
  On a34x running the stock ROM this kills Bluetooth completely (`/system_dlkm` modules
  `bluetooth.ko`, `rfcomm.ko`, `hidp.ko`, `hci_uart.ko`, `btsdio.ko`, `btbcm.ko`, `btqca.ko`
  all fail to load; the BT HAL then gets `fd -1` and `com.android.bluetooth` dies).
  The patch does **not** implement KDP — creds stay ordinary kernel objects — it only
  exports the vanilla behaviour under those names (plus `kdp_get_usecount`,
  `is_kdp_protect_addr`, `security_integrity_current`, `kdp_enable`), guarded by
  `#ifndef CONFIG_KDP_CRED` so a real KDP tree is unaffected.

## Updating
When you bump `kernel-6.6`, test build. If it fails, fix the file, then:
```bash
git diff 8c2413e78..HEAD -- kernel-6.6/ kernel/ vendor/ > patch/compat-kernel-6.6/0013-my-new-fix.patch
git add patch/compat-kernel-6.6/0013-my-new-fix.patch
# Or regenerate the consolidated 0000:
git diff 8c2413e78..HEAD -- kernel-6.6/ kernel/ vendor/ > patch/compat-kernel-6.6/0000-all-kernel-compat.patch
```

Current set was generated from `8c2413e78..c16b631e4` — 84 files, 75KB (see `0000`), no file left.
