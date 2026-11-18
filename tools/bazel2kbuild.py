#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""bazel2kbuild: describe a Pixel kernel's out-of-tree modules as plain Kbuild.

The Pixel kernel trees describe their vendor modules only in Kleaf's
BUILD.bazel files. Most of them are `ddk_module`s, which have no Makefile or
Kbuild at all: Kleaf writes one per module at build time. This repo builds the
kernel with make (kernel/kbuild.mk), so that description has to exist as Kbuild.
This tool produces it, without running Bazel:

  * BUILD.bazel / .bzl files are evaluated as data. Every Kleaf rule is a stub
    that records its attributes, select() is resolved against the device's
    `--condition` set, and glob() follows Bazel's rules (no descent into
    subpackages).
  * From the device's root labels it walks the module graph and, for every
    ddk_module, reproduces what Kleaf's ddk/makefiles.bzl + gen_makefiles.py
    compute: sources (conditional_srcs included), -I / LINUXINCLUDE (Kleaf's
    preorder include depset), local_defines/copts, and the Module.symvers of
    its direct module deps.

Outputs:
  * <package>/Kbuild for every package holding a ddk_module. One file can hold
    several modules; kernel/kbuild.mk builds them one per make invocation
    (DDK_MODULE=<name>, own MO= directory), the way Kleaf builds each in its own
    sandbox, so modules sharing a directory cannot leak flags into each other.
  * a make fragment (--manifest) listing every module, how to build it, what it
    installs, which modules it needs first, and the Kconfig/defconfig files
    the DDK modules bring.

