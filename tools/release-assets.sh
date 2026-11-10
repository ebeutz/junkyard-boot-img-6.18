#!/bin/bash
#
# release-assets.sh — turn one device's finished build into GitHub release assets.
#
#   tools/release-assets.sh <device> <outdir>
#
# Reads what `just <device>` produced (build/<device>/*.img and the kernel
# dist's dtbo.img) and writes to <outdir>:
#
#   <device>-boot.img, <device>-vendor_boot.img, <device>-dtbo.img
#   <device>-rootfs.img.zst, <device>-super.img.zst     (zstd; sparse zeros compress away)
#   <device>-SHA256SUMS                                  (of the UNCOMPRESSED images and of every asset)
#   <device>-image-version                               (IMAGE_VERSION read out of rootfs.img)
#
# GitHub refuses release assets of 2 GiB or more, so any file at or above
# SPLIT_BYTES is split into <name>.part00, .part01, …; `cat <name>.part* > <name>`
# restores it. super.img holds two copies of the rootfs, so its compressed
# size is roughly twice rootfs.img.zst and is the one most likely to be split.
#
# Run from the repo root (or anywhere: paths are resolved from the script).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

DEVICE="${1:-}"
OUT="${2:-}"
[ -n "$DEVICE" ] && [ -n "$OUT" ] || { echo "usage: $0 <device> <outdir>" >&2; exit 2; }
[ -f "devices/$DEVICE.mk" ] || { echo "unknown device '$DEVICE'" >&2; exit 2; }

# 2 GiB is GitHub's per-asset limit; stay well under it.
SPLIT_BYTES="${SPLIT_BYTES:-$((1900 * 1024 * 1024))}"
ZSTD_LEVEL="${ZSTD_LEVEL:-12}"

BUILD="${BUILD_DIR:-build/$DEVICE}"
DTBO="${DTBO:-kernel/source-$DEVICE/out/$DEVICE/dist/dtbo.img}"

declare -A src=(
	[boot.img]="$BUILD/boot.img"
	[vendor_boot.img]="$BUILD/vendor_boot.img"
	[dtbo.img]="$DTBO"
	[rootfs.img]="$BUILD/rootfs.img"
	[super.img]="$BUILD/super.img"
)
order=(boot.img vendor_boot.img dtbo.img rootfs.img super.img)

for f in "${order[@]}"; do
	[ -s "${src[$f]}" ] || { echo "ERROR: missing ${src[$f]} — build it with: just $DEVICE" >&2; exit 1; }
done

# Which image this is. debugfs reads the ext4 image without mounting it; in
# super.img it reads the first half, which starts at offset 0.
image_version() { debugfs -R 'cat /etc/image-version' "$1" 2>/dev/null | tr -d '\0' | head -n1 || true; }
ver=$(image_version "${src[rootfs.img]}")
[ -n "$ver" ] || { echo "ERROR: could not read /etc/image-version from ${src[rootfs.img]} (is debugfs installed?)" >&2; exit 1; }

# A super.img that holds a different rootfs than rootfs.img is stale (see the
# super.img note in the justfile, and the same check in flash-fastboot.sh).
# Never ship that pair.
sver=$(image_version "${src[super.img]}")
if [ "$sver" != "$ver" ]; then
	echo "ERROR: ${src[super.img]} holds '${sver:-?}' but rootfs.img is '$ver'; rebuild it (just device=$DEVICE build_super_image)" >&2
	exit 1
fi

mkdir -p "$OUT"
sums="$OUT/$DEVICE-SHA256SUMS"
: > "$sums"
printf '%s\n' "$ver" > "$OUT/$DEVICE-image-version"
echo ">>> $DEVICE: $ver"

# Checksums of the images as flashed, so a downloaded+decompressed file can be
# checked against what was built.
echo "# uncompressed images" >> "$sums"
for f in "${order[@]}"; do
	printf '%s  %s\n' "$(sha256sum < "${src[$f]}" | cut -d' ' -f1)" "$DEVICE-$f" >> "$sums"
done

emit() { # emit <file>: split it if it is too big for one asset
	local f="$1" sz
	sz=$(stat -c%s "$f")
	if [ "$sz" -ge "$SPLIT_BYTES" ]; then
		echo "    splitting $(basename "$f") ($sz bytes)"
		split -b "$SPLIT_BYTES" -d -a 2 "$f" "$f.part"
		rm -f "$f"
	fi
}

for f in boot.img vendor_boot.img dtbo.img; do
	cp "${src[$f]}" "$OUT/$DEVICE-$f"
	emit "$OUT/$DEVICE-$f"
done
for f in rootfs.img super.img; do
	echo "    compressing $f"
	zstd -q -T0 -"$ZSTD_LEVEL" -f "${src[$f]}" -o "$OUT/$DEVICE-$f.zst"
	emit "$OUT/$DEVICE-$f.zst"
done

echo "# release assets" >> "$sums"
(cd "$OUT" && for a in "$DEVICE"-*; do
	case "$a" in "$DEVICE-SHA256SUMS") continue ;; esac
	sha256sum "$a"
done) >> "$sums"

ls -l "$OUT"/"$DEVICE"-*
