#!/usr/bin/env python3
# Mini-UHT: scans engine headers for NUKE_CLASS / NUKE_CLASS_NOCREATE + [[nuke::prop]]
# fields and emits Reflect.gen.cpp with the reflection registration. Run as a pre-build
# step. When C++26 reflection lands this whole tool is dropped (the [[nuke::prop]]
# attributes stay and are read natively).
import os, re, sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (tools/..)
INCLUDE_ROOT = os.path.join(_ROOT, "NukeEngine", "include")
OUT = os.path.join(_ROOT, "NukeEngine", "src", "reflect", "Reflect.gen.cpp")

CLASS_RE = re.compile(r'\bNUKE_CLASS(_NOCREATE)?\s*\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_][\w:]*)\s*\)')
# [[nuke::prop ...]] <type> <name> (= ... | ; | {)
# The attribute body (group "attr") may carry hints, e.g. [[nuke::prop(asset="mesh")]].
PROP_RE = re.compile(
    r'\[\[\s*nuke::prop(?P<attr>[^\]]*)\]\][ \t]*'
    r'(?P<type>[A-Za-z_][\w:\*&<>, \t]*?)[ \t]+'   # type (single line; trimmed later)
    r'(?P<fname>[A-Za-z_]\w*)[ \t]*(?:=|;|\{)')
# [[nuke::func]] <ret> <name>( — a reflected METHOD (emitted as MakeMethod, which deduces
# the FT signature from the member-function pointer). Overloads are NOT supported (a plain
# member pointer would be ambiguous); param/return types must be FT-supported or the
# generated MakeMethod line fails to COMPILE (detail::FromRV has no such specialization).
FUNC_RE = re.compile(
    r'\[\[\s*nuke::func\s*\]\][ \t]*'
    r'(?:virtual[ \t]+)?'
    r'(?P<ret>[A-Za-z_][\w:&<>, \t]*?)[ \t]+'
    r'(?P<mname>[A-Za-z_]\w*)[ \t]*\(')
ASSET_RE = re.compile(r'asset\s*=\s*"([^"]*)"')
LABEL_RE = re.compile(r'label\s*=\s*"([^"]*)"')
MIN_RE   = re.compile(r'\bmin\s*=\s*(-?[\d.]+)')
MAX_RE   = re.compile(r'\bmax\s*=\s*(-?[\d.]+)')
ENUM_RE  = re.compile(r'enum\s*=\s*"([^"]*)"')
HIDDEN_RE = re.compile(r'\bhidden\b')   # [[nuke::prop(hidden)]] -> serialized but NOT drawn in the inspector

def rel_include(path):
    p = os.path.relpath(path, INCLUDE_ROOT).replace("\\", "/")
    return p

