# Kernel-tree patches

Patches against the **repo-managed** AOSP kernel checkout under `kernel/source/`.

## Why this directory exists

`kernel/source/` is a `repo` checkout and `kernel/source/.gitignore` ignores
**everything**, so nothing edited in there is tracked by this repo. A `repo
sync`, a fresh clone, or `just clone_kernel_source` silently reverts any local
edit — and the build then succeeds against the *unpatched* tree with no error.
That is the same failure shape as the sentinel/gitlink gotchas in CLAUDE.md:
the build reports success while quietly losing a capability.

Kconfig changes already have a home that survives syncs
(`kernel/custom_defconfig_mod/`, wired in via `--defconfig_fragment`). **Device
tree changes have no such mechanism**, so they are kept here as patches.

## Layout

```
kernel/patches/<repo-project-path>/NNNN-name.patch
```

e.g. `kernel/patches/private/devices/google/gs201/0001-….patch`.

`repo` makes each project its own git, so one `git apply` cannot span them. The
directory under `kernel/patches/` names the project the patch is applied
**inside**, and each patch is `-p1` relative to that project root — i.e.
generate it with `git diff` from within the project directory.

## These ARE applied automatically

The `.apply_kernel_patches` make stage applies everything here, and
`.build_kernel` depends on it, so a normal build is patched with no extra step.

- **Idempotent** — already-applied patches are detected via
  `git apply --check --reverse` and skipped.
- **Fail-loud** — a patch that neither applies nor is already applied *aborts
  the build*. A kernel patch that silently no-ops is the exact failure this
  stage exists to prevent.
- **Survives syncs** — `clone_kernel_source` deletes `.apply_kernel_patches`
  (and `.build_kernel`) after `repo sync`, because a sync reverts the tree and a
  stale sentinel would otherwise mean quietly building an unpatched kernel.
- `just apply_kernel_patches` runs the stage alone, without building.
- `just clean_kernel` drops the sentinel too.

To force a rebuild after adding or editing a patch, the dependency does it for
you (the sentinel is older than the patch file). To rebuild by hand:

```sh
rm -f .build_kernel .install_kernel .install_initramfs .build_boot
nix run .#bazel-fhs -- -c "make .build_kernel BAZEL=$(pwd)/kernel/source/tools/bazel"
tools/dockershell just update_kernel_modules_and_source update_initramfs build_boot_images
```

Two invocation traps worth knowing:

- `make .build_kernel` alone fails — `$(BAZEL)` is repo-relative but the recipe
  `cd`s into `kernel/source` first, hence the absolute `BAZEL=` above.
- Do **not** call `make .install_kernel` directly: `KERNEL_VERSION` is exported
  by the justfile, not defined in the Makefile, so it expands empty, every path
  becomes `lib/modules//…`, and the `find … -name '*.ko' -delete` in that recipe
  hits the whole module tree. Go through the `just` targets.

## Device-only patches: `kernel/patches-<device>/`

Same layout and the same apply rules, but only applied to that device's tree
(`PATCH_FILES` in the Makefile picks up `kernel/patches-$(DEVICE)/` alongside
this directory). Use it for a patch that is valid for one device's kernel
branch only.

**`kernel/patches-lynx/` is the gs201 port to Linux 6.18.** lynx builds
GrapheneOS's `kernel_pixel_6.18` monorepo (see `devices/lynx.mk`), whose gs201
drivers were never ported past the 6.1 tree. Each patch under it is one AOSP
`repo` project from that monorepo's `aosp_manifest.xml`; the directory names the
project and the patch applies with `git apply --directory=<project>` from the
monorepo top, since inside the monorepo the project is a subdirectory, not its
own git. `aosp/` is the ACK `common/` tree (its own git, as on felix).

Most of it is mechanical API migration (callback signatures, renamed helpers,
the 6.18 thermal/IOMMU/V4L2/UFS/DRM driver interfaces). Each patch header lists
the changes it contains. The non-mechanical decisions are called out in their
own headers:

- `private/devices/google/gs201/0001-…`: pKVM S2MPU and GSA pKVM are turned
  off. They target the 6.1 pKVM module ABI, which ACK 6.18 replaced, and the
  images boot `kvm-arm.mode=nvhe` anyway.
- `aosp/0001-…`, `aosp/0002-…`: GKI exports that the 6.1 Android GKI had and
  that 6.18 lacks (`init_ipc_ns`/`put_ipc_ns` for rust_binder with IPC_NS on,
  `dma_direct_alloc`/`dma_direct_free` for the WCN6740 driver).