It is a maintenance tool: run it when the vendor tree's BUILD files change (for
example after moving kernel/kernel-source.<device>.rev), and commit what it
writes into the per-device patches. The build itself never reads BUILD.bazel.
"""

import argparse
import fnmatch
import os
import pathlib
import re
import sys

# --------------------------------------------------------------------------
# Labels


class Label:
    __slots__ = ("pkg", "name")

    def __init__(self, pkg, name):
        self.pkg = pkg
        self.name = name

    @staticmethod
    def parse(text, cur_pkg):
        if text.startswith("@"):
            # @repo//pkg:name -- external repository. Only @kleaf and friends
            # are referenced, and never for anything a module build needs.
            repo, _, rest = text.partition("//")
            return Label("@" + repo.lstrip("@") + "//" + rest.partition(":")[0],
                         rest.partition(":")[2] or rest.rsplit("/", 1)[-1])
        if text.startswith("//"):
            rest = text[2:]
            if ":" in rest:
                pkg, name = rest.split(":", 1)
            else:
                pkg, name = rest, rest.rsplit("/", 1)[-1]
            return Label(pkg, name)
        if text.startswith(":"):
            return Label(cur_pkg, text[1:])
        return Label(cur_pkg, text)

    def __str__(self):
        return f"//{self.pkg}:{self.name}"

    def __eq__(self, other):
        return isinstance(other, Label) and (self.pkg, self.name) == (other.pkg, other.name)

    def __hash__(self):
        return hash((self.pkg, self.name))

    @property
    def external(self):
        return self.pkg.startswith("@")


# --------------------------------------------------------------------------
# Starlark evaluation with stubs


class Rule:
    def __init__(self, kind, pkg, name, attrs):
        self.kind = kind
        self.pkg = pkg
        self.name = name
        self.attrs = attrs

    @property
    def label(self):
        return Label(self.pkg, self.name)


class Struct:
    def __init__(self, **kw):
        self.__dict__.update(kw)


class Stub:
    """Anything loaded from Kleaf/Bazel: callable, records a rule if named."""

    def __init__(self, ws, kind):
        self.ws = ws
        self.kind = kind

    def __call__(self, *args, **kw):
        if "name" in kw and self.ws.cur_pkg is not None:
            self.ws.add_rule(self.kind, kw)
        return Stub(self.ws, self.kind)

    def __getattr__(self, attr):
        return Stub(self.ws, self.kind + "." + attr)

    def __iter__(self):
        return iter(())

    # A stubbed helper's result used in an expression (e.g. a module list
    # concatenated with literals) stands for nothing.
    def __add__(self, other):
        return other

    __radd__ = __add__


class SelectMiss(Exception):
    pass


# .bzl files that only define Kleaf macros we stub rather than run.
STUBBED_BZL = (
    "private/devices/google/common/kleaf/device_build.bzl",
)

KLEAF_RULES = {
    "ddk_module", "ddk_headers", "kernel_module", "kernel_module_group",
    "filegroup", "alias", "ddk_uapi_headers", "ddk_submodule", "ddk_library",
    "ddk_config", "genrule",
}


class Workspace:
    def __init__(self, root, conditions, flags=(), verbose=False):
        self.root = pathlib.Path(root).resolve()
        self.conditions = set(conditions)
        # --//pkg:flag=value from the device's bazelrc.
        self.flags = {}
        for f in flags:
            k, _, v = f.partition("=")
            self.flags[str(Label.parse(k, ""))] = v
        self.verbose = verbose
        self.packages = {}      # pkg -> {name: Rule} (None while loading)
        self.bzl_cache = {}
        self.cur_pkg = None
        self.select_log = {}

    # -- helpers exposed to Starlark ------------------------------------
    def add_rule(self, kind, attrs):
        name = attrs["name"]
        self.packages[self.cur_pkg][name] = Rule(kind, self.cur_pkg, name, dict(attrs))

    def _select(self, mapping, no_match_error=""):
        hits = []
        default = None
        has_default = False
        for key, val in mapping.items():
            if key == "//conditions:default":
                default, has_default = val, True
                continue
            lab = str(Label.parse(key, self.cur_pkg or ""))
            if self.condition_true(lab):
                hits.append((lab, val))
        if len(hits) > 1:
            raise SelectMiss(f"select() in {self.cur_pkg}: several conditions match: {[h[0] for h in hits]}")
        if hits:
            self.select_log[(self.cur_pkg, tuple(sorted(mapping)))] = hits[0][0]
            return hits[0][1]
        if not has_default:
            raise SelectMiss(f"select() in {self.cur_pkg} has no default and none of "
                             f"{list(mapping)} is in --condition")
        return default

    def flag_value(self, label):
        if label in self.flags:
            return self.flags[label]
        r = self.rule(Label.parse(label, ""))
        if r is None:
            raise SelectMiss(f"unknown build setting {label}")
        v = r.attrs.get("build_setting_default")
        return str(v)

    def condition_true(self, label):
        if label in self.conditions:
            return True
        r = self.rule(Label.parse(label, ""))
        if r is None or r.kind != "config_setting":
            return False
        if r.attrs.get("values") or r.attrs.get("define_values") or r.attrs.get("constraint_values"):
            return False  # only via --condition
        fv = r.attrs.get("flag_values") or {}
        if not fv:
            return False
        for flag, want in fv.items():
            flab = str(Label.parse(flag, r.pkg))
            have, want = self.flag_value(flab), str(want)
            fr = self.rule(Label.parse(flab, ""))
            if fr is not None and fr.kind == "bool_flag":
                # Bazel accepts 1/0, true/false, True/False for bools.
                have, want = _bool(have), _bool(want)
            if have != want:
                return False
        return True

    def _glob(self, include, exclude=(), allow_empty=True, exclude_directories=1):
        pkg_dir = self.root / self.cur_pkg
        out = set()
        for pattern in include:
            for path in self._walk(pkg_dir):
                if _glob_match(path, pattern):
                    out.add(path)
        for pattern in exclude:
            out = {p for p in out if not _glob_match(p, pattern)}
        return sorted(out)

    def _walk(self, pkg_dir):
        """Files under pkg_dir, relative, not crossing into subpackages."""
        res = []
        for dirpath, dirnames, filenames in os.walk(pkg_dir):
            rel = pathlib.Path(dirpath).relative_to(pkg_dir)
            keep = []
            for d in dirnames:
                sub = pathlib.Path(dirpath) / d
                if (sub / "BUILD.bazel").exists() or (sub / "BUILD").exists():
                    continue
                keep.append(d)
            dirnames[:] = sorted(keep)
            for f in filenames:
                res.append(str(rel / f) if str(rel) != "." else f)
        return res

    def _env(self):
        ws = self

        class Native:
            def __getattr__(self, attr):
                if attr == "glob":
                    return ws._glob
                if attr == "package_name":
                    return lambda: ws.cur_pkg
                if attr == "repository_name":
                    return lambda: "@"
                return Stub(ws, attr)

        class Env(dict):
            # Any other builtin or rule (config_setting, string_flag, ...):
            # a stub. Starlark has no other way for a name to be unbound.
            def __missing__(self, key):
                if key.startswith("__"):
                    raise KeyError(key)
                return Stub(ws, key)

        env = Env({
            "glob": self._glob,
            "select": self._select,
            "package": lambda **kw: None,
            "licenses": lambda *a, **kw: None,
            "exports_files": lambda *a, **kw: None,
            "package_group": lambda **kw: None,
            "Label": lambda s: s,
            "struct": Struct,
            "fail": _fail,
            "native": Native(),
            "depset": lambda *a, **kw: list(a[0]) if a else [],
        })
        for kind in KLEAF_RULES:
            env[kind] = Stub(self, kind)
        env["load"] = lambda bzl, *names, **renames: self._load(env, bzl, names, renames)
        return env

    def _load(self, env, bzl, names, renames):
        cur = self.cur_pkg or ""
        symbols = {}
        if bzl.startswith("@"):
            mod = None
        else:
            lab = Label.parse(bzl, cur)
            path = f"{lab.pkg}/{lab.name}" if lab.pkg else lab.name
            # Only the vendor tree's own .bzl files (constants, small macros)
            # are run; Kleaf's and everything else is stubbed.
            runnable = (path.startswith("private/") and path not in STUBBED_BZL
                        and (self.root / path).exists())
            mod = self._eval_bzl(path) if runnable else None
        for n in names:
            symbols[n] = n
        symbols.update({k: v for k, v in renames.items()})
        for local, remote in symbols.items():
            if mod is not None and remote in mod:
                env[local] = mod[remote]
            elif local in KLEAF_RULES:
                env[local] = Stub(self, local)
            else:
                env[local] = Stub(self, remote)

    def _eval_bzl(self, path):
        if path in self.bzl_cache:
            return self.bzl_cache[path]
        env = self._env()
        src = (self.root / path).read_text()
        exec(compile(_to_python(src), str(self.root / path), "exec"), env)
        self.bzl_cache[path] = env
        return env

    # -- packages --------------------------------------------------------
    def add_virtual(self, pkg, spec):
        """Rules for a package described by data instead of a BUILD file:
        the kernel tree's DDK header sets (see kernel/kbuild/README)."""
        self.packages[pkg] = {name: Rule(attrs.pop("kind"), pkg, name, dict(attrs, name=name))
                              for name, attrs in spec.items()}

    def package(self, pkg):
        if pkg in self.packages:
            rules = self.packages[pkg]
            if rules is None:
                raise RuntimeError(f"recursive load of {pkg}")
            return rules
        build = self.root / pkg / "BUILD.bazel"
        if not build.exists():
            build = self.root / pkg / "BUILD"
        if not build.exists():
            raise FileNotFoundError(f"no BUILD file for package {pkg}")
        self.packages[pkg] = {}
        saved, self.cur_pkg = self.cur_pkg, pkg
        try:
            env = self._env()
            exec(compile(_to_python(build.read_text()), str(build), "exec"), env)
        finally:
            self.cur_pkg = saved
        return self.packages[pkg]

    def rule(self, label):
        if label.external:
            return None
        rules = self.package(label.pkg)
        return rules.get(label.name)

    def resolve(self, label):
        """Follow alias() chains."""
        seen = set()
        while True:
            r = self.rule(label)
            if r is None or r.kind not in ("alias", "label_flag"):
                return label, r
            if label in seen:
                raise RuntimeError(f"alias loop at {label}")
            seen.add(label)
            if r.kind == "alias":
                actual = r.attrs["actual"]
            else:
                actual = self.flags.get(str(label), r.attrs.get("build_setting_default"))
            label = Label.parse(actual, r.pkg)


