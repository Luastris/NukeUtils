#!/usr/bin/env python3
# Scans NUKE_CLASS / NUKE_CLASS_NOCREATE + [[nuke::prop]]/[[nuke::func]] and emits a
# reflection-registration TU. Run as a pre-build step.
#
# No args = the engine: NukeEngine/include -> NukeEngine/src/reflect/Reflect.gen.cpp.
# Module mode emits an .inc the module #includes in-TU and calls from OnLoad:
#   nukegen.py --include NukeScript/src --out NukeScript/src/NukeScript.gen.inc \
#              --init NukeReflectInit_NukeScript --scan-cpp --no-includes
import os, re, sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # eco root (NukeUtils/..)

def parse_args(argv):
    cfg = { "include": [], "out": None, "init": "NukeReflectInit", "scan_cpp": False, "no_includes": False }
    i = 0
    while i < len(argv):
        a = argv[i]
        if   a == "--include":     cfg["include"].append(argv[i + 1]); i += 2
        elif a == "--out":         cfg["out"] = argv[i + 1]; i += 2
        elif a == "--init":        cfg["init"] = argv[i + 1]; i += 2
        elif a == "--scan-cpp":    cfg["scan_cpp"] = True; i += 1
        elif a == "--no-includes": cfg["no_includes"] = True; i += 1
        else: raise SystemExit("nukegen: unknown arg %r" % a)
    if not cfg["include"]:
        cfg["include"] = [os.path.join(_ROOT, "NukeEngine", "include")]
    if not cfg["out"]:
        cfg["out"] = os.path.join(_ROOT, "NukeEngine", "src", "reflect", "Reflect.gen.cpp")
    # relative paths (from a module CMake) resolve against the eco root
    cfg["include"] = [p if os.path.isabs(p) else os.path.join(_ROOT, p) for p in cfg["include"]]
    cfg["out"]     = cfg["out"] if os.path.isabs(cfg["out"]) else os.path.join(_ROOT, cfg["out"])
    return cfg

CLASS_RE = re.compile(r'\bNUKE_CLASS(_NOCREATE)?\s*\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_][\w:]*)\s*(?:,\s*"([^"]*)"\s*)?\)')
# [[nuke::prop(<attr>)]] <type> <name> (= ... | ; | {) — \s* after ]]: the attribute may sit
# on its own line above the declaration (legal C++; C++26 reflection sees it there too).
PROP_RE = re.compile(
    r'\[\[\s*nuke::prop(?P<attr>[^\]]*)\]\]\s*'
    r'(?P<type>[A-Za-z_][\w:\*&<>, \t]*?)[ \t]+'   # type (single line; trimmed later)
    r'(?P<fname>[A-Za-z_]\w*)[ \t]*(?:=|;|\{)')
# [[nuke::func]] <ret> <name>( — no overloads (a member pointer would be ambiguous); param and
# return types must be FT-supported or the generated MakeMethod line fails to compile.
FUNC_RE = re.compile(
    r'\[\[\s*nuke::func\s*\]\]\s*'
    r'(?:virtual[ \t]+|static[ \t]+)?'   # static -> MakeMethod's free-function overload (isStatic)
    r'(?P<ret>[A-Za-z_][\w:&<>, \t\*]*?)[ \t]+'
    r'(?P<mname>[A-Za-z_]\w*)[ \t]*\(')
ASSET_RE = re.compile(r'asset\s*=\s*"([^"]*)"')
LABEL_RE = re.compile(r'label\s*=\s*"([^"]*)"')
MIN_RE   = re.compile(r'\bmin\s*=\s*(-?[\d.]+)')
MAX_RE   = re.compile(r'\bmax\s*=\s*(-?[\d.]+)')
ENUM_RE  = re.compile(r'enum\s*=\s*"([^"]*)"')
HIDDEN_RE = re.compile(r'\bhidden\b')   # [[nuke::prop(hidden)]] -> serialized but NOT drawn in the inspector
TIP_RE    = re.compile(r'tip\s*=\s*"([^"]*)"')     # inspector tooltip on hover
WIDGET_RE = re.compile(r'widget\s*=\s*"([^"]*)"')  # named custom inspector widget (e.g. "layers")