- `private/google-modules/aoc/0001-…`: keeps Laguna's arm-smmu-v3 package out
  of the gs201 dependency graph.
- `private/google-modules/soc/gs/…`: `samsung_iommu.ko` provides the same
  `pixel_iommu_{,un}register_fault_handler()` registry that Laguna's
  arm-smmu-v3 package does, replacing the removed
  `iommu_register_device_fault_handler()` for every gs201 SysMMU client.

**None of this has been run on hardware.** It compiles, links and passes
modpost; that is all it has been shown to do.

### lynx-mainline: the same tree on AOSP `android-mainline`

On the `lynx-mainline` branch, lynx's GKI is AOSP `kernel/common`
`android-mainline` (Linux 7.3 at the pin) instead of GrapheneOS's
`kernel_common-6.18`, and kleaf + every toolchain prebuilt move to the
revisions AOSP's `common-android-mainline` uses. That swap is a repo local
manifest, [`kernel/local-manifests/lynx.xml`](../local-manifests/lynx.xml),
generated by [`tools/mainline-local-manifest.py`](../../tools/mainline-local-manifest.py)
and installed by `clone_kernel_source`. The GrapheneOS monorepo itself is
pinned in `kernel/kernel-source.lynx.rev`, because the patches below are cut
against that exact commit.

**One patch per project, still.** Each monorepo project that the mainline
port touched carries a single cumulative
`0001-<project>-port-to-android-mainline.patch` (6.1 → android-mainline);
its header keeps the original 6.1 → 6.18 description and adds a
"6.18 → android-mainline" section. Projects the mainline port did not touch
keep their `…-port-to-linux-6.18.patch` unchanged. They are not stacked as
0001 + 0002 on purpose: both the apply stage's "already applied" test and
`tools/kernel-drift.sh` check each patch on its own (`git apply --check
[--reverse]`), and a second patch rewriting lines of the first makes the
first look neither applied nor applicable. To see exactly what mainline
needed, diff against the 6.18 branch:
`git diff main..lynx-mainline -- kernel/patches-lynx/`.

New patch locations:

- `build/kernel/0001-…`: kleaf's DDK config step no longer appends a
  `source` for a Kconfig the inherited `Kconfig.ext` already sources.
  android-mainline's kconfig rejects a repeated `source`, which 6.18
  tolerated, and the gs201 `Kconfig.ext` sources touch/common and
  radio/s5300 that DDK modules also declare.
- `private/devices/google/common/0001-…`: no KMI symbol list (mainline has
  none and does not trim), `pahole` for `kernel_build()`, and
  `build.config.constants` → `bazel/constants.scl`.

**Restore, don't rewrite, where the vendor tree depends on removed core API.**
For things android-mainline deleted that the vendor code uses at many sites,
or in ways whose semantics a blind rewrite could change, the GKI gets the old
interface back as a separate `aosp/` patch, rather than every caller being
edited:

- `aosp/0003`: `strncpy()` (removed upstream in 079a028d6327; ~60 vendor
  callers, each a padding/termination decision).
- `aosp/0004`: the `power:clock_*` tracepoints (de6fdc076d39; ~90 callers),
  now exported.
- `aosp/0005`: the Pixel TCPM layer GrapheneOS's 6.18 GKI carries
  (`tcpm_update_sink_capabilities()`, the three `android_vh_typec_*` hooks),
  needed by the USB-C port controller driver.
- `aosp/0006`: exports GrapheneOS had and mainline doesn't (`plist_add/del`,
  `seq_put_decimal_ull_width`, the cma/vmscan/workqueue tracepoints
  registered by vendor modules).
- `aosp/0001` (the `init_ipc_ns`/`put_ipc_ns` export) is **gone**: Rust Binder
  is built in on android-mainline (`CONFIG_ANDROID_BINDER_IPC_RUST=y`).
  `aosp/0002` lost its symbol-list hunk.

Everything else is ported in the vendor patches (API renames, signature
changes). **The behavioural decisions**, which are worth reviewing, are
spelled out in the soc/gs and gs201 patch headers:

- **Dropped modules** (off in `gs201_defconfig`, out of `BUILD.bazel` and
  the vendor ramdisk list). These are built on ACK-only vendor infrastructure
  android-mainline does not have (task_struct vendor area, Binder internals,
  the cgroup/fs/mm/thermal/iommu hooks, `__GFP_CMA`, the zram Android
  ioctls): `vh_sched` (+ `sched_tp`, `vh_preemptirq_long`), `vh_fs`,
  `vh_cgroup`, `vh_thermal`, `pixel_em`, `pixel_metrics`, `smra`,
  `iovad-vendor-hooks`, `ufs-pixel-fips140`, `zram_gs` + `zcomp_cpu` /
  `zcomp_eh`. They are Android performance, statistics and compliance
  features. modpost shows nothing else depends on them, and GKI's upstream
  `zram.ko` still ships.