def _bool(v):
    v = str(v).lower()
    if v in ("1", "true", "yes"):
        return True
    if v in ("0", "false", "no"):
        return False
    raise SelectMiss(f"not a bool: {v}")


def _fail(*args, **kw):
    raise RuntimeError("fail(): " + " ".join(str(a) for a in args))


def _to_python(src):
    # Starlark is close enough to Python for these files; the one construct
    # Python rejects is a load() of a symbol named like a keyword, which these
    # trees do not use.
    return src


def _glob_match(path, pattern):
    """Bazel glob semantics: '**' matches any number of path segments."""
    regex = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            regex += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            regex += ".*"
            i += 2
        elif pattern[i] == "*":
            regex += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            regex += "[^/]"
            i += 1
        else:
            regex += re.escape(pattern[i])
            i += 1
    return re.fullmatch(regex, path) is not None


# --------------------------------------------------------------------------
# Kleaf DDK semantics


def as_list(v):
    if v is None:
        return []
    if isinstance(v, (list, tuple)):
        return list(v)
    return [v]


class Analysis:
    def __init__(self, ws, kernel_build_headers, kernel_dir, kernel_path=None):
        self.ws = ws
        self.kernel_build_headers = [Label.parse(l, "") for l in kernel_build_headers]
        self.kernel_dir = kernel_dir
        # Where the kernel package's files are on disk, if not at its label
        # path (felix: //common:... is the tree at aosp/).
        self.kernel_path = kernel_path or kernel_dir
        self.modules = {}         # Label -> info dict, insertion = discovery order
        self._hdr_nodes = {}

    # -- files -----------------------------------------------------------
    def files_of(self, text, pkg):
        """Source files (workspace-relative) a label/filename in srcs stands for."""
        lab = Label.parse(text, pkg)
        if lab.external:
            return []
        lab, r = self.ws.resolve(lab)
        if r is None:
            # A plain file.
            return [f"{lab.pkg}/{lab.name}"]
        if r.kind in ("filegroup",):
            out = []
            for s in as_list(r.attrs.get("srcs")):
                out += self.files_of(s, r.pkg)
            return out
        if r.kind == "ddk_headers":
            out = []
            for s in as_list(r.attrs.get("hdrs")):
                out += self.files_of(s, r.pkg)
            return out
        return []

    def hdr_files(self, text, pkg, seen=None):
        """Header files a dep makes available: ddk_headers/ddk_module hdrs, transitively."""
        seen = set() if seen is None else seen
        lab = Label.parse(text, pkg)
        if lab.external or lab in seen:
            return []
        seen.add(lab)
        lab, r = self.ws.resolve(lab)
        if r is None:
            return [f"{lab.pkg}/{lab.name}"]
        out = []
        if r.kind in ("ddk_headers", "ddk_module", "filegroup"):
            for h in as_list(r.attrs.get("hdrs")) + (as_list(r.attrs.get("srcs")) if r.kind == "filegroup" else []):
                out += self.hdr_files(h, r.pkg, seen)
        return out

    # -- headers (DdkHeadersInfo.include_infos, preorder) -----------------
    def hdr_node(self, text, pkg):
        """(direct_infos, children) for a dep/hdr label, or None if it has no
        DdkHeadersInfo. An info is (prefix, includes, linux_includes)."""
        lab = Label.parse(text, pkg)
        if lab.external:
            return None
        lab, r = self.ws.resolve(lab)
        if r is None:
            return None
        key = lab
        if key in self._hdr_nodes:
            return self._hdr_nodes[key]
        node = None
        if r.kind == "ddk_headers":
            inc = tuple(as_list(r.attrs.get("includes")))
            linc = tuple(as_list(r.attrs.get("linux_includes")))
            prefix = self.kernel_path if r.pkg == self.kernel_dir else r.pkg
            direct = [(prefix, inc, linc)] if (inc or linc) else []
            kids = [self.hdr_node(h, r.pkg) for h in as_list(r.attrs.get("hdrs"))]
            node = (direct, [k for k in kids if k])
        elif r.kind == "ddk_module":
            inc = tuple(as_list(r.attrs.get("includes")))
            direct = [(r.pkg, inc, ())] if inc else []
            kids = [self.hdr_node(h, r.pkg) for h in as_list(r.attrs.get("hdrs"))]
            node = (direct, [k for k in kids if k])
        elif r.kind == "kernel_module_group":
            kids = [self.hdr_node(s, r.pkg) for s in as_list(r.attrs.get("srcs"))]
            node = ([], [k for k in kids if k])
        self._hdr_nodes[key] = node
        return node

    @staticmethod
    def preorder(nodes):
        out, seen = [], set()

        def visit(n):
            direct, kids = n
            for d in direct:
                if d not in seen:
                    seen.add(d)
                    out.append(d)
            for k in kids:
                visit(k)

        for n in nodes:
            visit(n)
        return out

    # -- modules -----------------------------------------------------------
    def module_symvers(self, text, pkg):
        """ModuleSymversInfo.restore_paths of a dep, [] if it is not a module."""
        lab = Label.parse(text, pkg)
        if lab.external:
            return []
        lab, r = self.ws.resolve(lab)
        if r is None:
            return []
        if r.kind == "ddk_module":
            return [f"{r.pkg}/{r.name}_Module.symvers"]
        if r.kind == "kernel_module":
            return [f"{self.ext_mod(r)}/Module.symvers"]
        if r.kind == "kernel_module_group":
            out = []
            for s in as_list(r.attrs.get("srcs")):
                out += [p for p in self.module_symvers(s, r.pkg) if p not in out]
            return out
        return []

    def module_labels(self, text, pkg):
        """Module targets a label stands for (groups expanded)."""
        lab = Label.parse(text, pkg)
        if lab.external:
            return []
        lab, r = self.ws.resolve(lab)
        if r is None:
            return []
        if r.kind in ("ddk_module", "kernel_module"):
            return [lab]
        if r.kind == "kernel_module_group":
            out = []
            for s in as_list(r.attrs.get("srcs")):
                out += self.module_labels(s, r.pkg)
            return out
        return []

    @staticmethod
    def ext_mod(r):
        mk = as_list(r.attrs.get("makefile"))
        if mk:
            lab = Label.parse(mk[0], r.pkg)
            return lab.pkg
        return r.pkg

    def add_roots(self, roots):
        self.installed = set()
        for text in roots:
            for lab in self.module_labels(text, ""):
                self.installed.add(lab)
                self.visit(lab)

    def visit(self, lab):
        if lab in self.modules:
            return
        _, r = self.ws.resolve(lab)
        self.modules[lab] = None  # placeholder for cycle safety
        deps = as_list(r.attrs.get("deps"))
        mod_deps = []
        for d in deps:
            for m in self.module_labels(d, r.pkg):
                if m not in mod_deps:
                    mod_deps.append(m)
        for m in mod_deps:
            self.visit(m)
        if r.kind == "ddk_module":
            self.modules[lab] = self.ddk_info(r, mod_deps)
        else:
            self.modules[lab] = self.kmod_info(r, mod_deps)
        # Re-insert at the end so self.modules is in dependency order.
        info = self.modules.pop(lab)
        self.modules[lab] = info

    def kmod_info(self, r, mod_deps):
        symvers = []
        for d in as_list(r.attrs.get("deps")):
            symvers += [p for p in self.module_symvers(d, r.pkg) if p not in symvers]
        return {
            "kind": "make",
            "label": r.label,
            "pkg": self.ext_mod(r),
            "name": r.name,
            "outs": as_list(r.attrs.get("outs")),
            "deps": mod_deps,
            "symvers_out": f"{self.ext_mod(r)}/Module.symvers",
            "extra_symbols": symvers,
        }

    def ddk_info(self, r, mod_deps):
        pkg = r.pkg
        out = r.attrs.get("out") or f"{r.name}.ko"
        if "/" in out:
            raise NotImplementedError(f"{r.label}: out in a subdirectory ({out}) is not supported")
        # srcs items, then conditional_srcs (Kleaf appends ddk_conditional_filegroups).
        items = []
        for s in as_list(r.attrs.get("srcs")):
            items.append((None, None, self.files_of(s, pkg)))
        for config, by_value in (r.attrs.get("conditional_srcs") or {}).items():
            for value, files in by_value.items():
                v = True if value is True else ("" if value is False else value)
                fl = []
                for f in as_list(files):
                    fl += self.files_of(f, pkg)
                items.append((config, v, fl))
        srcs = []
        for config, value, files in items:
            keep = [f for f in files
                    if pathlib.PurePath(f).suffix in (".c", ".S", ".o_shipped", ".rs")
                    and f.startswith(pkg + "/")]
            keep = [f[len(pkg) + 1:] for f in keep]
            if keep:
                srcs.append((config, value, keep))
        # include infos: own, then deps + hdrs + kernel_build (left to right).
        own_inc = tuple(as_list(r.attrs.get("includes")))
        own_linc = tuple(as_list(r.attrs.get("linux_includes")))
        nodes = [([(pkg, own_inc, own_linc)], [])]
        for t in as_list(r.attrs.get("deps")) + as_list(r.attrs.get("hdrs")):
            n = self.hdr_node(t, pkg)
            if n:
                nodes.append(n)
        for kb in self.kernel_build_headers:
            n = self.hdr_node(str(kb), "")
            if n:
                nodes.append(n)
        infos = self.preorder(nodes)
        includes = [os.path.normpath(os.path.join(p, i)) for p, incs, _ in infos for i in incs]
        linux_includes = []
        for p, _, lincs in infos:
            for i in lincs:
                v = os.path.normpath(os.path.join(p, i))
                if v not in linux_includes:
                    linux_includes.append(v)
        symvers = []
        for d in as_list(r.attrs.get("deps")):
            symvers += [p for p in self.module_symvers(d, pkg) if p not in symvers]
        files_of_attr = lambda a: [f for x in as_list(r.attrs.get(a)) for f in self.files_of(x, pkg)]
        # Headers Kleaf's sandbox would not have contained: under one of this
        # module's own-package include dirs, but declared by nothing it uses.
        # A plain build sees the whole tree, so such a file can shadow the
        # header the module really means (edgetpu's #error stubs did).
        declared = set()
        for _, _, files in items:
            declared.update(files)
        for t in as_list(r.attrs.get("deps")) + as_list(r.attrs.get("hdrs")) + as_list(r.attrs.get("srcs")):
            declared.update(self.files_of(t, pkg))
            declared.update(self.hdr_files(t, pkg))
        undeclared = []
        for inc in includes:
            if not (inc == pkg or inc.startswith(pkg + "/")):
                continue
            base = self.ws.root / inc
            for h in sorted(base.rglob("*.h")) if base.is_dir() else []:
                rel = str(h.relative_to(self.ws.root))
                if rel not in declared and rel not in undeclared:
                    undeclared.append(rel)
        return {
            "kind": "ddk",
            "label": r.label,
            "pkg": pkg,
            "name": r.name,
            "out": out,
            "srcs": srcs,
            "includes": includes,
            "linux_includes": linux_includes,
            "local_defines": as_list(r.attrs.get("local_defines")),
            "copts": as_list(r.attrs.get("copts")),
            "removed_copts": as_list(r.attrs.get("removed_copts")),
            "asopts": as_list(r.attrs.get("asopts")),
            "linkopts": as_list(r.attrs.get("linkopts")),
            "deps": mod_deps,
            "extra_symbols": symvers,
            "symvers_out": f"{pkg}/{r.name}_Module.symvers",
            "kconfig": files_of_attr("kconfig"),
            "defconfig": files_of_attr("defconfig"),
            "undeclared_headers": undeclared,
        }


