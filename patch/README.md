# `patch/` — optional extra patches

Drop your own `.patch` files **here** (top level of `patch/`). They are applied
only when the workflow input **`custom_patches: true`** is set:

```
build_kernel.sh → apply_optional_patches → patch -p1 -d <kernel tree> --forward
```

so their paths must start at the **kernel tree root** (`drivers/…`,
`security/…`, `kernel/…`), not at `kernel-6.6/…`:

```bash
# generating one from an edit inside kernel-6.6/
git diff --relative=kernel-6.6 -- kernel-6.6/drivers/foo/bar.c > patch/my-fix.patch
```

If `custom_patches` is off, they are ignored and the build runs without them.

## The other patch sets

| what | where | when |
|---|---|---|
| kernel-6.6 compatibility fixes (incl. the Bluetooth/KDP fix) | `kernel/patches-kernel-6.6/` | **always**, on every build |
| SELinux permissive | `Permissive/selinux-make-permissive.patch` | only when `permissive: true` |
| your extra patches | `patch/*.patch` | only when `custom_patches: true` |

`kernel-6.6/` itself is kept **pristine upstream**, so replacing it with a newer
tree needs no manual re-patching — see
[`kernel/patches-kernel-6.6/README.md`](../kernel/patches-kernel-6.6/README.md).

## Order used by the build (`prepare_workspace`)

1. `apply_kernel66_patches` — `kernel/patches-kernel-6.6/*.patch` (always)
2. `apply_optional_patches` — `Permissive/` then `patch/*.patch`, per the inputs
3. copy the tree into the bazel workspace (`kernel/kernel-6.6/`)
4. `apply_compat_fixes` — inline `sed`/header safety net (loop.h, MAX/MIN,
   SEC_PM, module signing) applied to the workspace copy

CI job **`#4 Patches`** dry-runs 1 and 2 and greps the vendor-side fixes before
the 50-minute build starts.
