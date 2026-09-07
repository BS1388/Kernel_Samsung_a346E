# Kernel 6.6 Compatibility Fixes

**This folder is intentionally empty of `.patch` files.**
All 84+ compatibility fixes are now **baked directly into the source tree**
(`kernel-6.6/`, `kernel/kernel_device_modules-6.6/`, `vendor/`), so every build
has them, always, with nothing to apply and nothing that can fail to apply.

`build_kernel.sh → apply_compat_patches()` still scans this folder on every
build: if you ever drop a `.patch` file here it is applied automatically
(`patch -p1 --forward`), so the mechanism is intact for future one-off fixes.

---

## What is fixed in the tree (and how to check it)

Samsung's device/vendor modules were written for an older kernel; these are the
changes that make them build against 6.6 (`common-android15-6.6`, 6.6.142):

| # | area | files | fix |
|---|---|---|---|
| 1 | `modules.order` duplicates | `kernel-6.6/scripts/modules-check.sh` | dedup with `sort -u`; only a *different path* with the same basename is an error (`sec_thermistor`) |
| 2 | `struct loop_device` moved out of the header in 6.6 | `kernel-6.6/include/linux/loop.h` | header restored, `zram_ext.c` needs `lo->lo_backing_file` |
| 3 | `MAX`/`MIN` now live in `linux/minmax.h` and collide with driver-local defines | `stp_uart.c`, `btmtk_define.h` (x2), `mali_malisw.h` (x2), `mtk-mae-isp8.c`, `zsmalloc.c`, 30+ thermal `tscpu_settings.h`, `rpmb-mtk.c`, `cpufreq_limit.c`, ged/gpufreq/drm/mdpm/blocktag … | `#include <linux/minmax.h>` + `#ifndef MAX` / `#ifndef MIN` guards |
| 4 | Samsung-only cred API | mali `mali_kbase_js.c`, `mali_csf_scheduler.c` | `get_current_cred_module()`/`put_cred_module()` → vanilla `get_current_cred()`/`put_cred()` |
| 5 | VLA build error | `stmmac_main.c` | `max_t()` statement-expression → constant |
| 6 | `UFS_CMD_ERR` removed in 6.6 | `ufs-sec-feature.c` | fall back to `UFS_TM_ERR` |
| 7 | Samsung PM | `drivers/samsung/pm/{Kconfig,Makefile}`, `sec_wakeup_cpu_allocator.c` | add `config SEC_PM`, add `sec_thermistor/` to the Makefile, drop the private `kernel/power/power.h` include |
| 8 | module signing in the bazel sandbox | `kernel/configs/disable_module_sig.config` | signing disabled for custom builds |
| 9 | **Samsung KDP (Knox) cred symbols** | `kernel-6.6/kernel/cred.c`, `kernel-6.6/include/linux/cred.h` | see below |

### #9 in detail — the one that killed Bluetooth

Samsung's stock kernel is built with `CONFIG_KDP_CRED=y`, so the inline helpers
in their `<linux/cred.h>` (`get_cred()`, `get_cred_rcu()`, `put_cred()`,
`get_new_cred()`) call `kdp_usecount_inc()` / `kdp_usecount_inc_not_zero()` /
`kdp_usecount_dec_and_test()` / `kdp_set_cred_non_rcu()` instead of touching
`cred->usage` and `cred->non_rcu` directly. Every **prebuilt stock module**
that takes a cred reference therefore has undefined references to those
symbols; on a plain GKI kernel they do not exist:

```
bluetooth: Unknown symbol kdp_set_cred_non_rcu (err -2)
bluetooth: Unknown symbol kdp_usecount_inc (err -2)
bt_drv_6877: Unknown symbol hci_register_dev (err -2)     <- cascade
```

On a34x with the stock ROM this killed Bluetooth completely (`/system_dlkm`
`bluetooth.ko`, `rfcomm.ko`, `hidp.ko`, `hci_uart.ko`, `btsdio.ko`, `btbcm.ko`,
`btqca.ko` all failed to load, no `/dev/stpbt`, `com.android.bluetooth` died).

The fix does **not** implement KDP — creds stay ordinary kernel objects — it
only exports the vanilla behaviour under those names (plus `kdp_get_usecount`,
`is_kdp_protect_addr`, `security_integrity_current`, `kdp_enable`), guarded by
`#ifndef CONFIG_KDP_CRED` so a real KDP tree is unaffected.

CI (`#4 Patches`) greps for all of the above on every run, so a fix can never
silently disappear from the tree.

---

## Updating `kernel-6.6` to a newer upstream tree

The fixes are in the tree, so a straight replacement of `kernel-6.6/` would
drop them. Do it like this:

```bash
# 1. save what we changed against the last pristine base (A346E branch @ 8c2413e78)
git diff 8c2413e78 -- kernel-6.6/ > /tmp/a346e-kernel-fixes.patch

# 2. drop in the new tree, then re-apply
patch -p1 --forward < /tmp/a346e-kernel-fixes.patch
#    ... fix whatever rejects, then rebuild

# 3. optional: keep the patch here so the next update is easier
cp /tmp/a346e-kernel-fixes.patch patch/compat-kernel-6.6/0001-kernel-6.6-fixes.patch
```

Older revisions of the split patches (`0000`…`0012`) are still in git history if
you need them:

```bash
git log --oneline -- patch/compat-kernel-6.6/
git show <commit>:patch/compat-kernel-6.6/0012-add-samsung-kdp-cred-compat-symbols.patch
```

## Other patch folders

* `Permissive/selinux-make-permissive.patch` — applied only when the workflow
  input `permissive: true` is set (`build_kernel.sh → apply_optional_patches`).
* `patch/*.patch` (top level) — applied only when `custom_patches: true`.