# --------------------------------------------------------------------------
# Output


HEADER = """\
# SPDX-License-Identifier: GPL-2.0
#
# GENERATED by tools/bazel2kbuild.py from this package's BUILD.bazel -- do not
# edit; regenerate it. kernel/kbuild.mk builds the modules here one per make
# invocation (DDK_MODULE=<name>), each into its own output directory.
"""


def _user_opt(o):
    """An option from BUILD.bazel, as Kleaf delivers it.

    Kleaf writes options into a response file (@file), so they reach the
    compiler verbatim: no make expansion, no shell word splitting or quote
    removal. Here they pass through both, so quote for the shell and escape
    '$' for make, and the compiler sees exactly what Kleaf's would.
    """
    import shlex
    return shlex.quote(o).replace("$", "$$")


def _flags_for(m, root_var="$(ROOT_DIR)"):
    # Same order as Kleaf's .cflags_shipped: defines, includes, copts.
    cflags = [_user_opt(f"-D{d}") for d in m["local_defines"]]
    cflags += [f"-I{root_var}/{i}" for i in m["includes"]]
    cflags += [_user_opt(o) for o in m["copts"]]
    asflags = [_user_opt(f"-D{d}") for d in m["local_defines"]]
    asflags += [f"-I{root_var}/{i}" for i in m["includes"]]
    asflags += [_user_opt(o) for o in m["asopts"]]
    return cflags, asflags


