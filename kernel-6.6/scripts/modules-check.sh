#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

set -e

if [ $# != 1 ]; then
	echo "Usage: $0 <modules.order>" >& 2
	exit 1
fi

exit_code=0

# Deduplicate modules.order to handle Kbuild bug where same entry appears twice
if [ -f "$1" ]; then
	tmp_sorted=$(mktemp)
	sort -u "$1" -o "$tmp_sorted" 2>/dev/null || cp "$1" "$tmp_sorted"
	mv "$tmp_sorted" "$1" 2>/dev/null || true
fi

# Check uniqueness of module names (only error if different paths share same basename)
check_same_name_modules()
{
	for m in $(sed 's:.*/::' "$1" | sort | uniq -d)
	do
		paths=$(sed -n "/\/$m/s:^\(.*\)\.o$:\1:p" "$1" | sort -u)
		num_paths=$(echo "$paths" | wc -l)
		if [ "$num_paths" -gt 1 ]; then
			echo "error: the following would cause module name conflict:" >&2
			sed -n "/\/$m/s:^\(.*\)\.o$:  \1.ko:p" "$1" >&2
			exit_code=1
		else
			echo "warning: duplicate $m with same path, deduplicated" >&2
		fi
	done
}

check_same_name_modules "$1"

exit $exit_code
