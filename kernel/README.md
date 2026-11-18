# kernel/

Everything that turns a pinned kernel source into the kernel, modules and
device tree the image ships. The build is plain make/kbuild with the clang
prebuilt the source pins. There is no Bazel/Kleaf.

The kernel source for each device is a checkout at `kernel/source-<device>/`.
The build output goes to `kernel/source-<device>/out/<device>/`. Both are
gitignored. This directory holds what is committed: the pins, the patches, the
config fragments and the build itself.

## Layout

| Path | What it is |
| --- | --- |
| [kbuild.mk](kbuild.mk) | The kernel build: config, Image, in-tree and out-of-tree modules, dtbs, and a `dist/` with the layout Kleaf's dist had. Its header explains how the Kleaf model maps onto one make build. |
| [kbuild/](kbuild/) | The build's data: the generated per-device module lists (`<device>-modules.mk`), lynx's base defconfig and `Kconfig.gki`, the GKI module lists, and the converter's inputs. See [kbuild/README.md](kbuild/README.md). |
| [custom_defconfig_mod/](custom_defconfig_mod/) | This repo's config fragments. `custom_defconfig` is shared. `<device>_cmdline_defconfig` sets `CONFIG_CMDLINE`, because the GKI base string differs between kernels. They merge last, so they win. |
| [patches/](patches/) | Patches shared by both devices: SoC-level (gs201) or AOSP-common. The path under `patches/` names the project they apply to. [patches/README.md](patches/README.md) documents every patch and the lynx driver port. `rejected/` holds patches that were measured not to work and are never applied. |
| [patches-lynx/](patches-lynx/) | lynx-only patches. `common/` patches the Linux tree (one patch). `private/` is the gs201 driver port: one cumulative patch per monorepo project, including the generated module Kbuild files. |
| [kernel-source.lynx.rev](kernel-source.lynx.rev) | The GrapheneOS monorepo commit lynx builds. |
| [kernel-manifest.felix.xml](kernel-manifest.felix.xml) | The pinned `repo` manifest felix builds. |
| [local-manifests/felix.xml](local-manifests/felix.xml) | Removes the projects only Kleaf/Bazel used (kleaf, bazel, JDK, build-tools, …) from felix's `repo` checkout. |

The per-device description lives outside this directory, in
[devices/&lt;device&gt;.mk](../devices/): source pins, base defconfig and
fragments, Kconfig.ext files, device tree, the in-tree modules the device
ships, and the vendor_ramdisk lists.

## The two kernels

| | felix | lynx |
| --- | --- | --- |
| Kernel | ACK android14-6.1 (`aosp/`) | Linus' tree at `v7.3` (`common/`) |
| Vendor code | AOSP `repo` manifest, branch `android-gs-felix-6.1-android16` | GrapheneOS [kernel_pixel_6.18](https://gitlab.com/grapheneos/kernel_pixel_6.18) monorepo |
| Fetched with | `repo`, the local manifest, [sparse-prebuilts.sh](../tools/sparse-prebuilts.sh) | plain git: the monorepo, the kernel tag (checked against its SHA), and a sparse partial clone of one clang release |
| clang | r487747c | r596125 |
| Release | `6.1.124-android14-11-g<sha>` | `7.3.0-linus-4k` |
| Base defconfig | ACK's `gki_defconfig` | [kbuild/linus_gki_defconfig](kbuild/linus_gki_defconfig) |
| Vendor modules | Makefile-based `kernel_module`s | mostly DDK modules, built from generated Kbuild |
| Module signing | off | each module signed with the build's own key |

## Building

The normal entry point is the device build (`just felix`, `just lynx`), whose
`.build_kernel` stage runs:

```shell
make -f kernel/kbuild.mk DEVICE=<device> dist
```

and then writes the release to `kernel/kernel_version.<device>`. That file
sets every `/lib/modules/<ver>/` path downstream, so the rootfs stages need
it to be current.

| Command | Does |
| --- | --- |
| `just device=<dev> clone_kernel_source` | Fetch the source at its pins. |
| `just device=<dev> build_kernel` | Apply the patches and build the kernel. |
| `just device=<dev> config_kernel` | Run `nconfig` on the build's config and print the defconfig diff. Copy what you want into a fragment. |
| `just device=<dev> clean_kernel` | Delete `out/<device>/` and drop the kernel sentinels. |
| `just device=<dev> pin_kernel_source` | Write the current checkout's revision to the pin file. Commit it. |
| `make -f kernel/kbuild.mk DEVICE=<dev> kbuild-regen` | Regenerate the module Kbuild files and `kbuild/<device>-modules.mk` after the vendor BUILD files change. |
| `tools/kernel-drift.sh` | Check that the kernel tree differs from its pinned revision by exactly the patch set, with no uncommitted work. |

The kernel stage uses the build host's tools (flex, bison, `libssl-dev`,
`libelf-dev`, `libdw-dev`, pahole ≥ 1.27, …). On NixOS, run it in the flake's
FHS env:

```shell
nix run .#kernel-fhs -- -c 'just device=<dev> build_kernel'
```

## Making changes

- **A config option:** add it to
  [custom_defconfig_mod/custom_defconfig](custom_defconfig_mod/custom_defconfig).
  Put an option that only one kernel has in that device's fragment. The build
  checks every value a fragment asks for against the final `.config`, so a
  silently dropped option (a missing dependency, a renamed symbol) fails the
  build.
- **A patch:** add it under `patches/<project>/` (both devices) or
  `patches-<device>/<project>/` (one device). A patch that neither applies nor
  is already applied stops the build. On lynx, prefer fixing the out-of-tree
  module over patching the Linux tree; [patches/README.md](patches/README.md)
  explains the rule and the techniques.
- **Moving a pin:** change the pin file or the `KERNEL_LINUX_*`/`KERNEL_CLANG_*`
  values in `devices/<device>.mk` (those four move together), run
  `kbuild-regen` if the vendor BUILD files changed, then rebuild the kernel
  and the rootfs.

## Status

Both kernels build. lynx's output matches the last Kleaf build's: the same
modules in each archive and load list, and byte-identical dtbs, `dtb.img` and
`dtbo.img`. felix is checked only by the build's own checks, since there is
no Kleaf felix build here to compare against. Neither kernel has been
booted.
