#!/bin/bash
#
# build-mesa.sh — build the open GPU userspace (Mesa: panvk Vulkan + rusticl
# OpenCL, on the panfrost gallium driver) for the Mali-G710.
#
#   tools/build-mesa.sh fetch   <srcdir>                 clone MESA_URL at MESA_REV
#   tools/build-mesa.sh build   <srcdir> <builddir> <outdir>
#                                                        build, in an arm64 Debian trixie
#   tools/build-mesa.sh docker  <workdir>                fetch + build in an arm64
#                                                        debian:trixie container (qemu)
#   tools/build-mesa.sh pack    <outdir> <tarball>       tar an outdir for MESA_PREBUILT
#
# MESA_URL / MESA_REV come from the environment (the Makefile passes its own).
#
# Why a fork: neither upstream Mesa nor any Debian Mesa has a model entry for
# the G710 (prod id 0xa802 = Valhall arch 10.8, prod 2), so Mesa refuses the GPU
# with "Unknown GPU ID". junkyard-computing/mesa `felix-g710` adds it (the G610's
# parameters; the G710 is a G610 with more cores) and is what the org's felix
# panthor bring-up ran OpenCL on.
#
# Why build in Debian trixie: the image is trixie, so the libraries link
# against the same glibc and LLVM 19 the image ships. The output is installed
# under /usr/local (nothing here is a dpkg package), and `build` writes the
# Debian packages it needs at runtime to <outdir>/runtime-packages.txt, found
# with ldd + dpkg -S, so the image installs exactly those.
#
# <outdir> layout:
#   root/                 the install tree (DESTDIR), rooted at /
#   runtime-packages.txt  Debian packages the libraries link against
#   MESA_REV              the commit that was built
set -euo pipefail

MESA_URL="${MESA_URL:-https://github.com/junkyard-computing/mesa.git}"
MESA_REV="${MESA_REV:-}"

die() { echo "build-mesa: $*" >&2; exit 1; }

cmd_fetch() {
	local src="$1"
	mkdir -p "$src"
	git -C "$src" init -q
	git -C "$src" remote remove origin 2>/dev/null || true
	git -C "$src" remote add origin "$MESA_URL"
	git -C "$src" fetch -q --depth 1 origin "$MESA_REV"
	git -C "$src" checkout -q --force FETCH_HEAD
	git -C "$src" clean -fdxq
	[ "$(git -C "$src" rev-parse HEAD)" = "$MESA_REV" ] || die "fetched $(git -C "$src" rev-parse HEAD), wanted $MESA_REV"
}

# Build dependencies, from trixie. Headless: no X11/Wayland, no GL/EGL/GBM.
# LLVM/clang/libclc/SPIRV-LLVM-Translator are needed both by rusticl and by
# mesa_clc, which panfrost uses to precompile its internal shaders.
DEPS=(
	meson ninja-build pkg-config python3 python3-mako python3-yaml
	python3-packaging python3-ply python3-pycparser bison flex git
	ca-certificates gcc g++ rustc cargo bindgen glslang-tools
	llvm-19-dev libclang-19-dev libclang-cpp19-dev clang-19
	libclc-19-dev libclc-19 libllvmspirvlib-19-dev spirv-tools
	libdrm-dev libelf-dev zlib1g-dev libzstd-dev libexpat1-dev libudev-dev
)

