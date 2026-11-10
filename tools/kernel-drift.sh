#!/usr/bin/env bash
#
# kernel-drift.sh — is the kernel tree's difference from HEAD EXACTLY our patches?
#
# `.apply_kernel_patches` needs this answered before it decides whether to hide the
# patched files from git's dirty check:
#
#   * If the tree differs from HEAD by exactly our patch set, that is not drift.
#     The patches are tracked, reviewed content that every build applies. Hiding
#     them keeps the kernel version string stable, which keeps /lib/modules/<ver>
#     stable, which keeps a boot-only flash valid.
#   * If it differs by anything else, somebody has uncommitted work in the kernel
#     and the kernel must say so. "-dirty" should mean "there is work here that is
#     not written down", not "a patch was applied".
#
# ═══ THE CHECK CANNOT ASK GIT WHETHER THE TREE IS CLEAN ══════════════════════
#
# `--assume-unchanged` is precisely a promise to git that those files did NOT
# change, so a tree carrying the flag reports zero modified files whether it is
# pristine or hand-edited beyond recognition. Observed here: `aosp` reported 0
# changed files while patch 0003 was fully applied to lib/kobject_uevent.c. The
# caller MUST clear the flag before invoking this; everything below re-derives the
# truth from HEAD.
#
# ═══ WHAT COUNTS AS "EXACTLY OUR PATCHES" ════════════════════════════════════
#
# Three tests per patched project, because no one of them suffices:
#
#   1. No modified file outside the set our patches touch.
#   2. Every patch reverse-applies cleanly (`git apply --check --reverse`) —
#      proves the patch is present and intact.
#   3. Per-file added/deleted line counts equal the patch's own counts.
#
# (3) is not redundant. An extra hand-edit elsewhere in an already-patched file
# usually leaves the patch's own hunks reversible, so (2) still passes and the
# edit rides along invisibly. The line counts change, so numstat catches it.
#
# ═══ EVERY PROJECT, NOT JUST PATCHED ONES ════════════════════════════════════
#
# The scan covers every git project under the repo checkout. Scoping it to
# projects our patches touch would have missed the case that motivated this: the
# clk-acpm-gpu work lived as a modified Kbuild plus an UNTRACKED driver in
# private/google-modules/soc/gs — a project with no patch of its own — and was
# compiled into every shipped image while no version string recorded it. A drift
# check that only looks where it already expects to find changes is not a check.
# 84 projects scan in ~4s, so there is no reason to narrow it.
#
# ═══ ENCODABLE vs FATAL ══════════════════════════════════════════════════════
#
# `CONFIG_LOCALVERSION_AUTO` derives "-dirty" from ONE tree: $VERSION_PROJECT.
# That splits drift in two:
#
#   ENCODABLE — modified tracked files in $VERSION_PROJECT. Leaving the patches
#     visible makes setlocalversion stamp "-dirty" by itself; the build proceeds,
#     honestly labelled. Uncommitted changes under kernel/patches/ land here too,
#     since the patches are applied INTO that project.
#
#   FATAL — drift that cannot reach the version string at all:
#       * any other project. They are separate git repos feeding MODULES, not the
#         kernel version, so their drift changes what ships while every version
#         string stays byte-identical.
#       * untracked files anywhere. setlocalversion's dirty check is `-uno`, so a
#         hand-added .c is compiled in and never mentioned.
#     No honest label exists, so refuse to build rather than emit an image whose
#     contents no version identifies. This repo has already lost a slot to a
#     kernel/modules mismatch; that is exactly this failure mode.
#
# KERNEL_DRIFT_OK=1 downgrades FATAL to a loud warning for a scratch build. Never
# use it for anything that reaches a device you cannot physically touch.
#
# Usage: kernel-drift.sh <kernel_source_dir> [patch]...
# Exit:  0 clean    — caller may hide the patches
#        1 dirty    — encodable; caller must leave them visible (-> -dirty)
#        2 fatal    — caller must abort
set -uo pipefail

SRC="${1:?usage: kernel-drift.sh <kernel_source_dir> [patch]...}"; shift
PATCHES=("$@")

