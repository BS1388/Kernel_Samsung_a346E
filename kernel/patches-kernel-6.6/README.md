# `kernel-6.6` compatibility patches

Everything this device needs **on top of a plain upstream `common-android15-6.6`
tree** lives here. `kernel-6.6/` itself stays **pristine**, so updating the
kernel never means re-doing this work.

```
kernel/patches-kernel-6.6/
├── apply.sh                                    <- applies / checks / reverts
├── 0001-modules-check-dedup-sec_thermistor.patch
├── 0002-restore-loop_h-for-zram_ext.patch
├── 0003-samsung-kdp-cred-compat-symbols.patch  <- the Bluetooth fix
└── 0004-thermal-soc-throttle-bypass.patch      <- opt-in SoC no-throttle
```

## Updating `kernel-6.6` (the whole point of this folder)

```bash
rm -rf kernel-6.6
#  ... put the new upstream kernel-6.6 in its place ...
kernel/patches-kernel-6.6/apply.sh
```

That is it. In CI you do not even do that: `build_kernel.sh` calls `apply.sh`
on every build (`prepare_workspace → apply_kernel66_patches`), and the CI job
**#4 Patches** dry-runs it first, so a patch that no longer fits the new tree
fails the run in one minute instead of 50 minutes into the compile.

```bash
kernel/patches-kernel-6.6/apply.sh --check     # dry-run, changes nothing
kernel/patches-kernel-6.6/apply.sh --revert    # back to the pristine tree
kernel/patches-kernel-6.6/apply.sh /path/to/other-kernel-6.6
```

The patches are `-p1` **relative to the kernel tree root** (`scripts/…`,
`kernel/…`, `include/…`), not to the repo root, so they work no matter what the
folder is called.

## What each patch does

### `0001-modules-check-dedup-sec_thermistor.patch`
`scripts/modules-check.sh`

Kbuild lists `sec_thermistor.ko` twice with the *same path* in `modules.order`,
and 6.6's checker treats any duplicate basename as a fatal name conflict:

```
error: the following would cause module name conflict:
  drivers/samsung/pm/sec_thermistor/sec_thermistor.ko
```

The patch dedups `modules.order` (`sort -u`) and only errors when two
*different* paths share a basename — the case the check actually exists for.

### `0002-restore-loop_h-for-zram_ext.patch`
`include/linux/loop.h` (file re-added)

6.6 moved `struct loop_device` into the private `drivers/block/loop.c`, but
Samsung's `zram_ext.c` still does `lo->lo_backing_file`:

```
zram_ext.c:541:16: error: incomplete definition of type 'struct loop_device'
```

The patch restores the old public header.

### `0003-samsung-kdp-cred-compat-symbols.patch`
`kernel/cred.c`, `include/linux/cred.h` — **this is the fix that brought
Bluetooth (and the Wi-Fi HAL) back to life on the stock ROM.**

Samsung's stock kernel is built with `CONFIG_KDP_CRED=y` (Knox Data Protection),
so the inline helpers in their `<linux/cred.h>` — `get_cred()`, `get_cred_rcu()`,
`put_cred()`, `get_new_cred()` — call

* `kdp_usecount_inc()` / `kdp_usecount_inc_not_zero()`
* `kdp_usecount_dec_and_test()`
* `kdp_set_cred_non_rcu()`

instead of touching `cred->usage` / `cred->non_rcu` directly. Every **prebuilt
stock module** that takes a cred reference therefore imports those symbols, and
a plain GKI kernel does not have them:

```
bluetooth: Unknown symbol kdp_set_cred_non_rcu (err -2)
bluetooth: Unknown symbol kdp_usecount_inc (err -2)
bluetooth: Unknown symbol kdp_usecount_dec_and_test (err -2)
bt_drv_6877: Unknown symbol hci_register_dev (err -2)      <- cascade
```

Result on a34x: `/system_dlkm` `bluetooth.ko`, `rfcomm.ko`, `hidp.ko`,
`hci_uart.ko`, `btsdio.ko`, `btbcm.ko`, `btqca.ko` all refuse to load, there is
no `/dev/stpbt`, the BT HAL gets `fd -1` and `com.android.bluetooth` dies.