- **Kept with fenced hooks**: `vh_mm`, `pixel_stat_mm` and the AOC USB
  hooks. Registrations of hooks android-mainline lacks are wrapped in
  `#if 0  /* junkyard (lynx-mainline): … does not exist in android-mainline */`.
  `pixel_stat_mm` stores its two per-task timestamps in
  `task_struct.android_vendor_data1[]` instead of `vh_sched`'s
  `vendor_task_struct`.
- **kbuild dropped `EXTRA_CFLAGS`.** mali passes every `-DCONFIG_MALI_*`
  that way, so its features were silently compiled out while the build still
  succeeded. Fixed with `ccflags-y += $(EXTRA_CFLAGS)` in mali, bms/misc,
  trusty and the soc/gs backlight Kbuild. **If you add an out-of-tree module
  to the lynx-mainline build, grep it for `EXTRA_CFLAGS`.**
- UFS FIPS 140 is off, so the plain inline-crypto `fill_prdt` path is
  registered. The PCIe RC driver's link wait is made non-fatal by reporting
  Detect.Quiet while the link is down.

Like the 6.18 port: **builds, links, passes modpost and produces a full
`lynx/dist`; not run on hardware.**

### lynx-linus-mainline: the same tree on Linus' tree

On the `lynx-linus-mainline` branch, lynx's "GKI" is Linus Torvalds'
`linux.git` at `v7.3` (the upstream base of the android-mainline pin
lynx-mainline used) instead of an Android Common Kernel. The local manifest
([`kernel/local-manifests/lynx.xml`](../local-manifests/lynx.xml), still
generated by `tools/mainline-local-manifest.py`, now with `--common linus`)
puts `torvalds/linux` at `common/`; kleaf and the toolchains stay at the same
AOSP superproject pin.

**The rule: patch the Linux tree only for build plumbing; fix everything else
in the out-of-tree modules.** android-mainline at the pin is Linus' v7.3 plus
519 files of ACK delta (vendor hooks, ~260 exports, ACK-only headers, struct
fields and Kconfig). The vendor port from lynx-mainline already covers the
upstream API churn up to 7.3, so what had to change is exactly the vendor
code's use of that delta.

#### Linux-tree patches (`kernel/patches-lynx/common/`)

None of them changes kernel code. That is the whole Linux-side diff, plus the
shared `kernel/patches/aosp/0003` (kobject_uevent).

| patch | what | why |
|---|---|---|
| `0001-kleaf-gki-build-glue-for-linus-tree` | new files: `BUILD.bazel`, `bazel/{constants.scl,modules.bzl,modules_private.bzl}`, `arch/arm64/configs/gki_defconfig`, `Kconfig.ext`, `init/Kconfig.gki` | kleaf and the device build need `//common:kernel_aarch64` & co; taken from AOSP and trimmed (see the patch header for every deviation) |
| `0002-kbuild-hooks-kleaf-mixed-builds-rely-on` | `Kconfig`, `init/Kconfig`, `Makefile`, `scripts/Makefile.{modpost,modinst,dtbs}`, `scripts/headers_install.sh`, `kernel/gen_kheaders.sh` | the exact AOSP hunks for `KCONFIG_EXT_PREFIX`, `KBUILD_MIXED_TREE`, extmod `modules.order.*` and `headers_install` (kleaf runs both for every external module), out-of-tree dts and kleaf's symlinked sandbox |
| `0003-tty-serial-samsung-build-without-arch-exynos` | one `depends on` line | built-in `samsung_tty` for `earlycon=exynos4210`, without pulling in upstream Exynos clk/pinctrl/MCT drivers that collide with the vendor ones |

`gki_defconfig` choices that replace ACK Kconfig patches:
- `ARCH_QCOM` is off: upstream's selects `HAVE_SHARED_GPIOS`, which turns on built-in shared-GPIO proxying, and ACK deletes that select.
- `MEDIA_SUPPORT_FILTER=y`: ACK un-hides the per-category media prompts instead.
- `kcflags` is empty in both `common/BUILD.bazel` and `device_build.bzl`, so `__ANDROID_COMMON_KERNEL__` is not defined. mali and qcacld test it to choose ACK-only code paths.

lynx-mainline's `aosp/0002`–`0006` (dma-direct exports, restored
`strncpy()`, `power:clock_*` events, the Pixel TCPM layer, extra exports) are
gone; their users are handled below.

