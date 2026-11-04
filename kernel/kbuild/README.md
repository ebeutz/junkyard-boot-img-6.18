# kernel/kbuild — the make-only kernel build's data

The kernel, its out-of-tree modules and the device tree are built by
[kernel/kbuild.mk](../kbuild.mk): plain kbuild, the kernel tree's own prebuilt
clang, no Bazel/Kleaf. The device-level description (defconfig fragments,
Kconfig.ext, device tree, module lists) is make variables in
`devices/<device>.mk`. This directory holds the rest.

| File | What it is |
| --- | --- |
| `<device>-modules.mk` | **Generated.** Every out-of-tree module the device ships (and the ones those depend on), in dependency order: how to build it, what it installs, which modules it needs first, the Module.symvers it consumes. Plus the DDK modules' own Kconfig/defconfig files. |
| `linus_gki_defconfig`, `linus_Kconfig.gki` | lynx's base defconfig and the `GKI_HIDDEN_*` Kconfig for Linus' tree. AOSP's, minus the ACK-only symbols (see the defconfig's header). They used to be added to `common/` by a patch. felix uses ACK's in-tree copies. |
| `linus-gki-modules.txt`, `android14-6.1-gki-modules.txt` | The GKI modules each kernel ships (system_dlkm). An in-tree module that is in neither this list nor the device's `KERNEL_VENDOR_INTREE_MODULES` is not installed, which matches Kleaf and keeps KUnit modules out of the image. |
| `linux-ddk-headers.json` | The kernel's DDK header sets (`//common:all_headers_aarch64` & co.) for the converter. Linus' tree has no BUILD.bazel to read them from. |

## Why the module Kbuild has to be generated

Most Pixel vendor modules are Kleaf `ddk_module`s. They have no Makefile or
Kbuild, only a BUILD.bazel entry, and Kleaf writes a Kbuild for each one at
build time. [tools/bazel2kbuild.py](../../tools/bazel2kbuild.py) does the same
thing once, ahead of time, without Bazel:

- it evaluates the BUILD.bazel/.bzl files as data. Kleaf rules are stubs that
  record their attributes, `select()` is resolved from the device's bazelrc
  flags, and `glob()` follows Bazel's rules.
- for every `ddk_module` it computes what Kleaf's `ddk/makefiles.bzl` and
  `gen_makefiles.py` would: sources (incl. `conditional_srcs`), `-I` and
  LINUXINCLUDE (Kleaf's preorder include depset), defines and copts, and the
  Module.symvers of its direct module deps.
- it writes one `Kbuild` per package that holds DDK modules. kbuild.mk builds
  each module in a separate make run (`DDK_MODULE=<name>`) with its own `MO=`
  output directory, as Kleaf built each module in its own sandbox. Modules
  that share a directory therefore never share flags, and their dependency
  graph needs no merging.
- it writes `<device>-modules.mk`.

Makefile-based `kernel_module`s (`soc/gs`, mali, trusty, cnss2, qcacld, bms/misc)
already have a Kbuild/Makefile. kbuild.mk runs their Makefile the way Kleaf did.
Their deps' Module.symvers is placed where those Makefiles look for it.

**Validated against Kleaf** for lynx (2026-11-04, the BUILD files at
`kernel/kernel-source.lynx.rev`). All 108 DDK modules came out identical to
Kleaf's own generated makefiles. That covers object lists and order, conditional
objects, compile flags (as the compiler sees them), LINUXINCLUDE, and
Module.symvers deps. The set of shipped modules matches too. `dtbo.img` from
[tools/mkdtboimg.py](../../tools/mkdtboimg.py) is byte-identical to Kleaf's.

## Regenerating

Run this after anything changes the vendor tree's BUILD files, such as moving
`kernel/kernel-source.lynx.rev` or `kernel/kernel-manifest.felix.xml`, or a
patch that edits a BUILD.bazel:

```
make -f kernel/kbuild.mk DEVICE=<device> kbuild-regen
```

It reads `KBUILD_GEN_*` from `devices/<device>.mk`: the root module labels
(the device's `ext_modules` / `kernel_ext_modules`), the bazelrc flags, extra
true conditions, and the kernel_build's DDK headers. It writes
`<package>/Kbuild` into the kernel tree and `kernel/kbuild/<device>-modules.mk`
here. It refuses to overwrite a Kbuild or Makefile it did not write.

The Kbuild files live in the kernel tree, so they are carried like every other
change there. Each one goes into its project's patch under
`kernel/patches-<device>/<project>/`, a cumulative diff of that project against
its pinned revision.

After regenerating, rebuild and check that every declared module was built.
kbuild.mk fails on a module whose `.outs` did not appear, and on any module
needing an unknown symbol (depmod).
