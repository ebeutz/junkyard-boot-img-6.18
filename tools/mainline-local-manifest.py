#!/usr/bin/env python3
"""Generate kernel/local-manifests/<device>.xml for the lynx mainline tracks.

The GrapheneOS kernel_pixel_6.18 monorepo carries an aosp_manifest.xml whose
`dependencies` group (common/, kleaf, clang, rust, the bazel externals) is
pinned for a 6.18 GKI. lynx-mainline builds the same device/module tree against
AOSP kernel/common `android-mainline` instead, and android-mainline needs the
toolchain AOSP pairs it with (it pins clang/rustc versions in
common/bazel/constants.scl that the 6.18 prebuilts do not carry). So every
dependency is moved to what AOSP's `common-android-mainline` manifest uses, at
the exact SHAs recorded by the `kernel/superproject` branch of the same name.

The output is a repo LOCAL manifest: clone_kernel_source copies it into
.repo/local_manifests/, so the monorepo's own (tracked) aosp_manifest.xml is
never edited. Re-run this to move the pin:

    tools/mainline-local-manifest.py kernel/source-lynx/aosp_manifest.xml \
        > kernel/local-manifests/lynx.xml

`--common linus` (the default on the lynx-linus-mainline branch) puts Linus
Torvalds' tree at common/ instead of AOSP android-mainline, at the upstream tag
android-mainline was last rebased onto (found by walking its log for the
newest "Merge tag 'vX.Y' into android-mainline"). Everything else -- kleaf,
clang, rust, the bazel externals -- still comes from the same superproject
pin, so the toolchain is exactly the one AOSP builds that Linux release with.
`--linus-tag` overrides the tag. `--common ack` reproduces lynx-mainline.

Rules:
  * dependency in both manifests, same name -> <extend-project revision=SHA>
  * dependency in both, different name (common, zlib) -> remove + re-add
  * GrapheneOS-only dependency AOSP replaced (rust linux-x86 -> linux-musl-x86)
    -> removed; GrapheneOS-only and still needed (external/bionic) -> kept
  * AOSP ddk/ddk-external project GrapheneOS lacks -> added
  AOSP's non-ddk extras (GBL, u-boot, cuttlefish, raviole) are not added: the
  lynx dist does not build them.
"""

import argparse
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr

AOSP = "https://android.googlesource.com"
LINUS_FETCH = "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/"
LINUS_NAME = "linux"
# GrapheneOS-only dependencies with no AOSP counterpart that must be KEPT.
KEEP_GOS_ONLY = {"external/bionic"}


def fetch_manifest(branch):
    import base64
    url = f"{AOSP}/kernel/manifest/+/refs/heads/{branch}/default.xml?format=TEXT"
    with urllib.request.urlopen(url) as r:
        return ET.fromstring(base64.b64decode(r.read()))