# Every remaining argument must be one readable patch file. A bad argument is
# not a cosmetic complaint here — it produces a FALSE ALL-CLEAR, which is the
# one outcome this script must never emit. Hit while testing this file from an
# interactive zsh: `kernel-drift.sh kernel/source $P` with P=$(find …) passes
# the WHOLE list as a single argument, because zsh does not word-split unquoted
# parameters the way bash does. Every per-patch test then matches no project and
# is silently skipped, and — since the caller has already set --assume-unchanged
# on exactly those files — git reports the tree unmodified too. Verdict: clean,
# on a tree with a planted edit sitting in it. The Makefile passes a
# space-separated $(PATCH_FILES) and is unaffected; hand invocations are not.
for _p in ${PATCHES[@]+"${PATCHES[@]}"}; do
	[ -f "$_p" ] && continue
	printf '  FATAL: not a readable patch file: %q\n' "$_p" >&2
	printf '  (pass each patch as its own argument — from zsh, use an array:\n' >&2
	printf '   p=(kernel/patches/**/*.patch(N)); tools/kernel-drift.sh kernel/source $p)\n' >&2
	echo fatal; exit 2
done

# The only project whose git state feeds CONFIG_LOCALVERSION_AUTO. Resolved to a
# real path: in GrapheneOS's tree `aosp` is a symlink to `common`, and projects
# below are compared by real path, so the alias and the target are one project.
VERSION_PROJECT=$(realpath -e "$SRC/aosp" 2>/dev/null || echo "$SRC/aosp")

encodable=0
fatal=0
say() { printf '  %s\n' "$*" >&2; }

# ═══ PROJECT DIR vs. GIT REPO ═════════════════════════════════════════════════
#
# A patch lives at kernel/patches/<project-dir>/, and each patch is -p1 relative
# to <project-dir>. Under AOSP `repo` every project-dir is its own git repo. In
# GrapheneOS's monorepo it is not: private/devices/google/gs201 is a plain
# SUBDIRECTORY of one big repo. So everything below works in terms of the
# containing repo (top_of) and the project-dir's path inside it (prefix_of):
#   * `git apply` must run from the repo top with --directory=<prefix>; run from
#     the subdirectory it prints "Skipped patch" and --check passes VACUOUSLY,
#     which here would mean a false "already applied"/"clean".
#   * `git diff --name-only` always prints repo-top-relative paths, so the
#     patch's own file list is prefixed to match.
# kernel/patches/<proj>/… or kernel/patches-<device>/<proj>/… -> <proj>
proj_of()     { dirname "${1#kernel/*/}"; }
top_of()      { git -C "$SRC/$(proj_of "$1")" rev-parse --show-toplevel 2>/dev/null; }
prefix_of()   { git -C "$SRC/$(proj_of "$1")" rev-parse --show-prefix 2>/dev/null; }
patch_files() {
	local pre; pre=$(prefix_of "$1")
	grep -oE '^\+\+\+ b/[^[:space:]]+' "$1" | sed "s|^+++ b/|$pre|"
}
# Files a patch CREATES (repo-top-relative). After the apply they exist but are
# untracked, and `git diff` never lists them, so tests 2 and 3 below must treat
# them as ours. Their content is still fully verified: a reverse-apply only
# succeeds if every created file matches the patch byte for byte.
patch_new_files() {
	local pre; pre=$(prefix_of "$1")
	awk '/^diff --git a\//{f=$4; sub(/^b\//,"",f); next} /^new file mode/{print f}' "$1" | sed "s|^|$pre|"
}
# patch_apply <patch> [git-apply args...] — run from the repo top, prefixed.
patch_apply() {
	local p=$1; shift
	local pre abs; pre=$(prefix_of "$p"); abs=$(readlink -f "$p")
	(cd "$(top_of "$p")" && git apply ${pre:+"--directory=$pre"} "$@" "$abs")
}
# Display name of a project (repo top), relative to $SRC; "." for the monorepo root.
name_of() {
	local r; r=$(realpath --relative-to="$(realpath "$SRC")" "$1")
	printf '%s' "$r"
}