def _expand_opt(o, m):
    if "$(" in o:
        raise NotImplementedError(f"{m['label']}: option with a make function / location: {o}")
    return o


def kbuild_for(mods):
    out = [HEADER]
    for m in mods:
        base = m["out"][:-3]
        out.append(f"\nifeq ($(DDK_MODULE),{m['name']})\n")
        out.append(f"# {m['label']}\n")
        out.append(f"obj-m += {base}.o\n")
        for config, value, files in m["srcs"]:
            objs = []
            for f in files:
                p = pathlib.PurePath(f)
                if str(p.with_suffix(".ko")) == m["out"]:
                    continue  # foo.c building foo.ko: Kbuild's default rule
                objs.append(str(p.with_suffix(".o")))
            if not objs:
                continue
            if config is None:
                suffix, cond = "y", None
            elif value is True:
                suffix, cond = f"$({config})", None
            else:
                suffix, cond = "y", f"ifeq ($({config}),{value})"
            if cond:
                out.append(cond + "\n")
            for o in objs:
                out.append(f"{base}-{suffix} += {o}\n")
            if cond:
                out.append(f"endif\n")
        if m["linux_includes"]:
            out.append("LINUXINCLUDE := \\\n")
            for i in m["linux_includes"]:
                out.append(f"  -I$(ROOT_DIR)/{i} \\\n")
            out.append("  $(LINUXINCLUDE)\n")
        cflags, asflags = _flags_for(m)
        if cflags:
            out.append("ccflags-y += \\\n" + "".join(f"  {f} \\\n" for f in cflags).rstrip(" \\\n") + "\n")
        if asflags:
            out.append("asflags-y += \\\n" + "".join(f"  {f} \\\n" for f in asflags).rstrip(" \\\n") + "\n")
        if m["removed_copts"]:
            # Kleaf's CFLAGS_REMOVE_<obj> per object; for a one-module build
            # the directory-wide form is the same thing.
            out.append("ccflags-remove-y += " + " ".join(m["removed_copts"]) + "\n")
        if m["linkopts"]:
            out.append(f"LDFLAGS_{base}.o += " + " ".join(m["linkopts"]) + "\n")
        out.append("endif\n")
    return "".join(out)


