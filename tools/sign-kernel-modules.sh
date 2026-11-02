#!/usr/bin/env bash
#
# sign-kernel-modules.sh — re-sign the kleaf staging archives' modules with GKI's key.
#
# Usage: sign-kernel-modules.sh <kernel_source_dir> <dist_dir> <out_dir>
#
# Writes <out_dir>/{vendor,system}_dlkm_staging_archive.tar.gz: the same archives
# as <dist_dir>'s, with every *.ko signed by the GKI kernel_build's signing key.
# The dist archives themselves are never modified.
#
# ═══ WHY ═════════════════════════════════════════════════════════════════════
#
# GrapheneOS's 6.18 GKI is built with CONFIG_MODULE_SIG_FORCE=y, so the kernel
# refuses ANY module whose trailing signature it cannot verify against the keys
# built into Image. In a kleaf mixed build the Image comes from
# //common:kernel_aarch64 (GKI), while vendor/ext modules are built by the
# device's own kernel_build, which generates its own throwaway signing key. Those
# modules are therefore untrusted by the Image we boot: every vendor module —
# UFS, AOC, display, the USB-Ethernet path's PHY/typec glue — fails to load with
# "Key was rejected by service", and the device never reaches the rootfs.
#
# GrapheneOS solves this in private/devices/google/common/tools/build_dist.sh by
# running GKI's scripts/sign-file over dist/*.ko after the build ("Sign the flat
# modules imported by the OS build with this GKI's key. Raw Kleaf images and
# module archives are not modified here."). We install from the staging
# archives, not the flat dist/*.ko, so we do the identical thing to copies of
# those archives.
#
# Signing an already-signed module is fine: sign-file appends a new signature
# block and the kernel only ever checks the LAST one (module_sig_check strips one
# trailer). GKI's own system_dlkm modules are already GKI-signed; re-signing
# them is harmless and keeps this script free of a "which ones need it" guess.
#
# ═══ WHY HERE, AT .build_kernel ══════════════════════════════════════════════
#
# sign-file is a host tool built by kleaf; it is only guaranteed to run in the
# environment bazel ran in (the FHS env), not in the Debian container that runs
# .install_kernel.
set -euo pipefail

SRC=$(realpath "${1:?usage: sign-kernel-modules.sh <kernel_source_dir> <dist_dir> <out_dir>}")
DIST=$(realpath "${2:?missing <dist_dir>}")
OUT=${3:?missing <out_dir>}

GKI="$SRC/bazel-bin/common/kernel_aarch64"
SIGN="$GKI/scripts/sign-file"
KEY="$GKI/certs/signing_key.pem"
CRT="$GKI/certs/signing_key.x509"
MAGIC='~Module signature appended~'

for f in "$SIGN" "$KEY" "$CRT"; do
	[ -e "$f" ] || { echo "ERROR: $f missing — was GKI built from source in this tree?" >&2; exit 1; }
done

# Same guard as build_dist.sh: these keys only mean something if the Image we
# are about to ship IS the GKI Image they were generated for.
if ! cmp -s "$DIST/Image" "$GKI/Image"; then
	echo "ERROR: $DIST/Image differs from $GKI/Image — the GKI signing key would not" >&2
	echo "       match the shipped kernel. Refusing to sign with the wrong key." >&2
	exit 1
fi

mkdir -p "$OUT"
work=$(mktemp -d "$OUT/.sign.XXXXXX")
trap 'rm -rf "$work"' EXIT

for a in vendor_dlkm system_dlkm; do
	arc="$DIST/${a}_staging_archive.tar.gz"
	[ -f "$arc" ] || { echo "ERROR: $arc missing" >&2; exit 1; }
	mkdir -p "$work/$a"
	tar -xzf "$arc" -C "$work/$a"

	n=0
	while IFS= read -r -d '' ko; do
		"$SIGN" sha256 "$KEY" "$CRT" "$ko"
		n=$((n + 1))
	done < <(find "$work/$a" -name '*.ko' -print0)

	# Verify, don't trust: every module must now END with the signature trailer.
	# A module that silently missed signing is a module the device refuses.
	bad=0
	while IFS= read -r -d '' ko; do
		if [ "$(tail -c 28 "$ko" | head -c 27)" != "$MAGIC" ]; then
			echo "ERROR: not signed after sign-file: ${ko#"$work/"}" >&2
			bad=1
		fi
	done < <(find "$work/$a" -name '*.ko' -print0)
	[ "$bad" = 0 ] || exit 1
	[ "$n" -gt 0 ] || { echo "ERROR: $arc contains no modules" >&2; exit 1; }

	tar -czf "$OUT/${a}_staging_archive.tar.gz.tmp" -C "$work/$a" .
	mv -f "$OUT/${a}_staging_archive.tar.gz.tmp" "$OUT/${a}_staging_archive.tar.gz"
	echo "signed $n modules -> $OUT/${a}_staging_archive.tar.gz"
	rm -rf "${work:?}/$a"
done