# ★ Clear --assume-unchanged ourselves rather than trusting the caller to have
# done it. This is not defensiveness for its own sake: a caller that forgets
# leaves git blind to exactly the files most likely to have been edited, and the
# check then reports "clean" with total confidence. That is not a hypothetical —
# writing this script, an un-hide loop failed silently and two test runs returned
# "clean" against a tree with a deliberate extra edit sitting in it. A check whose
# failure mode is a false all-clear has to own its preconditions.
for p in "${PATCHES[@]}"; do
	[ -d "$SRC/$(proj_of "$p")" ] || continue
	top=$(top_of "$p") || continue
	while read -r f; do
		[ -n "$f" ] || continue
		git -C "$top" update-index --no-assume-unchanged "$f" 2>/dev/null || true
	done <<< "$(patch_files "$p")"
done

# --- outer repo: are the patch files themselves uncommitted? -----------------
# Encodable: the patches are applied into $VERSION_PROJECT, so simply not hiding
# them yields the -dirty that says "the patch set here is not committed".
if [ -n "$(git status --porcelain -- kernel/patches 'kernel/patches-*' 2>/dev/null)" ]; then
	say "DRIFT: kernel/patches has uncommitted changes:"
	git status --porcelain -- kernel/patches 'kernel/patches-*' 2>/dev/null | sed 's/^/        /' >&2
	encodable=1
fi