def rel_include(path, roots):
    # emit an #include relative to whichever scan root contains the file
    for r in roots:
        try:
            rp = os.path.relpath(path, r)
            if not rp.startswith(".."):
                return rp.replace("\\", "/")
        except ValueError:
            pass
    return os.path.basename(path)

def main():
    cfg = parse_args(sys.argv[1:])
    roots      = cfg["include"]
    OUT        = cfg["out"]
    INIT       = cfg["init"]
    exts       = (".h", ".cpp") if cfg["scan_cpp"] else (".h",)
    types = []  # (className, base, createFlag, includePath)
    seen_types = set()
    fields = {} # className -> [name]
    methods = {} # className -> [methodName]
    walk_files = []
    for root in roots:
        for dp, dn, fn in os.walk(root):
            if "reflect" in dp.replace("\\", "/").lower():
                continue  # skip the macro-definition headers (their comments contain examples)
            for f in fn:
                if f.endswith(exts):
                    walk_files.append(os.path.join(dp, f))
    if True:
        for path in walk_files:
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
            text = re.sub(r'(?m)^\s*#define.*(?:\\\r?\n.*)*$', '', text)  # drop #define blocks
            classes = [(m.start(), m.group(2), m.group(3), m.group(1) is None, m.group(4) or "")
                       for m in CLASS_RE.finditer(text)]
            if not classes:
                continue
            inc = rel_include(path, roots)
            for _, cls, base, create, cat in classes:
                if cls in seen_types:
                    continue
                seen_types.add(cls)
                types.append((cls, base, create, inc, cat))
                fields.setdefault(cls, [])
                methods.setdefault(cls, [])
            # assign each [[nuke::prop]] field to the nearest preceding NUKE_CLASS
            for m in PROP_RE.finditer(text):
                owner = None
                for pos, cls, base, create, _cat in classes:
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
                tm = TIP_RE.search(m.group("attr"))
                wm = WIDGET_RE.search(m.group("attr"))
                fields[owner].append((fname, am.group(1) if am else "", lm.group(1) if lm else "",
                                      mn.group(1) if mn else None, mx.group(1) if mx else None,
                                      em.group(1) if em else "", hid,
                                      tm.group(1) if tm else "", wm.group(1) if wm else ""))
            # assign each [[nuke::func]] method to the nearest preceding NUKE_CLASS
            for m in FUNC_RE.finditer(text):
                owner = None
                for pos, cls, base, create, _cat in classes:
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
    for _, _, _, inc, _cat in types:
        if inc not in seen:
            seen.add(inc); incs.append(inc)

    lines = []
    lines.append("// AUTO-GENERATED by NukeUtils/nukegen.py — DO NOT EDIT.")
    if not cfg["no_includes"]:
        lines.append('#include "reflect/Reflect.h"')
        for inc in incs:
            lines.append('#include "%s"' % inc)
        lines.append("")
    else:
        # in-TU .inc: the including .cpp already pulls Reflect.h + the class definitions above.
        lines.append("// #included IN-TU after the module's component definitions (no headers here).")
    lines.append("namespace nuke {")
    if cfg["no_includes"]:
        lines.append("// Registers this MODULE's reflected components into the engine's shared registry.")
        lines.append("// Call once from the module's NUKEModule::OnLoad (before any world deserializes).")
    else:
        lines.append("// Called once from World's constructor. Must be an EXTERNAL function called from a")
        lines.append("// linked TU, otherwise the linker discards this .obj (and its registration) from")
        lines.append("// the static lib (nothing else references it).")
    lines.append("bool %s() {" % INIT)
    lines.append("\tstatic bool _done = false;")
    lines.append("\tif (_done) return true;")
    lines.append("\t_done = true;")
    for cls, base, create, inc, cat in types:
        lines.append("\t{")
        lines.append('\t\tTypeInfo& t = TypeOf<%s>();' % cls)
        lines.append('\t\tt.base = "%s";' % base)
        if cat:
            lines.append('		t.category = "%s";' % cat)
        for name, asset, label, fmin, fmax, enumc, hidden, tip, widget in fields.get(cls, []):
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
            if tip:
                lines.append('\t\tt.fields.back().tip = "%s";' % tip.replace('\\', '\\\\').replace('"', '\\"'))
            if widget:
                lines.append('\t\tt.fields.back().widget = "%s";' % widget)
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
