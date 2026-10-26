#!/usr/bin/env python3
"""Regenerate the Liquid Metal mirror layer (<style id="xbook-liquid-metal-mirror">) in index.html.

For every rule (outside Classic and the Metal blocks) that paints a page canvas/scene, defines a
Liquid Glass surface token, or paints the Liquid Glass CTA gradient, emit the same selector gated by
:root[data-xbook-style="metal"] with the Metal value, and write the block just before
<style id="xbook-liquid-metal">. Run after changing Liquid Glass CSS:

    python3 scripts/liquid-metal-mirror.py index.html
"""
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "index.html"
html = open(SRC, encoding="utf-8").read()
html = re.sub(r'  <style id="xbook-liquid-metal-mirror">.*?</style>\n', "", html, flags=re.S)

SKIP_IDS = {"xbook-classic", "xbook-liquid-metal-labs", "xbook-liquid-metal", "xbook-liquid-metal-mirror", "xbook-first-paint"}
head = html[: html.index("</head>")]
blocks = []
for m in re.finditer(r"<style([^>]*)>(.*?)</style>", head, re.S):
    attrs, css = m.group(1), m.group(2)
    idm = re.search(r'id="([^"]+)"', attrs)
    if idm and idm.group(1) in SKIP_IDS:
        continue
    blocks.append(css)

def strip_comments(css):
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)

def parse(css, i=0):
    """Return (items, i). item = ('rule', sel, decls) | ('at', prelude, items)."""
    items = []
    buf = ""
    n = len(css)
    while i < n:
        c = css[i]
        if c == "{":
            prelude = buf.strip()
            buf = ""
            if prelude.startswith("@"):
                if re.match(r"@(media|supports|layer|container)\b", prelude):
                    sub, i = parse(css, i + 1)
                    items.append(("at", prelude, sub))
                    continue
                # @keyframes / @font-face etc: skip block
                depth, i = 1, i + 1
                while i < n and depth:
                    if css[i] == "{":
                        depth += 1
                    elif css[i] == "}":
                        depth -= 1
                    i += 1
                continue
            # declaration block
            j = css.index("}", i)
            items.append(("rule", prelude, css[i + 1 : j]))
            i = j + 1
            continue
        if c == "}":
            return items, i + 1
        if c == ";" and buf.strip().startswith("@"):
            buf = ""
            i += 1
            continue
        buf += c
        i += 1
    return items, i

def split_top(s, sep=","):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [x.strip() for x in out if x.strip()]

def decls_of(text):
    out = []
    for d in split_top(text, ";"):
        if ":" not in d:
            continue
        k, v = d.split(":", 1)
        k = k.strip()
        v = v.strip()
        imp = bool(re.search(r"!\s*important\s*$", v))
        v = re.sub(r"!\s*important\s*$", "", v).strip()
        out.append((k, v, imp))
    return out

M = ':root[data-xbook-style="metal"]'

def gate(sel):
    s = sel.strip()
    if s.startswith(":root"):
        return M + s[len(":root"):]
    if re.match(r"html\b", s):
        return 'html[data-xbook-style="metal"]' + s[4:]
    if s.startswith(":is(html") or s.startswith(":where(html") or s.startswith(":is(:root"):
        return M + s
    if s.startswith("*") or s.startswith("::"):
        return M + " " + s
    return M + " " + s

def top_combinator_split(sel):
    """True if the selector's subject is the root element (no descendant combinator at top level)."""
    depth = 0
    for ch in sel.strip():
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif depth == 0 and ch in " >~+":
            return False
    return True

def subject_is_root(sel):
    s = sel.strip()
    return (s.startswith(":root") or re.match(r"html\b", s) is not None) and top_combinator_split(s)

def subject_is_body(sel):
    s = sel.strip()
    parts = re.split(r"\s+(?![^()]*\))", s)  # rough: last compound
    last = parts[-1] if parts else s
    return last.startswith("body")

CANVAS_LITERAL = re.compile(r"^(#0b1426|#0e2350|#0d0f14)$", re.I)
SHEET_RE = re.compile(r"(sheet|modal|dialog|popover|picker|drawer|overlay|panel(?!s))", re.I)
CANVAS_RE = re.compile(r"var\(--xb-(scene-canvas|[a-z]+-canvas|[a-z]+-scene)\b|xbook-liquid-scene-(dark|light)\.webp")
CTA_RE = re.compile(r"#6aa8ff\s+0%,\s*#3d82ff|#6aa4ff\s+0%,\s*#3474ea|#5b9bff\s+0%,\s*#3d82ff")
TOKEN_MAP = [
    (re.compile(r"^--xb-scene-canvas(-dark|-light)?$"), "transparent"),
    (re.compile(r"^--xb-[a-z]+-canvas$"), "transparent"),
    (re.compile(r"^--xb-[a-z]+-scene$"), "none"),
    (re.compile(r"^--xb-[a-z]+-(glass|card)-fill$"), "var(--xlm-fill)"),
    (re.compile(r"^--xb-[a-z]+-(glass|card)-border$"), "var(--xlm-border)"),
    (re.compile(r"^--xb-[a-z]+-(glass|card)-highlight$"), "var(--xlm-highlight)"),
    (re.compile(r"^--xb-[a-z]+-(glass|card)-shadow$"), "var(--xlm-shadow)"),
    (re.compile(r"^--xb-[a-z]+-nav-fill$"), "var(--xlm-nav-fill)"),
    (re.compile(r"^--xb-[a-z]+-nav-border$"), "rgba(141, 181, 255, 0.14)"),
    (re.compile(r"^--xb-[a-z]+-nav-shadow$"), "var(--xlm-nav-shadow)"),
    (re.compile(r"^--xb-[a-z]+-cta$"), "var(--xlm-cta)"),
    (re.compile(r"^--xb-[a-z]+-cta-shadow$"), "var(--xlm-cta-shadow)"),
    (re.compile(r"^--xb-[a-z]+-cta-border$"), "rgba(0, 12, 48, 0.7)"),
    (re.compile(r"^--xb-[a-z]+-row-line$"), "var(--xlm-line)"),
    (re.compile(r"^--xb-[a-z]+-icon-fill$"), "var(--xlm-icon-fill)"),
]
# Text tokens: only dark-scoped definitions (light ones would flip text on light surfaces).
TEXT_MAP = [
    (re.compile(r"^--xb-[a-z]+-muted$"), "var(--xlm-muted)"),
    (re.compile(r"^--xb-text-secondary$"), "var(--xlm-muted)"),
]

