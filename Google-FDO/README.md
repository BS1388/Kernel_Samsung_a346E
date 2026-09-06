# Google-FDO

This directory holds the Google AutoFDO profile `kernel.afdo` (3.1M) outside of `kernel-6.6` to survive kernel updates.

- Original location: `kernel-6.6/android/gki/aarch64/afdo/kernel.afdo` (manually copied before)
- New location: `Google-FDO/kernel.afdo`
- Bazel label: `//Google-FDO:kernel.afdo`
- Referenced in: `kernel/build/kernel/kleaf/impl/kernel_build.bzl` line `clang_autofdo_profile = "//Google-FDO:kernel.afdo"`

When updating `kernel-6.6` from Samsung or AOSP, you no longer need to re-copy `kernel.afdo` into `kernel-6.6`. The build will use this external copy.

If you update the AFDO profile, replace `Google-FDO/kernel.afdo` and optionally also copy to `kernel-6.6/android/gki/aarch64/afdo/kernel.afdo` for compatibility.

SHA256 (original):
```
d53c8cca54c7162c501628a4db6050b45213a331d003b12afd8acc82c786110d  kernel.afdo
```