def mid(label):
    return f"{label.pkg}:{label.name}".replace(":", "/")


def manifest_for(analysis, roots, device):
    lines = [
        "# SPDX-License-Identifier: GPL-2.0\n",
        f"# GENERATED by tools/bazel2kbuild.py for {device} -- do not edit; regenerate it.\n",
        "#\n",
        "# Every out-of-tree module the device ships, in dependency order. Per\n",
        "# module <id>: .kind (ddk = Kbuild written by bazel2kbuild, make = the\n",
        "# package's own Makefile), .dir (package built with M=), .name, .outs\n",
        "# (.ko files it installs), .needs (modules that must be built first),\n",
        "# .install (shipped, or only built for other modules' sake), .symvers\n",
        "# (where its Module.symvers is kept, under kernel/kbuild.mk's $(MOUT)) and\n",
        "# .extra_symbols (its deps' Module.symvers, KBUILD_EXTRA_SYMBOLS for ddk).\n",
        "#\n",
        "# Roots:\n",
    ]
    for r in roots:
        lines.append(f"#   {r}\n")
    lines.append("\n")
    ids = []
    for lab, m in analysis.modules.items():
        i = mid(lab)
        ids.append(i)
        outs = [m["out"]] if m["kind"] == "ddk" else m["outs"]
        lines.append(f"{i}.kind := {m['kind']}\n")
        lines.append(f"{i}.dir := {m['pkg']}\n")
        lines.append(f"{i}.name := {m['name']}\n")
        lines.append(f"{i}.outs := {' '.join(outs)}\n")
        # Kleaf installs what the device's module groups list; a module that
        # is only some other module's dep is built (for its symbols and
        # headers) but not shipped.
        lines.append(f"{i}.install := {'1' if lab in analysis.installed else ''}\n")
        lines.append(f"{i}.needs := {' '.join(mid(d) for d in m['deps'])}\n")
        lines.append(f"{i}.symvers := {m['symvers_out']}\n")
        lines.append(f"{i}.extra_symbols := {' '.join(m['extra_symbols'])}\n\n")
    lines.append("EXT_MODULES := \\\n" + "".join(f"  {i} \\\n" for i in ids).rstrip(" \\\n") + "\n\n")
    kconfigs, defconfigs = [], []
    for m in analysis.modules.values():
        for k in m.get("kconfig", []):
            if k not in kconfigs:
                kconfigs.append(k)
        for d in m.get("defconfig", []):
            if d not in defconfigs:
                defconfigs.append(d)
    lines.append("# Kconfig / defconfig of the ddk_modules (Kleaf's per-module ddk_config).\n")
    lines.append("EXT_MODULE_KCONFIGS := \\\n" + "".join(f"  {k} \\\n" for k in kconfigs).rstrip(" \\\n") + "\n")
    lines.append("EXT_MODULE_DEFCONFIGS := \\\n" + "".join(f"  {d} \\\n" for d in defconfigs).rstrip(" \\\n") + "\n")
    return "".join(lines)