The patch does **not** implement KDP — creds stay ordinary kernel objects. It
only exports the vanilla behaviour under those names, plus `kdp_get_usecount`,
`is_kdp_protect_addr()` and `security_integrity_current()` (both return 0) and
`kdp_enable = false`. The whole block is wrapped in `#ifndef CONFIG_KDP_CRED`,
so a real KDP tree is unaffected.

### `0004-thermal-soc-throttle-bypass.patch`
`drivers/thermal/thermal_core.c`

Opt-in switch that removes **kernel-side** thermal throttling for SoC zones
only. Off by default; enable on the kernel command line with
`thermal_sys.soc_nothrottle=1` (read-only at runtime, so it cannot be flipped
after boot).

`handle_non_critical_trips()` is the single place a governor is invoked
(`tz->governor->throttle()`), so that is where the bypass sits:

```c
	if (trip.type == THERMAL_TRIP_CRITICAL || trip.type == THERMAL_TRIP_HOT)
		handle_critical_trips(tz, trip_id, trip.temperature, trip.type);
	else if (!thermal_zone_throttle_bypassed(tz))
		handle_non_critical_trips(tz, trip_id);
```

What it deliberately does **not** do:

* **`THERMAL_TRIP_HOT` / `THERMAL_TRIP_CRITICAL` are never bypassed.** The
  `handle_critical_trips()` → `tz->ops->critical()` →
  `thermal_zone_device_critical()` → `hw_protection_shutdown()` path still
  runs, so a real overheat still powers the device off.
* **Battery / charger / USB-connector / PMIC zones are never bypassed.** They
  are matched by name (`batt`, `bat_`, `vbat`, `charger`, `chg`, `usb`,
  `pmic`, `fuel`) and that table is consulted *before* the bypass table, so it
  wins. This matters because a zeroed or ignored battery reading does not mean
  "no thermal event" — it means *cold*: `charger-manager.c` would return
  `CM_BATT_COLD` and stop charging.
* **No temperature is faked.** `tz->temperature`, the sysfs `temp` attribute
  and `thermal_genl_sampling_temp()` keep reporting the real reading. Faking
  `0` in `__thermal_zone_get_temp()` would blind the critical path above and
  the userspace thermal HAL at the same time.

Bypassed zone names are matched as substrings of `tz->type`: `cpu`, `gpu`,
`soc`, `npu`, `apu`, `little`, `big`, `tzts`, `tsens`, `ts`, `skin`, `ap`.
Each affected zone logs once at registration so `dmesg` shows exactly what was
affected.

**Scope:** kernel governors only. An Android thermal HAL that writes
cooling-device state from userspace is not in this file and is not affected.

## Adding a new fix

```bash
# 1. edit the file inside kernel-6.6/ and make the build pass
# 2. turn it into a patch (paths relative to the kernel tree!)
git diff --relative=kernel-6.6 -- kernel-6.6/path/to/file \
  > kernel/patches-kernel-6.6/0004-short-name.patch
# 3. put the tree back so it stays pristine
kernel/patches-kernel-6.6/apply.sh --revert && git checkout -- kernel-6.6
```

## What is *not* here

Fixes to Samsung's own trees (`vendor/…`, `kernel/kernel_device_modules-6.6/…`)
are committed directly to those folders — they are Samsung sources that we do
not replace wholesale, so there is nothing to re-apply:

* `MAX`/`MIN` guards (`stp_uart.c`, `btmtk_define.h` ×2, `mali_malisw.h` ×2,
  `mtk-mae-isp8.c`, `zsmalloc.c`, 30+ thermal `tscpu_settings.h`, `rpmb-mtk.c`,
  `cpufreq_limit.c`, ged/gpufreq/drm/mdpm/blocktag …)
* mali: `get_current_cred_module()`/`put_cred_module()` → `get_current_cred()`/`put_cred()`
* `stmmac_main.c` VLA, `ufs-sec-feature.c` `UFS_CMD_ERR`
* Samsung PM `Kconfig`/`Makefile`/`sec_wakeup_cpu_allocator.c`
* `disable_module_sig.config`

CI job **#4 Patches** greps for those on every run so they cannot silently
disappear.

## Optional patches (not applied by default)

| what | when |
|---|---|
| `Permissive/selinux-make-permissive.patch` | workflow input `permissive: true` |
| `patch/*.patch` | workflow input `custom_patches: true` |

Both are handled by `build_kernel.sh → apply_optional_patches`.