#### How the modules were ported

`IS_ENABLED(CONFIG_ANDROID_VENDOR_HOOKS)` is used throughout as "built against
an ACK", so each change keeps the ACK path compiling. Changes are marked
`junkyard (lynx-linus-mainline)` in the source.

**Compatibility headers**, all in `soc/gs/include/linus-compat/` (the
`//private/google-modules/soc/gs:linus_compat_headers` target). Every DDK
module gets the directory via the device `kernel_build`'s `ddk_module_headers`,
and Kbuild modules get it via `soc/gs/Makefile.include` or an explicit `-I`.
It is always searched *after* the kernel's `include/`:
- `linux/of_gpio.h`, which ~150 vendor files include. `of_get_named_gpio()` is rebuilt on `of_parse_phandle_with_args()` + `gpio_device_find_by_fwnode()`, using the standard two-cell xlate.
- `linux/wakeup_reason.h`: no-op stubs. Upstream's `/sys/power/pm_wakeup_irq` still reports the wake IRQ.
- `soc/google/linus-compat.h`, force-included in soc/gs and included by a few other files, covers interfaces upstream itself removed. `strncpy()` keeps its exact old semantics. `trace_clock_set_rate()` becomes a no-op. `cpumap_print_to_pagebuf()` is reproduced.
- `soc/google/kernel-tracepoint.h` attaches to core tracepoints that aren't exported (`sched_switch`, `device_pm_callback_*`, `workqueue_execute_*`) by looking them up with `for_each_kernel_tracepoint()`, with a compile-time probe prototype check.
- `soc/google/sched-setscheduler.h`: `sched_setscheduler[_nocheck]()` via the exported `sched_setattr_nocheck()`, keeping each thread's RT priority.
- `soc/google/perf-read-local.h`: `perf_event_read_local()` for the per-CPU counters of the memlat governors.
- `soc/google/psy-reference-array.h`: `power_supply_get_by_reference_array()` for bms and bcl, rebuilt on `power_supply_for_each_psy()`.
- `soc/google/samsung-dma-heap.h` (below).

**Ported to an upstream mechanism:**
- UFS inline crypto: FMP software-keys mode now fills PRDTs through ufshcd's `.fill_crypto_prdt` variant op (upstream since 6.10), instead of `android_vh_ufs_fill_prdt`. `use_kdn` defaults to 0 because KDN hardware-wrapped keys need the keyslot in the PRDT, which the upstream op does not pass, plus GSA key restore on resume. KDN mode disables inline crypto rather than half-working.
- CPU idle tracking in `gs_perf_mon`, `arm-memlat-mon` and `hardlockup-debug`: the exported `power:cpu_idle` tracepoint instead of `android_vh_cpu_idle_{enter,exit}`.
- The dma-heap in-kernel API (`dma_heap_find`/`_buffer_alloc`/`_put`/`_get_dev`): every heap the drivers allocate from in-kernel is one `samsung_dma_heap.ko` registers. It keeps its own heap list and exports `samsung_dma_heap_find()`/`_buffer_alloc()`, which MFC, exynos_drm_gem, mali PMA and lwis now use. Each heap gets a faux device for cache maintenance instead of the dma-heap chardev. ACK's `dma_buf_attachment::dma_map_attrs` (importers asking for `DMA_ATTR_PRIVILEGED` etc.) becomes `samsung_dma_buf_attach_{,set_}attrs()`, kept in the heap's own per-attachment data (users: MFC, smfc, gcip-iommu, bigo). The setter is a no-op on any other exporter's buffer.
- WLAN `dma_direct_alloc()`: `CONFIG_WCN_USE_DMA_DIRECT` is off. pcie_1 has no sysmmu, so `dma_alloc_attrs()` is dma-direct anyway.
- `max77759,extbst-ctl`: DT property renamed to `-gpios`, replacing ACK's gpiolib-of rename quirk.
- CRC8 for GBMS: a hidden `GOOGLE_BMS_CRC8` in `bms/misc/Kconfig` selects it, so the device build makes Linus' own `lib/crc/crc8.ko` (added to `GS201_MODULE_OUTS`). The ACK GKI happens to build CRC8 in.
- qcacld cfg80211 cookies: since v7.3 cfg80211 assigns the remain-on-channel/mgmt-tx cookie (`u64 cookie`), and ACK reverts this. The ops now record driver-id → cfg80211-cookie, and `os_if/p2p` translates in the ready-on-channel/expired/tx-status events and in cancels.