def superproject_pins(branch, rev=None):
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(
            ["git", "clone", "-q", "--depth=1", "--filter=blob:none",
             "--no-checkout", "-b", branch, f"{AOSP}/kernel/superproject", d],
            check=True)
        if rev:
            subprocess.run(["git", "-C", d, "fetch", "-q", "--depth=1",
                            "--filter=blob:none", "origin", rev], check=True)
            subprocess.run(["git", "-C", d, "reset", "-q", "--soft", rev], check=True)
        head = subprocess.run(["git", "-C", d, "rev-parse", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
        tree = subprocess.run(["git", "-C", d, "ls-tree", "-r", "HEAD"],
                              check=True, capture_output=True, text=True).stdout
    pins = {}
    for line in tree.splitlines():
        meta, path = line.split("\t", 1)
        _mode, kind, sha = meta.split()
        if kind == "commit":
            pins[path] = sha
    return head, pins


def gitiles_json(url):
    import json
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode()[4:])  # strip the )]}' XSSI guard


def ack_upstream_tag(ack_sha):
    """Newest upstream tag merged into android-mainline at or before ack_sha."""
    import re
    pat = re.compile(r"^Merge tag '(v\d+\.\d+(?:-rc\d+)?)' into android-mainline")
    url = f"{AOSP}/kernel/common/+log/{ack_sha}?format=JSON&n=1000"
    for _ in range(20):
        d = gitiles_json(url)
        for c in d["log"]:
            m = pat.match(c["message"])
            if m:
                return m.group(1)
        if "next" not in d:
            break
        url = f"{AOSP}/kernel/common/+log/{d['next']}?format=JSON&n=1000"
    sys.exit(f"no upstream tag merge found below android-mainline {ack_sha}")


def tag_commit(tag):
    out = subprocess.run(
        ["git", "ls-remote", "--tags", LINUS_FETCH + LINUS_NAME, f"refs/tags/{tag}^{{}}"],
        check=True, capture_output=True, text=True).stdout.split()
    if not out:
        sys.exit(f"tag {tag} not found in {LINUS_FETCH}{LINUS_NAME}")
    return out[0]


def attrs(**kw):
    return " ".join(f"{k.replace('_', '-')}={quoteattr(v)}" for k, v in kw.items() if v)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("gos_manifest", help="the monorepo's aosp_manifest.xml")
    ap.add_argument("--branch", default="common-android-mainline",
                    help="AOSP kernel/manifest + kernel/superproject branch")
    ap.add_argument("--superproject-rev",
                    help="pin to this kernel/superproject commit instead of the branch tip "
                         "(the one recorded in the current output's header keeps every "
                         "toolchain pin where it is)")
    ap.add_argument("--common", choices=("linus", "ack"), default="linus",
                    help="what goes at common/: Linus' tree (default) or AOSP android-mainline")
    ap.add_argument("--linus-tag",
                    help="Linus tag for common/ (default: the one android-mainline last merged)")
    a = ap.parse_args()

    gos = ET.parse(a.gos_manifest).getroot()
    aosp = fetch_manifest(a.branch)
    sp_head, pins = superproject_pins(a.branch, a.superproject_rev)
    adefault = aosp.find("default").get("revision")

    gdeps = {p.get("path"): p for p in gos.iter("project")
             if "dependencies" in (p.get("groups") or "").split(",")}
    adeps = {p.get("path"): p for p in aosp.iter("project")}

    out = []
    w = out.append
    w('<?xml version="1.0" encoding="UTF-8"?>')
    w("<!--")
    w("  GENERATED by tools/mainline-local-manifest.py — do not edit by hand.")
    w(f"  AOSP kernel/superproject {a.branch} @ {sp_head}")
    w("")
    if a.common == "linus":
        tag = a.linus_tag or ack_upstream_tag(pins["common"])
        tag_sha = tag_commit(tag)
        w(f"  common/: Linus Torvalds' linux.git {tag} ({tag_sha}),")
        w(f"  the upstream base of android-mainline {pins['common']}.")
    w("")
    w("  repo local manifest layered on the GrapheneOS monorepo's aosp_manifest.xml")
    w("  (clone_kernel_source copies it to .repo/local_manifests/). Moves common/ to")
    if a.common == "linus":
        w("  Linus' tree and every other `dependencies` project to the revision AOSP's")
        w("  common-android-mainline uses. See devices/lynx.mk.")
    else:
        w("  AOSP kernel/common android-mainline and every other `dependencies` project")
        w("  to the revision AOSP's common-android-mainline uses. See devices/lynx.mk.")
    w("-->")
    w("<manifest>")
    if a.common == "linus":
        w(f"  <remote {attrs(name='kernelorg', fetch=LINUS_FETCH)}/>")

    def add(ap_, path):
        if path == "common" and a.common == "linus":
            # Shallow: the history is ~5 GB and nothing here walks it.
            # upstream= names the ref the SHA is fetched through, since
            # --current-branch would otherwise fetch the default branch.
            w(f"  <project {attrs(name=LINUS_NAME, path=path, remote='kernelorg', groups='dependencies', revision=tag_sha, upstream='refs/tags/' + tag, dest_branch='refs/tags/' + tag, clone_depth='1')}>")
            for lf in list(gdeps[path]):
                if lf.tag in ("linkfile", "copyfile"):
                    w(f"    <{lf.tag} {attrs(src=lf.get('src'), dest=lf.get('dest'))}/>")
            w("  </project>")
            return
        rev = pins.get(path)
        if not rev:
            sys.exit(f"no superproject pin for {path}")
        up = ap_.get("revision") or adefault
        groups = ",".join(["dependencies"] + [g for g in (ap_.get("groups") or "").split(",") if g])
        w(f"  <project {attrs(name=ap_.get('name'), path=path, remote='aosp', groups=groups, revision=rev, upstream=up, dest_branch=up, clone_depth=ap_.get('clone-depth'))}>")
        for lf in list(gdeps[path]) if path in gdeps else []:
            if lf.tag in ("linkfile", "copyfile"):
                w(f"    <{lf.tag} {attrs(src=lf.get('src'), dest=lf.get('dest'))}/>")
        w("  </project>")

    for path, gp in sorted(gdeps.items()):
        if path in adeps:
            ap_ = adeps[path]
            if ap_.get("name") == gp.get("name"):
                up = ap_.get("revision") or adefault
                w(f"  <extend-project {attrs(name=gp.get('name'), revision=pins[path], upstream=up, dest_branch=up)}/>")
            else:
                w(f"  <remove-project {attrs(name=gp.get('name'))}/>")
                add(ap_, path)
        elif path in KEEP_GOS_ONLY:
            w(f"  <!-- {path}: GrapheneOS-only, kept at the monorepo's pin -->")
        else:
            w(f"  <remove-project {attrs(name=gp.get('name'))}/>")
    for path, ap_ in sorted(adeps.items()):
        if path not in gdeps and "ddk" in (ap_.get("groups") or ""):
            add(ap_, path)
    w("</manifest>")
    print("\n".join(out))


if __name__ == "__main__":
    main()
