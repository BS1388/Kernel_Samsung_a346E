# Permissive

This folder contains SELinux permissive patches.

- `selinux-make-permissive.patch`: Makes SELinux permissive by setting `selinux_enforcing_boot` to 0 and removing enforcing checks.

This patch is applied when the `permissive` input is set to `true` in the workflow dispatch.

- For NO-ROOT builds, SELinux remains enforcing by default.
- For KSU builds, you can choose permissive or enforcing.

The patch is from Fede2782 and is commonly used for custom kernels to avoid SELinux denials.

Usage in workflow:
```yaml
permissive: true  # Apply permissive patch
```
