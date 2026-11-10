#!/usr/bin/env bash
# Restrict the toolchain prebuilt checkouts of a kernel `repo` tree to the one
# clang and one rustc version the build uses.
#
#   tools/sparse-prebuilts.sh <kernel-source-dir> <clang-version> [rustc-version]
#
# e.g. tools/sparse-prebuilts.sh kernel/source-lynx r596125 1.96.0
#
# Run between `repo sync -n` (fetch only) and `repo sync -l` (checkout).
# platform/prebuilts/clang/host/linux-x86 carries six full clang releases
# (~2.5 GB each checked out) and rust-toolchain/linux-musl-x86 four rustc
# releases (~3 GB each); a plain checkout of both filled a 40 GB build host
# before the kernel build started. Only clang-<version>/ and <rustc-version>/
# are read (kleaf picks them from common/bazel/constants.scl), so every other
# release directory is excluded with a non-cone sparse-checkout pattern; the
# repos' top-level files and helper directories (kleaf/, soong/, ...) stay.
# platform/prebuilts/build-tools also loses darwin-x86/ and linux-arm64/.
#
# Idempotent. A later `repo sync` keeps honouring the patterns, because they
# live in the project's git dir (core.sparseCheckout + info/sparse-checkout).
set -euo pipefail

src=${1:?kernel source dir}
clang=${2:?clang version, e.g. r596125}
rustc=${3:-}

sparse() {
	local proj=$1; shift
	local gd=$src/.repo/projects/$proj.git
	if [ ! -d "$gd" ]; then
		echo "sparse-prebuilts: $proj not in this tree, skipping" >&2
		return 0
	fi
	git --git-dir="$gd" config core.sparseCheckout true
	mkdir -p "$gd/info"
	printf '%s\n' "$@" > "$gd/info/sparse-checkout"
	# A tree that was already checked out in full shrinks on the next
	# `repo sync -l`; re-read the patterns now if a work tree exists.
	if [ -e "$src/$proj/.git" ]; then
		git -C "$src/$proj" read-tree -mu HEAD
	fi
	echo "sparse-prebuilts: $proj -> $*"
}

sparse prebuilts/clang/host/linux-x86 '/*' '!/clang-*/' "/clang-$clang/"
if [ -n "$rustc" ]; then
	sparse prebuilts/rust-toolchain/linux-musl-x86 '/*' '!/[0-9]*/' "/$rustc/"
fi
sparse prebuilts/build-tools '/*' '!/darwin-x86/' '!/linux-arm64/'