**Rebuilt locally from exported API** (each a short copy of upstream's code, under a `jy_` name):
`dw_handle_msi_irq` (PCIe MSI demux), `vm_unmapped_area` (mali, on the maple
tree), `thermal_cdev_update` (in `gs_thermal_compat.h`), `drm_mode_convert_to_umode`,
`power_supply_get_by_reference_array` (bms), `ufshcd_is_scsi_cmd`,
`cpuidle_governor_latency_req` (device QoS half, via `dev_pm_qos_read_value()`),
`seq_put_decimal_ull_width`, `thread_group_cputime_adjusted`/`nsec_to_clock_t`
(kernel-top), `POWER_SUPPLY_CHARGE_TYPE_TAPER_EXT` (same value, 50).
`dump_backtrace` → `dump_stack_lvl`/`sched_show_task`;
`kthread_set_per_cpu` dropped (the thread is already bound); single
`strncpy`/`sched_setscheduler` sites outside soc/gs converted to
`strscpy_pad`/`sched_set_fifo_low`.

**Compiled out (ACK infrastructure with no upstream counterpart).** Each is a stats, debug or tuning feature:
- exynos-cpupm's next-timer input: cluster/system power-down from idle is never chosen, but per-core idle still works.
- the ufs-pixel per-command stats, command log and WriteBooster group tagging, plus the pixel UFS sysfs nodes that need the unexported UPIU query helpers. Upstream's `ufs-sysfs` has the same device state.
- the exynos-ufs vendor AH8 error interrupt.
- the watchdog's RT-load stat, the debug-snapshot IPI-stop context save, sysrq-hook's custom panic message, and the hardlockup task dump.
- pixel-reboot's record of the `hw_protection_shutdown` reason, and the modem's WF_ANDROID_VENDOR wake hint.
- pixel_stat_mm's CMA and direct-reclaim latency stats. The module stays, because the GPU and heaps use its meminfo registration.
- vh_mm's per-CMA sysfs nodes.
- `debug-snapshot-debug-kinfo.ko`, which is not built: it extends ACK's `debug_kinfo`.
- GrapheneOS's `tcpm_update_sink_capabilities()` has two users. In TCPM, alternate modes are no longer ignored while the USB data path is disabled. In bms, PPS direct-charging PDO updates return `-EOPNOTSUPP`, so charging uses the DT sink PDOs.
- goodix touch's `irq_info` prints `disable-depth:n/a`, because `irq_to_desc()` is unexported.

qcacld's `wlan_osif_features.h` used `__ANDROID_COMMON_KERNEL__` as "cfg80211 has the MLO `link_id` APIs". It now also accepts any ≥6.0 kernel, which keeps the feature set it had on android-mainline.

Like everything before it on lynx: **builds, links, passes modpost and produces
a full `lynx/dist`; not run on hardware.**

## Verifying a DT patch actually landed

Three traps, each of which produced a wrong answer once:

1. **The felix `&udc` node lives in the OVERLAYS, not the base dtb.** Check
   `dtbo.img`, not `dtb.img` — and always alongside a *control* property known
   to be present (`dis-u1-entry-quirk`), which is likewise absent from
   `dtb.img`. **A `&udc` change requires reflashing the `dtbo` partition.**
2. **`find /proc/device-tree -name '*foo*'` does not work here** — it returns 0
   hits even for properties that are demonstrably live. Use
   `grep -ac <prop> /sys/firmware/fdt` on the device instead.
3. **Never trust the build's exit code alone** — piping a build through `tail`
   masks a failed `make`. Check artifact mtimes and expected strings.

## Patches

### 0001-gs201-dwc3-parkmode-disable-ss-quirk.patch

Adds `snps,parkmode-disable-ss-quirk` to the felix `&udc/dwc3` node.

**Status: PARTIAL MITIGATION, not a fix.** Sustained host-mode ingest above
~90 Mb/s kills the xHCI host controller outright (`HC died; cleaning up`),
taking the dongle and the only network path with it. With this quirk the
identical flood survived 91 s instead of 15–19 s — roughly 6× better, but it
still dies. The mainline gs201 port survives the same flood indefinitely and
sets this quirk; the AOSP DT never did, though the AOSP dwc3 core does read the
property (`drivers/usb/dwc3/core.c`).

Ship the `flash-ssh.sh` rate cap (`SCP_RATE_KBIT`, default 80 Mb/s) as the
actual protection until the host-controller bug is properly fixed. Remaining
suspect: the vendor `xhci-exynos.c` module, which mainline does not have at all.

See the `project_felix_xhci_hc_died_under_load` note for the full measurement.
