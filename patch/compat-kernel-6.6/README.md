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

## List
- `0001` — `modules-check.sh` dedup
- `0002` — `loop.h` restore
- `0003-0007` — `MAX`/`MIN` guards (stp_uart, btmtk, mali, mtk-mae)
- `0008-0009` — `cred` fixes (Mali)
- `0000` — consolidated single-file version

## Updating
When you bump `kernel-6.6`, test build. If it fails, fix the file, then:
```bash
git diff -- kernel-6.6/ vendor/ > patch/compat-kernel-6.6/0010-new-fix.patch
git add patch/compat-kernel-6.6/0010-new-fix.patch
```