# --- enumerate every git project in the checkout -----------------------------
# Skip out/ (build output, full of generated git-less trees and bazel caches) and
# .repo/ (repo's own bookkeeping, not a build input — its manifests project
# carries an untracked file as a matter of course).
#
# Absolute REAL paths, so that (a) the monorepo root — whose .git sits directly
# in $SRC — is a project like any other (the old `sed "s|^$SRC/||"` left it as
# the bare $SRC and every per-project path then doubled up), and (b) a patch
# matches its project by the repo it actually lands in (top_of), not by the
# spelling of its kernel/patches/ directory.
mapfile -t PROJECTS < <(
	find "$SRC" -maxdepth 6 -name .git -not -path '*/out/*' -not -path '*/.repo/*' 2>/dev/null \
		| sed 's|/\.git$||' | xargs -r -d '\n' realpath | sort -u
)
[ ${#PROJECTS[@]} -gt 0 ] || { say "FATAL: no git projects under $SRC (run 'just clone_kernel_source')"; echo fatal; exit 2; }

for tgt in "${PROJECTS[@]}"; do
	proj=$(name_of "$tgt")

	# Files our patches touch in this project (empty for unpatched projects).
	ours=""
	for p in "${PATCHES[@]}"; do
		[ "$(top_of "$p")" = "$tgt" ] || continue
		ours+=$'\n'"$(patch_files "$p")"
	done
	ours=$(printf '%s\n' "$ours" | sed '/^$/d' | sort -u)

	# 1. modified tracked files outside our patch set
	changed=$(git -C "$tgt" diff --name-only 2>/dev/null | sed '/^$/d' | sort -u)
	if [ -n "$changed" ]; then
		extra=$(comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$ours"))
		if [ -n "$extra" ]; then
			if [ "$tgt" = "$VERSION_PROJECT" ]; then
				say "DRIFT ($proj): modified files that are not ours:"
				printf '%s\n' "$extra" | sed 's/^/        /' >&2
				encodable=1
			else
				say "FATAL ($proj): modified files, and this project cannot reach the version string:"
				printf '%s\n' "$extra" | sed 's/^/        /' >&2
				fatal=1
			fi
		fi
	fi

	# 2. untracked files — compiled in, but invisible to setlocalversion (-uno).
	#    Files our own patches create are untracked by construction; skip them.
	created=""
	for p in "${PATCHES[@]}"; do
		[ "$(top_of "$p")" = "$tgt" ] || continue
		created+=$'\n'"$(patch_new_files "$p")"
	done
	untracked=$(git -C "$tgt" ls-files --others --exclude-standard 2>/dev/null \
		| grep -vxF -f <(printf '%s\n' "$created" | sed '/^$/d') || true)
	if [ -n "$untracked" ]; then
		say "FATAL ($proj): untracked files are built but can never appear in any version string:"
		printf '%s\n' "$untracked" | sed 's/^/        /' >&2
		fatal=1
	fi

	# 3. each patch present, intact, and with no extra edits inside its files
	for p in "${PATCHES[@]}"; do
		[ "$(top_of "$p")" = "$tgt" ] || continue
		if ! patch_apply "$p" --check --reverse >/dev/null 2>&1; then
			# NOT-YET-APPLIED IS NOT DRIFT. This check runs BEFORE the apply
			# stanza, so on a pristine tree — a fresh clone_kernel_source, or any
			# `repo sync`, which is the documented path that also drops the
			# .apply_kernel_patches sentinel — every patch is legitimately absent
			# and the reverse-check fails for all of them. Treating that as drift
			# made the FIRST build after a sync abort with "not cleanly applied"
			# for a tree that had nothing wrong with it, and for a non-version
			# project (gs201) it escalated to FATAL, so the build could never
			# reach the code that would have applied the patch.
			#
			# A patch that applies FORWARD cleanly is provably absent and intact:
			# the tree is HEAD, which is exactly the state the apply stanza
			# expects. Only a patch that goes neither way is real drift — a
			# partial application, or a tree edited out from under the patch.
			if patch_apply "$p" --check >/dev/null 2>&1; then
				# ...but only if its files are untouched. A hand edit that does not
				# overlap a hunk still lets the patch apply forward, and without
				# this the edit was reported "clean" and then built in unrecorded.
				pf=$(patch_files "$p")
				if [ -n "$(cd "$tgt" && git diff --name-only -- $pf 2>/dev/null)" ]; then
					say "DRIFT ($proj): $(basename "$p") is not applied, yet its files are modified:"
					(cd "$tgt" && git diff --name-only -- $pf) | sed 's/^/        /' >&2
					if [ "$tgt" = "$VERSION_PROJECT" ]; then encodable=1; else fatal=1; fi
				fi
				continue
			fi
			say "DRIFT ($proj): $(basename "$p") neither applies nor is already applied"
			if [ "$tgt" = "$VERSION_PROJECT" ]; then encodable=1; else fatal=1; fi
			continue
		fi
		# Resolve the file list HERE, before any cd: $p is repo-relative, so
		# expanding it inside a subshell that has already cd'd into $tgt finds
		# nothing, silently yielding an empty pathspec — and `git diff --numstat --`
		# with no paths diffs everything, so the comparison quietly stops testing
		# what it claims to. Cost me a false "clean" on a tree with a planted edit.
		# Created files are verified by the reverse-apply above and never show
		# in `git diff`, so compare line counts over the pre-existing files only.
		newf=$(patch_new_files "$p")
		pfiles=$(patch_files "$p" | grep -vxF -f <(printf '%s\n' "$newf" | sed '/^$/d') || true)
		want=$(patch_apply "$p" --numstat 2>/dev/null \
			| awk -v new="$newf" 'BEGIN{n=split(new,a,"\n"); for(i=1;i<=n;i++) skip[a[i]]=1}
			                     !($3 in skip){print $1" "$2" "$3}' | sort)
		# A patch that only CREATES files (lynx's kleaf glue) leaves $pfiles
		# empty, and the bare `--` would then diff the whole project, charging
		# every other patch's edits to this one. Nothing pre-existing to compare.
		if [ -n "$pfiles" ]; then
			got=$(cd "$tgt" && git diff --numstat -- $pfiles 2>/dev/null | awk '{print $1" "$2" "$3}' | sort)
		else
			got=""
		fi
		if [ "$want" != "$got" ]; then
			say "DRIFT ($proj): $(basename "$p") is applied, but its files carry EXTRA edits"
			say "        expected: $(printf '%s' "$want" | tr '\n' ';')"
			say "        actual:   $(printf '%s' "$got" | tr '\n' ';')"
			if [ "$tgt" = "$VERSION_PROJECT" ]; then encodable=1; else fatal=1; fi
		fi
	done
done

if [ "$fatal" = 1 ]; then
	if [ "${KERNEL_DRIFT_OK:-0}" = 1 ]; then
		say ""
		say "KERNEL_DRIFT_OK=1 — continuing anyway. This image's modules will NOT match"
		say "any version string. Do not flash it to a device you cannot physically reach."
		echo dirty; exit 1
	fi
	say ""
	say "This drift cannot be expressed in the kernel version string, so the build would"
	say "produce an image whose contents no version identifies. Commit it, revert it, or"
	say "capture it under kernel/patches/ (see kernel/patches/README.md)."
	say "Override for a scratch build with KERNEL_DRIFT_OK=1."
	echo fatal; exit 2
fi
[ "$encodable" = 1 ] && { echo dirty; exit 1; }
echo clean; exit 0
