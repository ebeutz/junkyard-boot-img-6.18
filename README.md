# lynx images: 1.7.1-g47df1bd

Build outputs only; the code is on [`lynx-grapheneos-6.18`](../../tree/lynx-grapheneos-6.18) (built from commit 47df1bd). The images are stored with Git LFS, so clone with `git lfs` installed, or use GitHub's download button on each file.

Debian rootfs + GrapheneOS Linux 6.18 kernel for **lynx (Pixel 7a, gs201)**.

> [!WARNING]
> **Built, not booted.** The kernel compiles, links and passes modpost, and the images were checked on disk, but none of this has been run on hardware. The gs201 vendor drivers were ported from 6.1 to 6.18 for this build (`kernel/patches-lynx/`); expect boot-time issues.

- Kernel: `6.18.38-android17-5-gb4196b0d350e-4k` (GrapheneOS `kernel_pixel_6.18` + `kernel_common-6.18` b4196b0d, plus `kernel/patches-lynx/`)
- Image version: `1.7.1-g47df1bd+k6.18.38-android17-5-gb4196b0d350e-4k` (built from 47df1bd)
- Modules: 357, re-signed with the GKI key (`CONFIG_MODULE_SIG_FORCE=y`); initramfs carries `aoc.bin`, UFS, r8152 and the `90rootfs-flash` hook
- Login: `kalm`, password `0000`, plus the keys in `rootfs/authorized_keys`

Not in this build:
- pKVM S2MPU / GSA pKVM are off (images boot `kvm-arm.mode=nvhe`)
- mali page migration is off

## Files

| File | Use |
|---|---|
| `boot.img` | kernel |
| `vendor_boot.img` | dtb + dracut initramfs |
| `dtbo.img` | lynx board overlays (**must be flashed**) |
| `super.img.zst` | full `super` (both halves seeded), for fastboot |
| `rootfs.img.zst` | one rootfs half, for the SSH/OTA path |
| `SHA256SUMS` | checksums of the files above, plus the uncompressed images |

Download everything into one directory, `zstd -d *.zst`, then from a checkout of `lynx-grapheneos-6.18`:

```
DEVICE=lynx IMAGE_DIR=<dir> DTBO=<dir>/dtbo.img ./flash-fastboot.sh <serial>
```

## SHA256

```
54c0a67d884299369d1205b011b0c30e0c895cc64604765781fb88a8f6dfcadc  boot.img
c2905c628637f5e87758ff69e81c69ae4922437d287893cbcbd65549e316b136  vendor_boot.img
6c41f9ae9df377e3f2610e869f36941fde269cf29d87cd2a2d1478314c1205bb  dtbo.img
8aed3edf036501c5d5356f2ce8379b8b96119830c6c2780e638f62bedea0645e  rootfs.img.zst
54ad5713614b3c859ecfc8d6d770409465bb0d29d5af1f904ef6a67791b79bed  super.img.zst
1e98e4854591dc6a1eadd76de4994d9d712dbddbd20c0f8c01a2c6153289986f  kernel_version.txt
# uncompressed: cfb45fb905a58d9d6ad2c5d82f0ed70b825ce17f0b7e73286bda6dc0462afc6e  rootfs.img
# uncompressed: 5e19343826e1e53392491fee378ff183da392c794ed43e4c82804b97290c24fb  super.img
```
