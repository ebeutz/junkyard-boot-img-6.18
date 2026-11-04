#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Restrict a kernel `repo` tree's clang prebuilt checkout to the one release
# the kernel builds with.
#
#   tools/sparse-prebuilts.sh <kernel-source-dir> <clang-version>
#
# e.g. tools/sparse-prebuilts.sh kernel/source-felix r487747c
#
# Run between `repo sync -n` (fetch only) and `repo sync -l` (checkout).
# platform/prebuilts/clang/host/linux-x86 carries several full clang releases
# side by side (~2.5 GB each checked out), and kernel/kbuild.mk reads only
# clang-<version>/, so every other release directory is excluded with a
# non-cone sparse-checkout pattern; the repo's top-level files stay.
#
# Idempotent. A later `repo sync` keeps honouring the pattern, because it lives
# in the project's git dir (core.sparseCheckout + info/sparse-checkout).
#
# (The GrapheneOS-monorepo device fetches clang with plain git and does the
# same thing inline in clone_kernel_source.)
set -euo pipefail

src=${1:?kernel source dir}
clang=${2:?clang version, e.g. r487747c}
proj=prebuilts/clang/host/linux-x86

gd=$src/.repo/projects/$proj.git
if [ ! -d "$gd" ]; then
	echo "sparse-prebuilts: $proj not in this tree, skipping" >&2
	exit 0
fi
git --git-dir="$gd" config core.sparseCheckout true
mkdir -p "$gd/info"
printf '%s\n' '/*' '!/clang-*/' "/clang-$clang/" > "$gd/info/sparse-checkout"
# A tree that was already checked out in full shrinks now rather than on the
# next `repo sync -l`.
if [ -e "$src/$proj/.git" ]; then
	git -C "$src/$proj" read-tree -mu HEAD
fi