stats = {"rules": 0, "canvas": 0, "tokens": 0, "cta": 0}

def is_dark_selector(sel):
    return 'data-xbook-theme="dark"' in sel or "app-theme-dark" in sel

def transform_rule(sel, text):
    decls = decls_of(text)
    out = []
    sels = split_top(sel)
    dark = all(is_dark_selector(s) for s in sels)
    lightonly = any(":not([data-xbook-theme=\"dark\"])" in s for s in sels)
    if lightonly:
        return None
    has_cta = False
    for k, v, imp in decls:
        kl = k.lower()
        if kl in ("background", "background-color", "background-image") and (
            (CANVAS_RE.search(v) and "color-mix" not in v) or CANVAS_LITERAL.match(v)
        ):
            out.append(("__canvas__", kl))
            stats["canvas"] += 1
            continue
        if kl in ("background", "background-image") and CTA_RE.search(v):
            out.append(("background", "var(--xlm-cta)", True))
            has_cta = True
            stats["cta"] += 1
            continue
        if kl.startswith("--"):
            for rx, val in TOKEN_MAP:
                if rx.match(kl):
                    out.append((kl, val, imp))
                    stats["tokens"] += 1
                    break
            else:
                if dark:
                    for rx, val in TEXT_MAP:
                        if rx.match(kl):
                            out.append((kl, val, imp))
                            stats["tokens"] += 1
                            break
    if has_cta:
        out.append(("box-shadow", "var(--xlm-cta-shadow)", True))
        out.append(("border-color", "transparent", True))
    if not out:
        return None
    # Canvas declarations depend on the subject: root keeps the navy canvas, everything else clears.
    canvas = [o for o in out if o[0] == "__canvas__"]
    rest = [o for o in out if o[0] != "__canvas__"]
    pieces = []
    if canvas:
        def last_compound(s):
            return re.split(r"\s+(?![^()]*\))", s.strip())[-1]
        root_sels = [s for s in sels if subject_is_root(s)]
        rest_sels = [s for s in sels if not subject_is_root(s)]
        # Sheets, panels and the loading overlay sit above content: give them solid navy glass.
        sheet_sels = [s for s in rest_sels if SHEET_RE.search(last_compound(s))]
        clear_sels = [s for s in rest_sels if s not in sheet_sels]
        if root_sels:
            pieces.append((root_sels, [("background", "#030a1e", True)]))
        if sheet_sels:
            pieces.append((sheet_sels, [("background", "var(--xlm-sheet-fill)", True)]))
        if clear_sels:
            pieces.append((clear_sels, [("background", "transparent", True)]))
    if rest:
        pieces.append((sels, rest))
    css = []
    for ss, ds in pieces:
        gated = ",\n".join(gate(s) for s in ss)
        body = "\n".join("  %s: %s%s;" % (k, v, " !important" if imp else "") for k, v, imp in ds)
        css.append("%s {\n%s\n}" % (gated, body))
        stats["rules"] += 1
    return "\n".join(css)

def walk(items):
    out = []
    for it in items:
        if it[0] == "rule":
            r = transform_rule(it[1], it[2])
            if r:
                out.append(r)
        else:
            prelude = it[1]
            if "prefers-color-scheme: light" in prelude:
                continue
            sub = walk(it[2])
            if sub:
                out.append("%s {\n%s\n}" % (prelude, "\n".join(sub)))
    return out

result = []
for css in blocks:
    items, _ = parse(strip_comments(css))
    result.extend(walk(items))

header = (
    "  <style id=\"xbook-liquid-metal-mirror\">\n"
    "    /* XBOOK Liquid Metal — generated mirror of the Liquid Glass surface layer.\n"
    "       Each rule repeats an existing Liquid Glass selector, gated by html[data-xbook-style=\"metal\"]:\n"
    "       page canvases/scenes clear so the shared live background shows through, glass/nav/CTA\n"
    "       tokens take the Metal values. Generated; edit the hand-written block that follows instead. */\n"
)
block = header + "\n".join(result) + "\n  </style>\n"
anchor = '  <style id="xbook-liquid-metal">'
i = html.index(anchor)
open(SRC, "w", encoding="utf-8").write(html[:i] + block + html[i:])
print(stats, file=sys.stderr)