def check_defconfigs(root, defconfigs):
    """Two module defconfigs setting one symbol differently would silently
    depend on merge order once they share one .config; refuse instead."""
    seen = {}
    bad = []
    for d in defconfigs:
        for line in (root / d).read_text().splitlines():
            m = re.match(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$", line) or \
                re.match(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$", line)
            if not m:
                continue
            sym = m.group(1)
            val = m.group(2) if m.lastindex == 2 else "n"
            if sym in seen and seen[sym][1] != val:
                bad.append(f"{sym}: {seen[sym][0]}={seen[sym][1]} vs {d}={val}")
            seen.setdefault(sym, (d, val))
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", required=True, help="kernel source checkout (kernel/source-<device>)")
    ap.add_argument("--device", required=True)
    ap.add_argument("--module", action="append", default=[], dest="roots",
                    help="root module label (repeatable): the device's ext_modules")
    ap.add_argument("--condition", action="append", default=[],
                    help="config_setting label that is true for this device (repeatable)")
    ap.add_argument("--flag", action="append", default=[],
                    help="//pkg:build_setting=value, as the device's bazelrc sets it (repeatable)")
    ap.add_argument("--kernel-build-headers", action="append", default=[],
                    help="ddk_headers the device kernel_build provides to every DDK module "
                         "(its ddk_module_headers), lowest priority")
    ap.add_argument("--kernel-dir", default="common",
                    help="package name the BUILD files use for the kernel tree")
    ap.add_argument("--kernel-path",
                    help="where that tree is, if not at --kernel-dir (felix: aosp)")
    ap.add_argument("--kernel-headers",
                    help="JSON describing the kernel package's ddk_headers targets "
                         "(used instead of <kernel-dir>/BUILD.bazel)")
    ap.add_argument("--manifest", required=True, help="make fragment to write")
    ap.add_argument("--write-kbuild", action="store_true",
                    help="write <package>/Kbuild into the source tree")
    ap.add_argument("--kbuild-out", help="write <package>/Kbuild under this directory instead")
    ap.add_argument("--dump", help="write the analysis as JSON (for diffing against Kleaf)")
    args = ap.parse_args()

    ws = Workspace(args.root, args.condition, args.flag)
    if args.kernel_headers:
        import json
        ws.add_virtual(args.kernel_dir, json.loads(pathlib.Path(args.kernel_headers).read_text()))
    an = Analysis(ws, args.kernel_build_headers, args.kernel_dir, args.kernel_path)
    an.add_roots(args.roots)

    bad = check_defconfigs(ws.root, [d for m in an.modules.values() for d in m.get("defconfig", [])])
    if bad:
        sys.exit("conflicting module defconfigs:\n  " + "\n  ".join(bad))

    by_pkg = {}
    for m in an.modules.values():
        if m["kind"] == "ddk":
            by_pkg.setdefault(m["pkg"], []).append(m)
    for pkg, mods in sorted(by_pkg.items()):
        for f in ("Kbuild", "Makefile"):
            p = ws.root / pkg / f
            if p.exists() and not p.read_text().startswith(HEADER.splitlines()[0] + "\n#\n# GENERATED"):
                sys.exit(f"{p} exists and was not written by this tool; refusing to overwrite")
        text = kbuild_for(mods)
        if args.write_kbuild:
            (ws.root / pkg / "Kbuild").write_text(text)
        if args.kbuild_out:
            dst = pathlib.Path(args.kbuild_out) / pkg / "Kbuild"
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(text)

    pathlib.Path(args.manifest).write_text(manifest_for(an, args.roots, args.device))

    if args.dump:
        import json
        def enc(o):
            if isinstance(o, Label):
                return str(o)
            raise TypeError(o)
        pathlib.Path(args.dump).write_text(json.dumps(
            {str(k): v for k, v in an.modules.items()}, default=enc, indent=1))

    for m in an.modules.values():
        for h in m.get("undeclared_headers", []):
            print(f"WARNING: {m['label']}: {h} is on its include path but declared by "
                  f"nothing it uses; Kleaf's sandbox hid it, a plain build does not", file=sys.stderr)
    for (pkg, keys), hit in sorted(ws.select_log.items()):
        print(f"select() in {pkg}: took {hit}", file=sys.stderr)
    nd = sum(1 for m in an.modules.values() if m["kind"] == "ddk")
    print(f"{len(an.modules)} modules ({nd} ddk, {len(an.modules) - nd} make), "
          f"{len(by_pkg)} Kbuild files", file=sys.stderr)


if __name__ == "__main__":
    main()
