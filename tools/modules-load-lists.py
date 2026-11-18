#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Write the *.modules.load lists Kleaf's dist used to provide.

kernel/kbuild.mk installs every module into one staging tree and runs depmod
over it. From that, and the device's lists, this writes into --out:

  vendor_kernel_boot.modules.load  the device's vendor_ramdisk lists, in their
                                   order, restricted to modules that exist
  vendor_dlkm.modules.load         every other vendor module (out-of-tree and
                                   the device's in-tree ones), in build order
  system_dlkm.modules.load         the GKI modules, in --gki-list order

Each list is then reordered so a module's dependencies (modules.dep) come
before it, keeping the given order otherwise. Kleaf did the same reordering.
The rootfs build turns the three lists into dracut's --force-drivers.
Paths are relative to lib/modules/<release>/, as Kleaf wrote them.
"""

import argparse
import pathlib
import sys


def read_list(path):
    out = []
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def dep_sort(mods, deps):
    """Stable topological sort: dependencies (within `mods`) first."""
    want = set(mods)
    done, out = set(), []

    def visit(m, stack):
        if m in done:
            return
        if m in stack:
            sys.exit(f"dependency cycle through {m}")
        stack.add(m)
        for d in deps.get(m, ()):
            if d in want:
                visit(d, stack)
        stack.discard(m)
        done.add(m)
        out.append(m)

    for m in mods:
        visit(m, set())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--moddir", required=True, help="staging lib/modules/<release>")
    ap.add_argument("--ramdisk-list", action="append", default=[])
    ap.add_argument("--vendor-order", required=True,
                    help="file: vendor modules (relative paths) in build order")
    ap.add_argument("--gki-list", required=True, help="GKI modules, paths under kernel/")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    moddir = pathlib.Path(args.moddir)
    deps = {}
    for line in (moddir / "modules.dep").read_text().splitlines():
        mod, _, rest = line.partition(":")
        deps[mod] = rest.split()
    present = set(deps)

    ramdisk = []
    for f in args.ramdisk_list:
        ramdisk += [m for m in read_list(f) if m in present and m not in ramdisk]
    vendor = [m for m in read_list(args.vendor_order) if m in present and m not in ramdisk]
    gki = [f"kernel/{m}" for m in read_list(args.gki_list)]
    gki = [m for m in gki if m in present]

    out = pathlib.Path(args.out)
    for name, mods in (("vendor_kernel_boot", ramdisk), ("vendor_dlkm", vendor),
                       ("system_dlkm", gki)):
        (out / f"{name}.modules.load").write_text(
            "".join(m + "\n" for m in dep_sort(mods, deps)))


if __name__ == "__main__":
    main()