def main():
    types = []  # (className, base, createFlag, includePath)
    seen_types = set()
    fields = {} # className -> [name]
    methods = {} # className -> [methodName]
    for dp, dn, fn in os.walk(INCLUDE_ROOT):
        if "reflect" in dp.replace("\\", "/").lower():
            continue  # skip the macro-definition headers (their comments contain examples)
        for f in fn:
            if not f.endswith(".h"):
                continue
            path = os.path.join(dp, f)
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
            text = re.sub(r'(?m)^\s*#define.*(?:\\\r?\n.*)*$', '', text)  # drop #define blocks
            classes = [(m.start(), m.group(2), m.group(3), m.group(1) is None)
                       for m in CLASS_RE.finditer(text)]
            if not classes:
                continue
            inc = rel_include(path)
            for _, cls, base, create in classes:
                if cls in seen_types:
                    continue
                seen_types.add(cls)
                types.append((cls, base, create, inc))
                fields.setdefault(cls, [])
                methods.setdefault(cls, [])
            # assign each [[nuke::prop]] field to the nearest preceding NUKE_CLASS
            for m in PROP_RE.finditer(text):
                owner = None
                for pos, cls, base, create in classes:
                    if pos < m.start():
                        owner = cls
                    else:
                        break
                if owner is None:
                    continue
                fname = m.group("fname")
                if fname in [f[0] for f in fields[owner]]:
                    continue
                am = ASSET_RE.search(m.group("attr"))
                lm = LABEL_RE.search(m.group("attr"))
                mn = MIN_RE.search(m.group("attr"))
                mx = MAX_RE.search(m.group("attr"))
                em = ENUM_RE.search(m.group("attr"))
                hid = bool(HIDDEN_RE.search(m.group("attr")))
                fields[owner].append((fname, am.group(1) if am else "", lm.group(1) if lm else "",
                                      mn.group(1) if mn else None, mx.group(1) if mx else None,
                                      em.group(1) if em else "", hid))
            # assign each [[nuke::func]] method to the nearest preceding NUKE_CLASS
            for m in FUNC_RE.finditer(text):
                owner = None
                for pos, cls, base, create in classes:
                    if pos < m.start():
                        owner = cls
                    else:
                        break
                if owner is None:
                    continue
                mname = m.group("mname")
                if mname not in methods[owner]:
                    methods[owner].append(mname)

    # de-dupe includes, keep order
    incs, seen = [], set()
    for _, _, _, inc in types:
        if inc not in seen:
            seen.add(inc); incs.append(inc)

    lines = []
    lines.append("// AUTO-GENERATED by tools/nukegen.py — DO NOT EDIT.")
    lines.append('#include "reflect/Reflect.h"')
    for inc in incs:
        lines.append('#include "%s"' % inc)
    lines.append("")
    lines.append("namespace nuke {")
    lines.append("// Called once from World's constructor. Must be an EXTERNAL function called from a")
    lines.append("// linked TU, otherwise the linker discards this .obj (and its registration) from")
    lines.append("// the static lib (nothing else references it).")
    lines.append("bool NukeReflectInit() {")
    lines.append("\tstatic bool _done = false;")
    lines.append("\tif (_done) return true;")
    lines.append("\t_done = true;")
    for cls, base, create, inc in types:
        lines.append("\t{")
        lines.append('\t\tTypeInfo& t = TypeOf<%s>();' % cls)
        lines.append('\t\tt.base = "%s";' % base)
        for name, asset, label, fmin, fmax, enumc, hidden in fields.get(cls, []):
            if enumc:
                mn = float(fmin) if fmin is not None else 0.0
                mx = float(fmax) if fmax is not None else 0.0
                lines.append('\t\tt.fields.push_back(MakeField("%s", &%s::%s, "%s", "%s", %sf, %sf, "%s"));' % (name, cls, name, asset, label, mn, mx, enumc))
            elif fmin is not None and fmax is not None:
                lines.append('\t\tt.fields.push_back(MakeField("%s", &%s::%s, "%s", "%s", %sf, %sf));' % (name, cls, name, asset, label, float(fmin), float(fmax)))
            elif label:
                lines.append('\t\tt.fields.push_back(MakeField("%s", &%s::%s, "%s", "%s"));' % (name, cls, name, asset, label))
            elif asset:
                lines.append('\t\tt.fields.push_back(MakeField("%s", &%s::%s, "%s"));' % (name, cls, name, asset))
            else:
                lines.append('\t\tt.fields.push_back(MakeField("%s", &%s::%s));' % (name, cls, name))
            if hidden:
                lines.append('\t\tt.fields.back().hidden = true;')   # serialized but not drawn in the inspector
        for mname in methods.get(cls, []):
            lines.append('\t\tt.methods.push_back(MakeMethod("%s", &%s::%s));' % (mname, cls, mname))
        if create:
            lines.append('\t\tt.create = []() -> void* { return new %s(); };' % cls)
        lines.append("\t}")
    lines.append("\treturn true;")
    lines.append("}")
    lines.append("}  // namespace nuke")
    lines.append("")

    content = "\n".join(lines)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    old = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else None
    if old != content:
        open(OUT, "w", encoding="utf-8").write(content)
        print("nukegen: wrote", OUT, "(%d types)" % len(types))
    else:
        print("nukegen: up to date (%d types)" % len(types))

if __name__ == "__main__":
    main()