cmd_build() {
	local src="$1" build="$2" out="$3"
	[ "$(dpkg --print-architecture)" = arm64 ] || die "must run on arm64 Debian (got $(dpkg --print-architecture))"
	[ -f "$src/meson.build" ] || die "no Mesa source at $src"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends "${DEPS[@]}" >/dev/null
	export PATH="/usr/lib/llvm-19/bin:$PATH"

	rm -rf "$build" "$out"
	# -Dprefix=/usr/local: Debian's own Mesa (if anything pulls it in) keeps
	#   /usr; the Vulkan loader searches /usr/local/share/vulkan/icd.d.
	# -Dsysconfdir=/etc: rusticl's ICD goes to /etc/OpenCL/vendors, the
	#   only place ocl-icd looks.
	# -Dstatic-libclc=all: no libclc .spv files needed at runtime.
	meson setup "$build" "$src" \
		-Dprefix=/usr/local -Dlibdir=lib -Dsysconfdir=/etc \
		-Dbuildtype=release -Db_ndebug=true \
		-Dgallium-drivers=panfrost -Dvulkan-drivers=panfrost \
		-Dgallium-rusticl=true -Dstatic-libclc=all \
		-Dllvm=enabled -Dshared-llvm=enabled \
		-Dplatforms= -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
		-Degl=disabled -Dgbm=disabled -Dglx=disabled -Dglvnd=disabled \
		-Dvideo-codecs= -Dgallium-va=disabled \
		-Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
		-Dmicrosoft-clc=disabled -Dbuild-tests=false
	ninja -C "$build"
	DESTDIR="$out/root" meson install -C "$build" --no-rebuild --quiet

	# Runtime packages: every shared library our binaries load that is not one
	# of our own, mapped to the Debian package that ships it.
	local libdir="$out/root/usr/local/lib"
	find "$out/root" -type f -name '*.so*' -print0 \
		| xargs -0 -r env LD_LIBRARY_PATH="$libdir" ldd 2>/dev/null \
		| awk '$2 == "=>" && $3 ~ /^\// {print $3}' \
		| grep -v "^$libdir/" | sort -u \
		| while read -r lib; do
			dpkg -S "$(readlink -f "$lib")" 2>/dev/null || dpkg -S "$lib" 2>/dev/null || echo "UNOWNED: $lib" >&2
		done | cut -d: -f1 | sort -u > "$out/runtime-packages.txt"
	if find "$out/root" -type f -name '*.so*' -print0 | xargs -0 -r env LD_LIBRARY_PATH="$libdir" ldd 2>/dev/null | grep -q 'not found'; then
		find "$out/root" -type f -name '*.so*' -print0 | xargs -0 -r env LD_LIBRARY_PATH="$libdir" ldd | grep 'not found' >&2
		die "unresolved shared libraries (above)"
	fi
	echo "$MESA_REV" > "$out/MESA_REV"
	echo "build-mesa: built $MESA_REV; runtime packages: $(tr '\n' ' ' < "$out/runtime-packages.txt")"
	find "$out/root" -type f | sed "s|^$out/root||" | sort
}

# Whole build in a throwaway arm64 trixie container (qemu-user under docker;
# the host needs binfmt for aarch64). Slow — use a native arm64 machine or the
# CI artifact (MESA_PREBUILT) when you can.
cmd_docker() {
	local work; work="$(mkdir -p "$1" && cd "$1" && pwd)"
	local here; here="$(cd "$(dirname "$0")" && pwd)"
	cmd_fetch "$work/src"
	docker run --rm --platform linux/arm64 \
		-e MESA_URL="$MESA_URL" -e MESA_REV="$MESA_REV" \
		-v "$here/build-mesa.sh:/build-mesa.sh:ro" -v "$work:/work" \
		debian:trixie /build-mesa.sh build /work/src /work/build /work/out
}

cmd_pack() {
	local out="$1" tarball="$2"
	[ -f "$out/MESA_REV" ] || die "$out is not a build-mesa outdir"
	tar -C "$out" -cf - root runtime-packages.txt MESA_REV | zstd -q -T0 -f -o "$tarball"
}

case "${1:-}" in
	fetch|build|docker) [ -n "$MESA_REV" ] || die "MESA_REV must be set (the Makefile's MESA_REV)" ;;
esac
case "${1:-}" in
	fetch)  shift; cmd_fetch "$@" ;;
	build)  shift; cmd_build "$@" ;;
	docker) shift; cmd_docker "$@" ;;
	pack)   shift; cmd_pack "$@" ;;
	*) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
