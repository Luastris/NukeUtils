#!/usr/bin/env python3
# Builds the editor's file-type icon font + its header.
#
# Source: the Nerd Fonts symbols font (MIT), which aggregates Seti-UI (the glyphs VS Code's file
# explorer draws), Font Awesome, Octicons, Codicons and Devicons. Only the glyphs listed below
# are kept, and their codepoints are RE-MAPPED into plane 15 (U+F0100+): the originals sit inside
# Lucide's range (E038-E6FD), and two fonts merged into one ImGui atlas cannot share a slot.
#
#   pip install fonttools
#   python NukeUtils/nukeicons.py
#
# Writes NukeImGui/assets/nukefileicons.ttf and NukeEngine/include/interface/IconsFileTypes.h.
# Requires IMGUI_USE_WCHAR32 (imconfig.h) — the remapped codepoints are above 0xFFFF.
import io, json, os, sys, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NF_VERSION = "v3.4.0"
NF_ZIP = "https://github.com/ryanoasis/nerd-fonts/releases/download/%s/NerdFontsSymbolsOnly.zip" % NF_VERSION
NF_NAMES = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/glyphnames.json"
BASE = 0xF0100

# constant name -> glyph name in the Nerd Fonts set. Source files use the Seti-UI set; engine
# asset kinds use the Font Awesome / Octicons / Codicons subsets.
ICONS = [
    ("CPP", "seti-cpp"), ("C", "seti-c"), ("CSHARP", "seti-c_sharp"), ("LUA", "seti-lua"),
    ("PYTHON", "seti-python"), ("JSON", "seti-json"), ("XML", "seti-xml"),
    ("MARKDOWN", "seti-markdown"), ("TEXT", "seti-text"), ("CONFIG", "seti-config"),
    ("SHELL", "seti-shell"), ("POWERSHELL", "seti-powershell"), ("MAKEFILE", "seti-makefile"),
    ("FONT", "seti-font"), ("IMAGE", "seti-image"), ("AUDIO", "seti-audio"),
    ("VIDEO", "seti-video"), ("ZIP", "seti-zip"), ("DB", "seti-db"), ("LOCK", "seti-lock"),
    ("FOLDER", "seti-folder"), ("HTML", "seti-html"), ("CSS", "seti-css"),
    ("JAVASCRIPT", "seti-javascript"), ("ASM", "custom-asm"), ("PROJECT", "seti-project"),
    ("LICENSE", "seti-license"), ("INFO", "seti-info"), ("GIT", "seti-git"),
    ("DEFAULT", "seti-default"),
    ("MESH", "fa-cube"), ("MESH_INSTANCED", "fa-cubes"), ("MATERIAL", "fa-paint_brush"),
    ("PREFAB", "oct-package"), ("ANIM", "cod-play"), ("SKELETON", "fa-bone"),
    ("BONEMAP", "cod-symbol_structure"), ("STATEMACHINE", "oct-workflow"),
    ("BLENDSPACE", "cod-graph"), ("SEQUENCE", "fa-film"), ("RAGDOLL", "fa-child"),
    ("WORLD", "fa-globe"), ("SHADER", "cod-circuit_board"), ("VFX", "fa-magic"),
    ("WATER", "fa-tint"), ("FOLIAGE", "fa-tree"), ("TILEMAP", "fa-map"),
    ("INPUT", "fa-gamepad"), ("PACKAGE", "fa-archive"), ("MOD", "fa-puzzle_piece"),
    ("SAVE", "fa-database"), ("SETTINGS", "fa-sliders"),
]


def fetch(url, path):
    if os.path.exists(path):
        return path
    print("fetching", url)
    urllib.request.urlretrieve(url, path)
    return path


