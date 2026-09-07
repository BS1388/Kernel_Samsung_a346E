# Patch Directory

## Structure

- `compat-kernel-6.6/` — **empty of `.patch` files on purpose.**
  All kernel-6.6 compatibility fixes are baked into the source tree
  (`kernel-6.6/`, `kernel/kernel_device_modules-6.6/`, `vendor/`), so they are
  always in effect and can never fail to apply. See
  [`compat-kernel-6.6/README.md`](compat-kernel-6.6/README.md) for the full list
  of what is fixed and how to carry the fixes over to a newer kernel tree.
  `build_kernel.sh → apply_compat_patches()` still auto-applies any `.patch`
  you drop in there, so the mechanism stays available for future fixes.

- `*.patch` (root of `patch/`) — **optional extra patches**, applied only when
  the workflow input `custom_patches: true` is set
  (`build_kernel.sh → apply_optional_patches`). Put your own patches here; they
  are applied with `patch -p1` **inside the kernel tree**, i.e. paths start at
  `security/…`, `drivers/…`, not at `kernel-6.6/…`.

- `../Permissive/selinux-make-permissive.patch` — applied only when the workflow
  input `permissive: true` is set. Also `-p1` inside the kernel tree.

## Order used by the build

`build_kernel.sh` (`prepare_workspace`):

1. `apply_optional_patches` — `Permissive/` (if `PERMISSIVE=true`) then
   `patch/*.patch` (if `CUSTOM_PATCH=true`), on the source tree
2. copy the tree into the bazel workspace (`kernel/kernel-6.6/`)
3. `apply_compat_patches` — every `patch/compat-kernel-6.6/*.patch` (currently
   none), with `patch -p1 --forward`, so re-applying is harmless
4. `apply_compat_fixes` — inline `sed`/header safety net (loop.h, MAX/MIN,
   SEC_PM, module signing) that repairs the workspace copy even if a source
   file is ever reverted

CI job **`#4 Patches`** dry-runs everything in 1–2 minutes and greps the tree
for the baked-in fixes *before* the 50-minute build starts.
