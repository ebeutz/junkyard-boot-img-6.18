#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# kconfig-check-fragments.sh <.config> <fragment>...
#
# Fail if any value a defconfig fragment asks for did not survive into the
# final .config. olddefconfig drops a request silently when the symbol does not
# exist in this kernel or its dependencies are unmet, and the build then goes
# ahead without it: a =y driver that is simply not there, found only on the
# device. Kleaf ran the same check after applying fragments (it is how the
# android-mainline removal of CONFIG_NFS_V4_1 was caught), so kernel/kbuild.mk
# keeps it.
#
# "=n" and "# CONFIG_X is not set" are satisfied by the symbol being unset or
# absent. Anything else must match exactly.
set -euo pipefail

config=$1
shift
bad=0
for frag in "$@"; do
	while IFS= read -r line; do
		if [[ $line =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then
			sym=${BASH_REMATCH[1]} want=${BASH_REMATCH[2]}
		elif [[ $line =~ ^\#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
			sym=${BASH_REMATCH[1]} want=n
		else
			continue
		fi
		have=$(grep -E "^$sym=" "$config" | head -n1 | cut -d= -f2- || true)
		if [ "$want" = n ]; then
			[ -z "$have" ] || [ "$have" = n ] && continue
		elif [ "$have" = "$want" ]; then
			continue
		fi
		echo "  $frag: $sym=$want, but .config has ${have:-<unset>}" >&2
		bad=1
	done < "$frag"
done
if [ "$bad" = 1 ]; then
	echo "ERROR: defconfig fragment values did not make it into $config (see above)." >&2
	echo "       The symbol is gone from this kernel or its dependencies are not met." >&2
	exit 1
fi