def main():
    try:
        from fontTools import subset
        from fontTools.ttLib import TTFont, newTable
        from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
    except ImportError:
        raise SystemExit("nukeicons: needs fonttools (pip install fonttools)")

    work = os.path.join(ROOT, "build", "nukeicons")
    os.makedirs(work, exist_ok=True)
    zip_path = fetch(NF_ZIP, os.path.join(work, "nf.zip"))
    names_path = fetch(NF_NAMES, os.path.join(work, "glyphnames.json"))
    src_ttf = os.path.join(work, "SymbolsNerdFont-Regular.ttf")
    if not os.path.exists(src_ttf):
        with zipfile.ZipFile(zip_path) as z:
            open(src_ttf, "wb").write(z.read("SymbolsNerdFont-Regular.ttf"))

    names = json.load(open(names_path, encoding="utf-8"))
    missing = [g for _, g in ICONS if g not in names]
    if missing:
        raise SystemExit("nukeicons: unknown glyph(s): %s" % ", ".join(missing))
    wanted = [(k, int(names[g]["code"], 16)) for k, g in ICONS]

    opts = subset.Options()
    opts.notdef_outline = True
    opts.drop_tables += ["DSIG"]
    font = subset.load_font(src_ttf, opts)
    ss = subset.Subsetter(options=opts)
    ss.populate(unicodes=sorted({c for _, c in wanted}))
    ss.subset(font)
    stage = os.path.join(work, "stage.ttf")
    subset.save_font(font, stage, opts)

    font = TTFont(stage)
    old = font.getBestCmap()
    mapping, out = {}, []
    for i, (name, code) in enumerate(wanted):
        mapping[BASE + i] = old[code]
        out.append((name, BASE + i))
    cmap = newTable("cmap")
    cmap.tableVersion = 0
    sub = CmapSubtable.newSubtable(12)
    sub.platformID, sub.platEncID, sub.format, sub.reserved = 3, 10, 12, 0
    sub.length, sub.language, sub.nGroups = 0, 0, 0
    sub.cmap = mapping
    cmap.tables = [sub]
    font["cmap"] = cmap
    for nid in (1, 4, 6):
        font["name"].setName("NukeFileIcons", nid, 3, 1, 0x409)
    ttf_out = os.path.join(ROOT, "NukeImGui", "assets", "nukefileicons.ttf")
    font.save(ttf_out)

    bs = chr(92)
    utf8 = lambda cp: "".join(bs + "x%02x" % b for b in chr(cp).encode("utf-8"))
    w = max(len(n) for n, _ in out)
    L = [
        "#pragma once",
        "#ifndef NUKEE_ICONS_FILE_TYPES_H",
        "#define NUKEE_ICONS_FILE_TYPES_H",
        "",
        "// The glyph vocabulary a file type can name when it registers itself",
        "// (AssetCreator::icon / RegisterFileIcon): source files use the Seti-UI set — the same",
        "// glyphs VS Code's file explorer draws — and asset kinds use the Font Awesome / Octicons /",
        "// Codicons subsets. All of it is subset out of the Nerd Fonts symbols font (MIT) and",
        "// RE-MAPPED into plane 15: the source codepoints overlap Lucide's range, and two merged",
        "// fonts cannot share a slot. Needs IMGUI_USE_WCHAR32; the editor merges",
        "// fonts/nukefileicons.ttf over the range below.",
        "//",
        "// GENERATED by NukeUtils/nukeicons.py — do not edit by hand.",
        "",
        '#define FONT_ICON_FILE_NAME_FT "nukefileicons.ttf"',
        "",
        "#define ICON_MIN_FT 0x%x" % out[0][1],
        "#define ICON_MAX_FT 0x%x" % out[-1][1],
        "",
    ]
    for name, cp in out:
        L.append('#define ICON_FT_%s%s "%s"   // U+%X' % (name, " " * (w - len(name)), utf8(cp), cp))
    L += ["", "#endif // !NUKEE_ICONS_FILE_TYPES_H", ""]
    hdr = os.path.join(ROOT, "NukeEngine", "include", "interface", "IconsFileTypes.h")
    io.open(hdr, "w", encoding="utf-8", newline="\n").write("\n".join(L))
    print("nukeicons: %d glyphs, U+%X-U+%X" % (len(out), out[0][1], out[-1][1]))
    print("  ->", ttf_out)
    print("  ->", hdr)


if __name__ == "__main__":
    sys.exit(main())
