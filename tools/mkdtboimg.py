#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Pack device-tree overlays into an Android DTBO partition image.

Equivalent of AOSP's `mkdtboimg.py create <out> --page_size=4096
--id=/:board_id --rev=/:board_rev <dtbo>...`, which is how Kleaf built
dtbo.img: a dt_table_header (version 0), one dt_table_entry per overlay in
the order given, then the overlays, each 4-byte aligned. Each entry's id/rev come
from the overlay's root-node board_id / board_rev properties (0 if absent),
which the bootloader matches against the board.

Format: https://source.android.com/docs/core/architecture/dto/partitions
"""

import argparse
import struct
import sys

DT_TABLE_MAGIC = 0xD7B7AB1E
FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def root_props(blob):
    """Properties of the root node of a flattened device tree, as bytes."""
    magic, _, off_struct, off_strings = struct.unpack_from(">4I", blob, 0)
    if magic != FDT_MAGIC:
        raise ValueError("not a flattened device tree")
    strings = blob[off_strings:]
    pos, depth, props = off_struct, 0, {}
    while True:
        (tok,) = struct.unpack_from(">I", blob, pos)
        pos += 4
        if tok == FDT_BEGIN_NODE:
            end = blob.index(b"\0", pos)
            pos = (end + 4) & ~3
            depth += 1
        elif tok == FDT_END_NODE:
            depth -= 1
            if depth == 0:
                return props
        elif tok == FDT_PROP:
            length, nameoff = struct.unpack_from(">2I", blob, pos)
            pos += 8
            if depth == 1:
                name = strings[nameoff:strings.index(b"\0", nameoff)].decode()
                props[name] = blob[pos:pos + length]
            pos = (pos + length + 3) & ~3
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            return props
        else:
            raise ValueError(f"bad FDT token {tok:#x}")


def u32_prop(props, name):
    v = props.get(name)
    if v is None:
        return 0
    if len(v) != 4:
        raise ValueError(f"/{name} is {len(v)} bytes, expected a u32")
    return struct.unpack(">I", v)[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out")
    ap.add_argument("dtbos", nargs="+")
    ap.add_argument("--page-size", type=int, default=4096)
    args = ap.parse_args()

    header_size = entry_size = 32
    blobs = [open(p, "rb").read() for p in args.dtbos]
    offset = header_size + entry_size * len(blobs)
    entries = b""
    for path, blob in zip(args.dtbos, blobs):
        try:
            props = root_props(blob)
        except ValueError as e:
            sys.exit(f"{path}: {e}")
        entries += struct.pack(">8I", len(blob), offset,
                               u32_prop(props, "board_id"), u32_prop(props, "board_rev"),
                               0, 0, 0, 0)
        # Each overlay starts on a 4-byte boundary, as libufdt aligns them.
        offset += (len(blob) + 3) & ~3
    header = struct.pack(">8I", DT_TABLE_MAGIC, offset, header_size, entry_size,
                         len(blobs), header_size, args.page_size, 0)
    with open(args.out, "wb") as f:
        f.write(header + entries)
        for blob in blobs:
            f.write(blob + b"\0" * (-len(blob) % 4))


if __name__ == "__main__":
    main()
