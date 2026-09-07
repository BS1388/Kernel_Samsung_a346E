#!/bin/bash
# =============================================================================
# Apply the kernel-6.6 compatibility patches to a kernel tree.
#
# The tree in kernel-6.6/ is kept PRISTINE (plain upstream common-android15-6.6).
# Everything this device needs on top of it lives here as numbered patches, so
# updating the kernel is just:
#
#     rm -rf kernel-6.6 && unzip/copy the new kernel-6.6 in its place
#     kernel/patches-kernel-6.6/apply.sh        # <- re-applies everything
#
# build_kernel.sh runs this automatically on every build, so in CI you do not
# have to do anything at all.
#
# Usage:
#   apply.sh [<kernel tree>]      apply   (default tree: <repo>/kernel-6.6)
#   apply.sh --check [<tree>]     dry-run only, change nothing
#   apply.sh --revert [<tree>]    undo, back to the pristine tree
#
# Patch files are -p1 relative to the KERNEL TREE ROOT (scripts/..., kernel/...,
# include/...), not to the repo root, so they survive a rename of the folder
# (kernel-6.6 vs Kernel-6.6) and can be applied to any 6.6 tree.
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="apply"
case "${1:-}" in
  --check|-n)  MODE="check";  shift ;;
  --revert|-R) MODE="revert"; shift ;;
  -h|--help)   sed -n '2,26p' "$0"; exit 0 ;;
esac

KDIR="${1:-}"
if [ -z "$KDIR" ]; then
  for c in "$DIR/../../kernel-6.6" "$DIR/../../Kernel-6.6" "$DIR/../kernel-6.6"; do
    if [ -f "$c/Makefile" ]; then KDIR="$c"; break; fi
  done
fi
if [ -z "$KDIR" ] || [ ! -f "$KDIR/Makefile" ]; then
  echo "error: no kernel tree found - usage: $0 [--check|--revert] <path to kernel-6.6>" >&2
  exit 1
fi
KDIR="$(cd "$KDIR" && pwd)"

shopt -s nullglob
PATCHES=("$DIR"/*.patch)
shopt -u nullglob
if [ ${#PATCHES[@]} -eq 0 ]; then
  echo "no patches in $DIR - nothing to do"
  exit 0
fi

echo "kernel tree : $KDIR"
echo "patches     : ${#PATCHES[@]} in $DIR"
echo "mode        : $MODE"
echo

FAILED=0
for p in "${PATCHES[@]}"; do
  base="$(basename "$p")"
  case "$MODE" in
    # --forward is what makes this idempotent: patch then refuses to apply
    # something that is already in the wanted state instead of flipping it back
    check)  args=(-p1 -d "$KDIR" --dry-run --forward --batch --no-backup-if-mismatch -r /tmp/kpatch.rej) ;;
    revert) args=(-p1 -d "$KDIR" -R --forward --batch --no-backup-if-mismatch -r /tmp/kpatch.rej) ;;
    *)      args=(-p1 -d "$KDIR" --forward --batch --no-backup-if-mismatch -r /tmp/kpatch.rej) ;;
  esac

  if patch "${args[@]}" < "$p" > /tmp/kpatch.log 2>&1; then
    echo "  OK       $base"
  elif grep -qE "Reversed \(or previously applied\)|which already exists|which does not exist|Skipping patch" /tmp/kpatch.log; then
    # --forward on an already patched tree, or --revert on a pristine one:
    #   "Reversed (or previously applied) patch detected"      (edited file)
    #   "would create the file ..., which already exists"      (new file, apply)
    #   "would delete the file ..., which does not exist"      (new file, revert)
    echo "  SKIP     $base (already in the expected state)"
  else
    echo "  FAILED   $base"
    sed 's/^/           /' /tmp/kpatch.log
    FAILED=1
  fi
done

echo
if [ "$FAILED" != "0" ]; then
  echo "at least one patch did not apply - fix it, then regenerate it with:"
  echo "  git diff --relative=kernel-6.6 -- kernel-6.6/<file> > kernel/patches-kernel-6.6/00NN-name.patch"
  exit 1
fi
echo "done ($MODE)"
