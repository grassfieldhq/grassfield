#!/usr/bin/env python3
"""Gate A2, exact token calculation (L0, deterministic, no compositor): the PRIMARY evidence of contrast.

  python3 -I tests/visual/test_contrast_tokens.py          unit tests + the table (also run by scripts/dev/test.sh)
  python3 -I tests/visual/test_contrast_tokens.py --table  only print the table

For every text role of tests/visual/contrast-roles.json the effective text colour (token colour x the item's opacity, composited over
the backdrop) is compared with the backdrop (WCAG 2.x relative luminance) for both appearances, transparency 0, 0.25, 0.4, 0.6
(material default 0.25; master-prompt 5.5: every value <= 0.6 must pass) and every worst-case flat wallpaper colour: black, white,
mid-grey, saturated red and blue and the extreme colours of the five contrast wallpapers (contrast.py: white, black, grey, the yellow/
green noise palette, the black/white checker). Blur makes the backdrop a local average, so flat colours bound it. Compositing is done in
sRGB, as Qt does. Backdrops:
  material       tint at alpha 1 - t * (1 - material.tintAlphaMin), then (worst case) with the fill overlay (a tile or field fill)
  window         an opaque app window: color.windowBackground and color.sidebarFill, bare and under a rimmed capsule's fill (the text
                 colour at toolbar.fieldFillOpacity, or white at toolbar.capsuleFillOpacity); the same at every transparency and wallpaper
  accent         the solid accent colour
  selection      the solid selection colour: the light appearance's accent in the light appearance, color.selectionDark in the dark one (Appearance.accentedDark/Light,
                 Accent.withSelection), the fill of a selected row, a default button or a checked box
  rename-field   colors.fieldFill at desktopIcon.renameFillOpacity over the wallpaper (the inline rename field)
  bar-light-tone / bar-dark-tone  the adaptive menu bar (shell/services/BarTone.qml): the opaque wallpaper itself, only for the
                 wallpaper colours the tone can be chosen for (light text up to menubar.toneDarkAbove, dark text from
                 menubar.toneLightBelow); the faint shadow is decoration and not counted
  desktop-label  the label shadow colour at its core alpha (desktopIcon.labelShadowOpacity) over the wallpaper: white text against the
                 shadow taken as fully opaque behind the glyph. That is the BEST case (19:1), a ceiling that only proves the token
                 colours still contrast; the rendered contrast of the labels over a white wallpaper (blurred shadow, 4.8:1) is
                 measured by tests/visual/contrast.sh --surfaces desktop, which is the evidence for that surface.
  lock           the lock screen: the shadow-colour scrim at lock.dimOpacity over the (blurred) wallpaper; the lock always uses the
                 dark palette and no material, so both appearances and every transparency give the same values
  lock-field     lock + the dark password field fill (shadow colour at lock.fieldFillOpacity)
  lock-avatar    lock + the light avatar disc (dark-palette fill at lock.avatarFillOpacity)
  lock-submit    lock-field + the return arrow disc (text colour at material.highlightOpacity, and x2 when hovered: worst of the two)
  lock-selection the opaque dark-palette accent band behind selected dots in the password field (Shift+arrows, Ctrl+A); the band
                 itself is checked against lock-field as a graphic (3:1)
                 The lock model is checked against LockView.qml and PasswordField.qml (test_lock_model_matches_the_qml); the text
                 shadow is decoration and not counted.
The role table is cross-checked against the QML (tests/visual/qml_scan.py, a structural scan: palette aliases, colors["textSecondary"],
opacity on any ancestor, one-line items, Qt.darker/lighter/alpha/tint/rgba, `opacity :`): a new secondary-text, danger-colour, derived
text-colour (alpha), computed-palette-key (dynamic) or text-opacity use without a role fails. Inside shell/security/ every palette
read counts (primary text and backdrop colours: the lock and the authorization dialog draw their own backdrops).
Tint alpha: material.tintAlphaMin at transparency 1, linear in between, clamped to material.tintAlphaClamp up to transparency
material.tintClampUntil (ui/Grassfield/Ui/Appearance.qml tintAlpha()); at the default 0.25 the tint is 0.85, unclamped.
"""
import importlib.util
import json
import math
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("contrast", os.path.join(HERE, "contrast.py"))
contrast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contrast)

TRANSPARENCIES = (0.0, 0.25, 0.4, 0.6)
LOCK_BACKDROPS = ("lock", "lock-field", "lock-avatar", "lock-submit", "lock-selection")
BAR_TONES = ("bar-light-tone", "bar-dark-tone")
APPEARANCES = ("dark", "light")
THRESHOLD = {"text": 4.5, "large": 3.0, "icon": 3.0}
# Flat worst-case backdrops: black, white, mid-grey, saturated red and blue, the noise palette (yellow/greens). The checker (black/white
# 2 px) and the plain wallpapers are covered by black, white and grey.
WALLPAPER_COLORS = [(0, 0, 0), (255, 255, 255), (128, 128, 128), (255, 0, 0), (0, 0, 255)] + list(contrast.NOISE_PALETTE)


def load_tokens():
    with open(os.path.join(ROOT, "ui", "tokens", "tokens.json")) as f:
        return json.load(f)


def load_roles():
    with open(os.path.join(HERE, "contrast-roles.json")) as f:
        return json.load(f)["roles"]


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def round_half_up(x):
    """Math.round of JavaScript (halves go up)."""
    return int(math.floor(x + 0.5))


def over(fg, alpha, bg):
    """fg at alpha composited over the opaque bg (sRGB channels 0-255, floats)."""
    return tuple(fg[i] * alpha + bg[i] * (1 - alpha) for i in range(3))


def lum(rgb):
    return contrast.luminance(rgb)


def wcag(a, b):
    return contrast.ratio(lum(a), lum(b))


def grey_of(l):
    """The sRGB grey (0-255) of a relative luminance (mirror of GlassTint.greyOf)."""
    l = max(0.0, min(1.0, l))
    v = l * 12.92 if l <= 0.03928 / 12.92 else 1.055 * l ** (1 / 2.4) - 0.055
    return (v * 255, v * 255, v * 255)


GLASS_WEIGHTS = (0.2126, 0.7152, 0.0722)


def glass_backdrops(l):
    """Mirror of GlassTint.backdropsOf: the grey of luminance l and the linear-light vertices of the colours of that luminance."""
    l = max(0.0, min(1.0, l))
    out = [grey_of(l)]
    for c in range(3):
        others = [k for k in range(3) if k != c]
        for bits in range(4):
            x = [0.0, 0.0, 0.0]
            x[others[0]] = float(bits & 1)
            x[others[1]] = float((bits >> 1) & 1)
            free = (l - GLASS_WEIGHTS[others[0]] * x[others[0]] - GLASS_WEIGHTS[others[1]] * x[others[1]]) / GLASS_WEIGHTS[c]
            if free < -1e-9 or free > 1 + 1e-9:
                continue
            x[c] = max(0.0, min(1.0, free))
            out.append(tuple(grey_of(v)[0] for v in x))
    return out


def glass_floor(tok, appearance, lum_min, lum_max, need):
    """Mirror of GlassTint.floorAlpha for the appearance's tint, text and secondary text, with and without the fill overlay."""
    tint = tok.color("colors", appearance, "materialTint")
    fill = tok.color("colors", appearance, "fill")
    inks = [tok.color("colors", appearance, "text"), tok.color("colors", appearance, "textSecondary")]
    for i in range(101):
        a = i / 100
        ok = True
        for back in glass_backdrops(lum_min) + glass_backdrops(lum_max):
            base = over(tint, a, back)
            filled = over(fill, tok.path("material.fillOpacity"), base)
            if any(wcag(ink, base) < need or wcag(ink, filled) < need for ink in inks):
                ok = False
                break
        if ok:
            return a
    return 1.0


def glass_target(target, t, default):
    x = max(0.0, min(1.0, t))
    return 1 - (1 - target) * x / default if x <= default else target * (1 - (x - default) / (1 - default))


_GLASS_CACHE = {}


def glass_alpha(tok, appearance, target, t, backdrop):
    """Mirror of GlassTint.alpha: backdrop (lum_min, lum_max) or None for the worst case. Cached: the search is slow and the
    answer depends only on the appearance's tokens, the target, the slider value and the backdrop."""
    key = (id(tok.data), appearance, target, t, backdrop)
    if key not in _GLASS_CACHE:
        if t <= 0:
            _GLASS_CACHE[key] = 1.0
        else:
            if backdrop is None:
                floor = glass_floor(tok, appearance, 0.0, 1.0, 4.5)
            else:
                floor = glass_floor(tok, appearance, backdrop[0], backdrop[1], 4.5 + tok.path("glass.contrastMargin"))
            _GLASS_CACHE[key] = max(floor, glass_target(target, t, tok.path("material.defaultTransparency")))
    return _GLASS_CACHE[key]


class Tokens:
    def __init__(self, data):
        self.data = data

    def path(self, dotted):
        node = self.data
        for part in dotted.split("."):
            node = node[part]
        return node["value"]

    def color(self, palette, appearance, name):
        # palette "colors" follows the appearance; "darkColors" / "lightColors" are always the dark / light palette.
        # selection / selectionText (mirror of Accent.selectionPair): the light palette's accent and accentText in the light
        # appearance, the color.selectionDark pair of the accent in the dark one.
        fixed = {"darkColors": "dark", "lightColors": "light"}
        if name == "accentGlass":
            # Mirror of Accent.glassInk: the accent ink mixed toward the palette's text colour (sRGB, rounded to a channel value).
            ap = fixed.get(palette, appearance)
            ink = self.color(palette, appearance, "accentInk")
            text = self.color(palette, appearance, "text")
            mix = self.path("glass.accentInkMix" + ap.capitalize())
            # The same arithmetic as the JS, step for step: channels as v / 255, mixed, times 255, Math.round.
            return tuple(round_half_up((ink[i] / 255 + (text[i] / 255 - ink[i] / 255) * mix) * 255) for i in range(3))
        if name in ("selection", "selectionText"):
            if fixed.get(palette, appearance) == "light":
                return self.color("lightColors", "light", "accent" if name == "selection" else "accentText")
            return hex_rgb(self.path("color.selectionDark.%s%s" % (self.accent_name(), "Text" if name == "selectionText" else "")))
        if name == "accentInk":
            # Text and glyphs drawn in the accent colour (mirror of Accent.resolve): the palette's accent (the Grassfield
            # green holds 4.5:1 on its grounds).
            return self.color(palette, appearance, "accent")
        return hex_rgb(self.path("color.%s.%s" % (fixed.get(palette, appearance), name)))

    def accent_name(self):
        return "multicolor"

    def number(self, ref):
        return float(ref) if isinstance(ref, (int, float)) else float(self.path(ref))

    def tint_alpha(self, t):
        """Mirror of Appearance.tintAlpha (checked against the QML source by test_tint_alpha_matches_appearance_qml)."""
        mn = self.path("material.tintAlphaMin")
        clamp = self.path("material.tintAlphaClamp")
        until = self.path("material.tintClampUntil")
        t = max(0.0, min(1.0, t))
        linear = 1 - t * (1 - mn)
        if t <= until:
            return max(linear, clamp)
        return clamp + (mn - clamp) * (t - until) / (1 - until)


def material_variants(tok, pal, appearance, base):
    """The tint over the backdrop as it is, and under the fills a tile, a field or a row draws on glass (material.fillOpacity;
    in the light appearance the chip, button and well fills of Appearance.chipFill, buttonFill, lightWellFill)."""
    fill = tok.color(pal, appearance, "fill")
    out = [base, over(fill, tok.path("material.fillOpacity"), base)]
    if pal == "colors" and appearance == "light":
        chip = tok.color(pal, appearance, "chipFill")
        out += [over(chip, tok.path("material.chipFillOpacityLight"), base),
                over(fill, tok.path("material.fillOpacityLight"), base),
                over(chip, tok.path("material.wellFillOpacityLight"), base)]
    return out


GLASS_CLASSES = ("menu", "notification", "controls", "apps", "gallery", "widgets")


def backdrops(tok, role, appearance, t, wallpaper):
    """Backdrop colours (opaque RGB) behind the text for one role/appearance/transparency/wallpaper colour."""
    kind = role["backdrop"]
    pal = "darkColors" if role["fg"].startswith("darkColors") else "colors"
    if kind in BAR_TONES:
        # The adaptive menu bar (BarTone): the wallpaper under the bare bar, for the wallpapers the tone can be chosen for. Light text
        # is shown up to menubar.toneDarkAbove and dark text from menubar.toneLightBelow (the hysteresis band shows either).
        l = lum(wallpaper)
        if kind == "bar-light-tone":
            return [wallpaper] if l <= tok.path("menubar.toneDarkAbove") else []
        return [wallpaper] if l >= tok.path("menubar.toneLightBelow") else []
    if kind == "material":
        return material_variants(tok, pal, appearance, over(tok.color(pal, appearance, "materialTint"), tok.tint_alpha(t), wallpaper))
    if kind == "glass":
        # The shell's real glass (Appearance.glassAlpha, GlassTint.alpha): every glass class at the slider value t, over the
        # wallpaper colour with the tint alpha the class really gets, in the two cases the shell can be in: the backdrop unknown
        # (the worst case, black to white) and the backdrop known to be this colour (its own luminance range). Each with the fills
        # a tile, a field or a hovered row draws over the tint. The tint alpha protects the text and the secondary text only, so
        # it is thinner than tintAlpha(t) says: 0.79 in the light appearance over a window, not 0.85.
        out = []
        for cls in GLASS_CLASSES:
            target = tok.path("glass." + cls)
            known = (lum(wallpaper), lum(wallpaper))
            for backdrop in (None, known):
                a = glass_alpha(tok, appearance, target, t, backdrop)
                out += material_variants(tok, pal, appearance, over(tok.color(pal, appearance, "materialTint"), a, wallpaper))
        return out
    if kind in ("window", "window-pane"):
        # window-pane: the same without the search field's grey fill (accent text never sits in a field: a field's own text
        # is the text roles', its selection the selection's); the field is a flat grey since ADR-0024's 2026-11-03 amendment.
        # An opaque app window (Settings, the Store, Search's clipboard page): the window and the flush sidebar, each bare and
        # under a rimmed capsule's fill (RimmedCapsule: the text colour at the field or the toolbar opacity); the transparency
        # and the wallpaper do not reach it.
        # A field tints with the text colour, a capsule is white (colors.knob); the dark appearance has its own opacities.
        text = tok.color(pal, appearance, "text")
        white = tok.color(pal, appearance, "knob")
        sfx = "Dark" if appearance == "dark" else ""
        out = []
        for base_name in ("windowBackground", "sidebarFill"):
            base = tok.color(pal, appearance, base_name)
            out.append(base)
            if kind == "window":
                out.append(over(text, tok.path("toolbar.fieldFillOpacity" + sfx), base))
            out.append(over(white, tok.path("toolbar.capsuleFillOpacity" + sfx), base))
        return out
    if kind == "accent":
        return [tok.color(pal, appearance, "accent")]
    if kind == "selection":
        return [tok.color(pal, appearance, "selection")]
    if kind == "rename-field":
        return [over(tok.color("colors", appearance, "fieldFill"), tok.path("desktopIcon.renameFillOpacity"), wallpaper)]
    if kind == "weather-sky":
        # The Weather widget's opaque skies (ADR-0045 OC-14, widget.weatherSky*): each gradient's two ends, the same in both
        # appearances and at every transparency. Every channel grows from top to bottom, so the luminance does too and the
        # ends are the extremes of the gradient.
        return [hex_rgb(tok.path("widget.weatherSky%s%s" % (sky, end))) for sky in ("Day", "Night", "Cloudy") for end in ("Top", "Bottom")]
    if kind == "desktop-label":
        return [over(tok.color("darkColors", appearance, "shadow"), tok.path("desktopIcon.labelShadowOpacity"), wallpaper)]
    if kind == "lock-selection":
        # Opaque band: whatever lies under it (field, scrim, wallpaper) is hidden.
        return [tok.color("darkColors", appearance, "accent")]
    if kind in LOCK_BACKDROPS:
        shadow = tok.color("darkColors", appearance, "shadow")
        base = over(shadow, tok.path("lock.dimOpacity"), wallpaper)
        if kind == "lock":
            return [base]
        if kind == "lock-avatar":
            return [over(tok.color("darkColors", appearance, "fill"), tok.path("lock.avatarFillOpacity"), base)]
        field = over(shadow, tok.path("lock.fieldFillOpacity"), base)
        if kind == "lock-field":
            return [field]
        text = tok.color("darkColors", appearance, "text")
        hl = tok.path("material.highlightOpacity")
        return [over(text, hl, field), over(text, 2 * hl, field)]
    raise ValueError("unknown backdrop " + kind)


def role_ratio(tok, role, appearance, t, wallpaper):
    """Worst ratio of one role over the backdrop variants for one combination."""
    pal, name = role["fg"].split(".")
    fg = tok.color(pal, appearance, name)
    alpha = 1.0
    for o in role.get("opacity", []):
        alpha *= tok.number(o)
    worst = None  # None: the role has no backdrop for this wallpaper (an adaptive bar tone is never chosen for it)
    for bg in backdrops(tok, role, appearance, t, wallpaper):
        r = wcag(over(fg, alpha, bg), bg)
        worst = r if worst is None else min(worst, r)
    return worst


def role_table(tok, roles):
    """{role id: {(appearance, t): (min ratio, wallpaper colour)}}"""
    table = {}
    for role in roles:
        cells = {}
        for ap in APPEARANCES:
            for t in TRANSPARENCIES:
                best = None
                for wp in WALLPAPER_COLORS:
                    r = role_ratio(tok, role, ap, t, wp)
                    if r is not None and (best is None or r < best[0]):
                        best = (r, wp)
                cells[(ap, t)] = best
        table[role["id"]] = cells
    return table


def print_table(tok, roles, table):
    head = "%-40s %5s | %s | %s" % ("role (min over 9 wallpaper colours)", "need",
                                    " ".join("d.%-4s" % t for t in TRANSPARENCIES), " ".join("l.%-4s" % t for t in TRANSPARENCIES))
    print(head)
    print("-" * len(head))
    for role in roles:
        thr = THRESHOLD[role["kind"]]
        cells = table[role["id"]]
        cols = []
        for ap in APPEARANCES:
            cols.append(" ".join("%5.2f%s" % (cells[(ap, t)][0], "*" if cells[(ap, t)][0] < thr else " ") for t in TRANSPARENCIES))
        lo = min(c[0] for c in cells.values())
        tag = "  exempt: " + role["exempt"][:48] if role.get("exempt") else ""
        print("%-40s %5.1f | %s | %s  min %.2f%s" % (role["id"][:40], thr, cols[0], cols[1], lo, tag))
    print("columns: d = dark, l = light appearance; transparency %s; '*' = below the threshold." % ", ".join(str(t) for t in TRANSPARENCIES))


# ---- QML cross-check ------------------------------------------------------------------------------------

_scan_spec = importlib.util.spec_from_file_location("qml_scan", os.path.join(HERE, "qml_scan.py"))
qml_scan = importlib.util.module_from_spec(_scan_spec)
_scan_spec.loader.exec_module(qml_scan)


def scan_qml():
    """{(relative file, class): count} of the contrast-relevant uses in shell/ and ui/Grassfield/ (see qml_scan.py)."""
    return qml_scan.scan_tree(ROOT)


def cross_check(scan, declared):
    """Problems of a scan against the declared sites: uses without a role (or with another count) and stale declarations."""
    missing = sorted("%s [%s]: QML has %d, roles declare %d" % (k[0], k[1], scan[k], declared.get(k, 0))
                     for k in scan if scan[k] != declared.get(k, 0))
    stale = sorted("%s [%s]: roles declare %d, QML has none" % (k[0], k[1], declared[k]) for k in declared if k not in scan)
    return missing + stale


# One sample per form the scanner must catch (each makes the cross-check FAIL when no role declares it), and the forms it must not flag.
SELFTEST_SAMPLES = {
    "palette alias": 'Item {\n  readonly property var pal: Appearance.colors\n  Text { color: pal.textSecondary }\n}\n',
    "palette alias in a ternary": 'Item {\n  readonly property var pal: Appearance.dark ? Tokens.colorDark : Tokens.colorLight\n'
                                  '  Text { color: pal.danger }\n}\n',
    "bracket access": 'Text { color: Appearance.colors["textSecondary"] }\n',
    "bracket access, single quotes on an alias": "Item {\n  property var c: Appearance.darkColors\n  Text { color: c['danger'] }\n}\n",
    "opacity on a parent": 'Item {\n  opacity: 0.6\n  Column {\n    Text { text: "x" }\n  }\n}\n',
    "opacity on a grandparent, computed": 'Item {\n  opacity: shown ? 1 : 0.4\n  Row {\n    Item {\n      Text { text: "x" }\n    }\n  }\n}\n',
    "one-line Text with opacity": 'Item {\n  Text { text: "x"; opacity: 0.5 }\n}\n',
    "one-line Text, opacity first": 'Item { Text{opacity:0.5;text:"x"} }\n',
    "Qt.darker": 'Text { color: Qt.darker(Appearance.colors.text, 1.4) }\n',
    "Qt.lighter of an alias": 'Item {\n  property var pal: Appearance.colors\n  Text { color: Qt.lighter(pal.text) }\n}\n',
    "Qt.alpha": 'Text { color: Qt.alpha(Appearance.colors.accentText, 0.7) }\n',
    "opacity with a space before the colon": 'Text {\n  text: "x"\n  opacity : 0.5\n}\n',
    "computed palette key": 'Item {\n  property string key: "text"\n  Text { color: Appearance.colors[key] }\n}\n',
    "withAlpha on a multi-line call": 'Text {\n  color: Appearance.withAlpha(\n    Appearance.colors.text, 0.5)\n}\n',
}
# Forms only classified inside shell/security/ (every palette read there counts: primary and backdrop). Each must FAIL the
# cross-check when undeclared there, and none may be flagged outside shell/security/.
SECURITY_SAMPLES = {
    "primary text through root.colors": 'Item {\n  id: root\n  readonly property var colors: Appearance.darkColors\n'
                                        '  Text { color: root.colors.text }\n}\n',
    "primary text through a bare alias": 'Item {\n  property var colors: Tokens.colorDark\n  Text { color: colors.text }\n}\n',
    "primary text with brackets": "Text { color: Tokens.colorDark['text'] }\n",
    "scrim through root.colors": 'Item {\n  id: root\n  readonly property var colors: Appearance.darkColors\n'
                                 '  Rectangle { color: root.colors.shadow; opacity: 0.6 }\n}\n',
    "field fill through withAlpha": 'Item {\n  readonly property var colors: Appearance.darkColors\n'
                                    '  Rectangle { color: Appearance.withAlpha(colors.shadow, 0.45) }\n}\n',
    "surface colour from Tokens": 'Rectangle { color: Tokens.colorDark.shadow }\n',
}
SELFTEST_CLEAN = {
    "opacity 1": 'Item {\n  opacity: 1\n  Text { text: "x"; opacity: 1.0 }\n}\n',
    "commented use": '// Appearance.colors.textSecondary\nItem {\n  /* Text { opacity: 0.5 } */\n}\n',
    "string mentioning the token": 'Item { property string s: "Appearance.colors.textSecondary" }\n',
    "opacity on an item without text": 'Item {\n  opacity: 0.5\n  Rectangle { color: "red" }\n}\n',
    "primary text": 'Text { color: Appearance.colors.text }\n',
}


def declared_sites(roles):
    out = {}
    for role in roles:
        for s in role["sites"]:
            key = (s["file"], s["class"])
            out[key] = out.get(key, 0) + s["count"]
    return out


class AccentTokens(Tokens):
    """The token reader with one `accent.color` applied (mirror of ui/Grassfield/Ui/Accent.js): accent and accentText come
    from color.accentDark / color.accentLight, every other role is unchanged."""

    def __init__(self, data, accent):
        super().__init__(data)
        self.accent = accent

    def accent_name(self):
        return self.accent

    def color(self, palette, appearance, name):
        if self.accent != "multicolor" and name in ("accent", "accentText", "accentInk"):
            fixed = {"darkColors": "dark", "lightColors": "light"}
            ap = fixed.get(palette, appearance)
            # accentInk: in the light appearance the accent's shade in color.accentInkLight where it has one, else the accent.
            if name == "accentInk" and ap == "light" and self.accent in self.data["color"].get("accentInkLight", {}):
                return hex_rgb(self.path("color.accentInkLight.%s" % self.accent))
            key = self.accent + ("Text" if name == "accentText" else "")
            return hex_rgb(self.path("color.accent%s.%s" % (ap.capitalize(), key)))
        return super().color(palette, appearance, name)


class ContrastTokens(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tok = Tokens(load_tokens())
        cls.roles = load_roles()
        cls.table = role_table(cls.tok, cls.roles)

    def test_calculation_sanity(self):
        # Hand-checked: black on white 21, mid-grey (118) on white 4.54, the same colour on itself 1, 50 % black over white is grey 127.5.
        self.assertAlmostEqual(wcag((0, 0, 0), (255, 255, 255)), 21.0, places=6)
        self.assertAlmostEqual(wcag((118, 118, 118), (255, 255, 255)), 4.54, delta=0.01)
        self.assertAlmostEqual(wcag((7, 7, 7), (7, 7, 7)), 1.0, places=9)
        self.assertEqual(over((0, 0, 0), 0.5, (255, 255, 255)), (127.5, 127.5, 127.5))
        # text colour x opacity over the backdrop: 85 % white over mid-grey is lighter grey but never reaches white.
        self.assertLess(wcag(over((255, 255, 255), 0.85, (128, 128, 128)), (128, 128, 128)), wcag((255, 255, 255), (128, 128, 128)))

    def test_opacity_is_part_of_the_colour(self):
        # The old banner body (opacity 0.85 on text) failed on the white wallpaper; the same role at opacity 1 must be better.
        full = {"fg": "colors.text", "backdrop": "material", "kind": "text"}
        faded = dict(full, opacity=[0.85])
        for ap in APPEARANCES:
            self.assertLess(role_ratio(self.tok, faded, ap, 0.6, (255, 255, 255)), role_ratio(self.tok, full, ap, 0.6, (255, 255, 255)))

    def test_tint_alpha_matches_appearance_qml(self):
        # Appearance.tintAlpha(t) = 1 - clamp01(t) * (1 - tintAlphaMin) (ui/Grassfield/Ui/Appearance.qml): same formula here.
        with open(os.path.join(ROOT, "ui", "Grassfield", "Ui", "Appearance.qml")) as f:
            qml = f.read()
        for line in ("const x = clamp01(t);",
                     "const linear = 1 - x * (1 - Tokens.materialTintAlphaMin);",
                     "return Math.max(linear, Tokens.materialTintAlphaClamp);",
                     "return Tokens.materialTintAlphaClamp + (Tokens.materialTintAlphaMin - Tokens.materialTintAlphaClamp) * (x - until) / (1 - until);"):
            self.assertIn(line, qml)
        self.assertIn("const until = Tokens.materialTintClampUntil;", qml)

    def test_frosted_default_and_clamp(self):
        # The material reads as frosted at the default (tint <= 0.85) and the clamp only acts at high transparency.
        self.assertLessEqual(self.tok.tint_alpha(0.25), 0.85 + 1e-9)
        self.assertAlmostEqual(self.tok.tint_alpha(0.25), 1 - 0.25 * (1 - self.tok.path("material.tintAlphaMin")), places=9)
        self.assertEqual(self.tok.tint_alpha(0.0), 1.0)
        self.assertAlmostEqual(self.tok.tint_alpha(1.0), self.tok.path("material.tintAlphaMin"), places=9)
        self.assertGreaterEqual(self.tok.tint_alpha(0.6), self.tok.path("material.tintAlphaClamp") - 1e-9)
        for lo, hi in ((0.0, 0.25), (0.25, 0.4), (0.4, 0.6), (0.6, 1.0)):
            self.assertGreaterEqual(self.tok.tint_alpha(lo), self.tok.tint_alpha(hi))

    def test_every_role_meets_its_threshold(self):
        bad = []
        for role in self.roles:
            if role.get("exempt"):
                continue
            thr = THRESHOLD[role["kind"]]
            for (ap, t), (r, wp) in self.table[role["id"]].items():
                if r < thr:
                    bad.append("%s: %s t=%s over %s: %.2f < %.1f" % (role["id"], ap, t, wp, r, thr))
        self.assertEqual(bad, [], "\n" + "\n".join(bad))

    def test_exempt_roles_state_a_reason(self):
        for role in self.roles:
            if "exempt" in role:
                self.assertGreater(len(role["exempt"]), 20, role["id"])

    def test_role_table_matches_the_qml(self):
        problems = cross_check(scan_qml(), declared_sites(self.roles))
        self.assertEqual(problems, [], "\nadd or update the role in tests/visual/contrast-roles.json:\n" + "\n".join(problems))

    def test_cross_check_selftest_each_form_fails(self):
        # Every form of a contrast-relevant use the scanner must see makes the cross-check FAIL when no role declares it.
        comps = frozenset({"Button"})
        for name, src in SELFTEST_SAMPLES.items():
            scan = qml_scan.scan_source(src, "shell/Sample.qml", comps)
            self.assertNotEqual(cross_check(scan, {}), [], "form not detected: " + name)

    def test_cross_check_selftest_declared_passes_and_clean_forms_do_not_trip(self):
        for name, src in SELFTEST_SAMPLES.items():
            scan = qml_scan.scan_source(src, "shell/Sample.qml", frozenset())
            self.assertEqual(cross_check(scan, dict(scan)), [], name)
        for name, src in SELFTEST_CLEAN.items():
            self.assertEqual(qml_scan.scan_source(src, "shell/Sample.qml", frozenset()), {}, "false positive: " + name)

    def test_cross_check_selftest_security_reads(self):
        # Inside shell/security/ every palette read (primary text, scrim, fill, ...) must be declared; outside it they are not
        # classified (primary text on material is the default "text on material" role).
        for name, src in SECURITY_SAMPLES.items():
            scan = qml_scan.scan_source(src, "shell/security/lock/Sample.qml", frozenset())
            self.assertNotEqual(cross_check(scan, {}), [], "security form not detected: " + name)
            self.assertEqual(cross_check(scan, dict(scan)), [], name)
            self.assertEqual(qml_scan.scan_source(src, "shell/overlay/Sample.qml", frozenset()), {}, "outside shell/security: " + name)
        # A derived text colour stays one `alpha` site (not also primary); textSecondary stays `secondary`.
        src = ('Item {\n  id: root\n  readonly property var colors: Appearance.darkColors\n'
               '  Rectangle { border.color: Appearance.withAlpha(root.colors.text, 0.7) }\n  Text { color: root.colors.textSecondary }\n}\n')
        self.assertEqual(qml_scan.scan_source(src, "shell/security/Sample.qml", frozenset()),
                         {("shell/security/Sample.qml", "alpha"): 1, ("shell/security/Sample.qml", "secondary"): 1})

    def test_lock_roles_are_asserted(self):
        # The lock screen is inside gate A2: its roles exist, none is exempt, and each meets its threshold over every wallpaper colour.
        lock = [r for r in self.roles if r["id"].startswith("lock ")]
        self.assertGreaterEqual(len(lock), 6)
        for role in lock:
            self.assertNotIn("exempt", role, role["id"])
            self.assertIn(role["backdrop"], LOCK_BACKDROPS, role["id"])
            lo = min(r for r, _ in self.table[role["id"]].values())
            self.assertGreaterEqual(lo, THRESHOLD[role["kind"]], role["id"])
        self.assertEqual({r["backdrop"] for r in lock}, set(LOCK_BACKDROPS))
        # The lock does not follow the appearance or the transparency: every column of a lock role is the same.
        for role in lock:
            values = {round(r, 9) for r, _ in self.table[role["id"]].values()}
            self.assertEqual(len(values), 1, role["id"])

    def test_lock_model_matches_the_qml(self):
        # The lock backdrops above mirror these lines; a change in the QML must change the model (and this test) too.
        with open(os.path.join(ROOT, "shell", "security", "lock", "LockView.qml")) as f:
            view = f.read()
        with open(os.path.join(ROOT, "shell", "security", "PasswordField.qml")) as f:
            field = f.read()
        for line in ("readonly property var colors: Appearance.darkColors",
                     # The banded scrim (ADR-0040 step 4a, IQ-W4 A): lock.dimOpacity from the top to the bottom of the date and
                     # clock and from the top of the account column down; the clear band only between them, on the far side
                     # of each feather; all at lock.dimOpacity without room for it.
                     "readonly property color dim: Appearance.withAlpha(root.colors.shadow, Tokens.lockDimOpacity)",
                     "readonly property color clear: Appearance.withAlpha(root.colors.shadow, Tokens.lockScrimClearOpacity)",
                     "readonly property real upperEdge: (dateClock.y + dateClock.height) / Math.max(1, height)",
                     "readonly property real lowerEdge: account.y / Math.max(1, height)",
                     "readonly property real feather: Tokens.lockScrimFeather / Math.max(1, height)",
                     "readonly property bool banded: lowerEdge - upperEdge > 2 * feather",
                     "position: scrim.banded ? scrim.upperEdge : 0\n                color: scrim.dim",
                     "position: scrim.banded ? scrim.upperEdge + scrim.feather : 0\n                color: scrim.banded ? scrim.clear : scrim.dim",
                     "position: scrim.banded ? scrim.lowerEdge - scrim.feather : 1\n                color: scrim.banded ? scrim.clear : scrim.dim",
                     "position: scrim.banded ? scrim.lowerEdge : 1\n                color: scrim.dim",
                     "color: Appearance.withAlpha(root.colors.fill, Tokens.lockAvatarFillOpacity)",
                     "textColor: root.colors.text",
                     "placeholderColor: root.colors.textSecondary",
                     "fillColor: Appearance.withAlpha(root.colors.shadow, Tokens.lockFieldFillOpacity)",
                     # No focus ring on the lock's field (UI audit 2026-11-05 U23): it always has the focus, macOS draws none.
                     "focusRing: false\n",
                     "selectionColor: root.colors.accent\n",
                     "selectedTextColor: root.colors.accentText\n"):
            self.assertIn(line, view)
        for line in ("color: Appearance.withAlpha(root.textColor, submitMouse.containsMouse ? Tokens.materialHighlightOpacity * 2"
                     " : Tokens.materialHighlightOpacity)",
                     "color: root.textColor\n        selectionColor: root.selectionColor\n        selectedTextColor: root.selectedTextColor\n",
                     "property color selectionColor: Appearance.colors.accent\n",
                     "property color selectedTextColor: Appearance.colors.accentText\n",
                     "color: root.placeholderColor",
                     "color: root.fillColor",
                     "visible: root.focusRing && input.activeFocus"):
            self.assertIn(line, field)
        # Every text item on the scrim and the disc uses the primary text colour: date, clock, the user's message, initials,
        # name, error, notice.
        self.assertEqual(view.count("color: root.colors.text\n"), 7)
        # The clear part of the scrim is lighter than the text bands, and only the two middle stops use it.
        self.assertLess(self.tok.path("lock.scrimClearOpacity"), self.tok.path("lock.dimOpacity"))
        self.assertEqual(view.count("scrim.clear"), 2)
        self.assertEqual(view.count("GradientStop {"), 6)
        # The date and clock are in the top column, every other text in the account column: the bands' geometry follows
        # the two columns, so no text lies in the clear band.
        top = view[view.index("id: dateClock"):view.index("id: account")]
        self.assertEqual(top.count("Text {"), 2)
        # The error and notice lines (the two AlertMessage items) carry no layer or effect: a failed effect would hide
        # "Authentication service unavailable" / "Crash recovery unavailable" (R12 review of 0513f6e).
        alerts = [i for i in range(len(view)) if view.startswith("Accessible.role: Accessible.AlertMessage", i)]
        self.assertEqual(len(alerts), 2)
        for at in alerts:
            block = view[view.rfind("Text {", 0, at):at]
            self.assertNotIn("layer.", block)

    def test_lock_password_selection(self):
        # R12 review #3 residual: a selection in the lock's password field drew white dots on the focus ring colour (white at
        # lock.focusRingOpacity), 1.7-2.1:1. As on macOS and in every other field of the shell, the selection is now the accent
        # band with accent-text dots: readable (4.5:1) and the band visible against the field (3:1) over every wallpaper colour.
        dots = next(r for r in self.roles if r["id"] == "lock password selection (dots on the accent band)")
        band = next(r for r in self.roles if r["id"] == "lock password selection band against the field")
        old = {"fg": "darkColors.text", "backdrop": "lock-field", "kind": "text"}
        for wp in WALLPAPER_COLORS:
            self.assertGreaterEqual(role_ratio(self.tok, dots, "dark", 0.25, wp), 4.5, wp)
            self.assertGreaterEqual(role_ratio(self.tok, band, "dark", 0.25, wp), 3.0, wp)
            # Negative control: the old rendering (white dots on the white focus-ring band over the field) stays below 3:1.
            field = backdrops(self.tok, old, "dark", 0.25, wp)[0]
            ring = over(self.tok.color("darkColors", "dark", "text"), self.tok.path("lock.focusRingOpacity"), field)
            self.assertLess(wcag(self.tok.color("darkColors", "dark", "text"), ring), 3.0, wp)

    def test_cross_check_selftest_component_instance_with_opacity(self):
        # An instance of a component that contains text, given an opacity, is a text item with that opacity.
        src = 'Item {\n  Button { opacity: 0.5 }\n}\n'
        self.assertNotEqual(cross_check(qml_scan.scan_source(src, "shell/Sample.qml", frozenset({"Button"})), {}), [])
        self.assertEqual(qml_scan.scan_source(src, "shell/Sample.qml", frozenset()), {})

    def test_role_ids_unique_and_fields_valid(self):
        ids = [r["id"] for r in self.roles]
        self.assertEqual(len(ids), len(set(ids)))
        for r in self.roles:
            self.assertIn(r["kind"], THRESHOLD)
            self.assertIn(r["backdrop"], ("material", "window", "window-pane", "accent", "selection", "rename-field", "desktop-label",
                                          "weather-sky", "glass") + BAR_TONES + LOCK_BACKDROPS)
            for site in r["sites"]:
                self.assertIn(site["class"], ("secondary", "danger", "alpha", "dynamic", "opacity", "opacity-dynamic", "primary",
                                              "backdrop"))
            self.assertRegex(r["fg"], r"^(colors|darkColors|lightColors)\.\w+$")

    def test_desktop_label_survives_white_and_black(self):
        # White label text over its shadow core on pure white and on black (and so over the checker, which is both).
        # Ceiling only (shadow core taken as opaque): the rendered contrast is measured by contrast.sh --surfaces desktop.
        label = next(r for r in self.roles if r["id"].startswith("desktop label ("))
        for wp in ((255, 255, 255), (0, 0, 0)):
            for ap in APPEARANCES:
                self.assertGreaterEqual(role_ratio(self.tok, label, ap, 0.25, wp), 4.5)

    def test_artworks_hold_their_menu_bar_tone(self):
        # ADR-0040 step 2 (gate A2 for the artworks): every palette of the four artworks, light and dark sets, the Grassfield hills at
        # every phase, gives the menu bar a tone that reaches menubar.toneNeededContrast over the whole strip under the bar, with no
        # band, on a display from 720 to 2160 pixels tall. The tone is chosen as BarTone does (the strip's mean luminance against
        # menubar.toneLightBelow and toneDarkAbove; either inside the hysteresis band); the text is the bar's own (the dark
        # palette's text over a dark strip, the light palette's over a light one). The strip: the top of the artwork's gradient,
        # from its first colour towards its second (at `at` of the height, Artwork.js palette().tone); Field Rows: the first four
        # bands, which cross the top edge. The crossfades between two palettes are covered by the band rule
        # (BarToneLogic.artFadeNeedsBand, tests/unit/tst_bartone.qml).
        need = self.tok.path("menubar.toneNeededContrast")
        light_below, dark_above = self.tok.path("menubar.toneLightBelow"), self.tok.path("menubar.toneDarkAbove")
        white_text = self.tok.color("darkColors", "dark", "text")
        black_text = self.tok.color("lightColors", "light", "text")
        bar = self.tok.path("menubar.height")

        def mix(a, b, t):
            return tuple(x + (y - x) * t for x, y in zip(a, b))

        cases = []
        for phase in ("Dawn", "Day", "Evening", "Night"):
            for st in ("Light", "Dark"):
                sky = [hex_rgb(c) for c in self.tok.path("artwork.grassfield%s%sSky" % (phase, st))]
                cases.append(("grassfield %s %s" % (phase, st), sky[0], sky[1], 0.55, None))
        for st in ("Light", "Dark"):
            m = [hex_rgb(c) for c in self.tok.path("artwork.meadow%sSky" % st)]
            cases.append(("meadow %s" % st, m[0], m[1], 1.0, None))
            r = [hex_rgb(c) for c in self.tok.path("artwork.ridgeline%sSky" % st)]
            cases.append(("ridgeline %s" % st, r[0], r[1], 0.6, None))
            bands = [hex_rgb(c) for c in self.tok.path("artwork.rows%s" % st)]
            cases.append(("rows %s" % st, bands[1], bands[2], 1.0, bands[:4]))
        for name, top, nxt, at, extra in cases:
            for height in (720, 1080, 1440, 2160):
                reach = min(1.0, bar / (at * height))
                strip = [mix(top, nxt, reach * k / 4) for k in range(5)] + (extra or [])
                mean = lum(mix(top, nxt, reach / 2))
                tones = ["light"] if mean < light_below else ["dark"] if mean > dark_above else ["light", "dark"]
                for tone in tones:
                    text = white_text if tone == "light" else black_text
                    worst = min(wcag(text, c) for c in strip)
                    self.assertGreaterEqual(worst, need, "%s at %d px: %s text %.2f:1" % (name, height, tone, worst))

    def test_menu_bar_tone_roles_are_asserted(self):
        # The adaptive bar is inside gate A2: white text over every wallpaper colour that picks it, black text over every one that picks
        # the dark foreground; neither is exempt, and every wallpaper colour is covered by at least one tone.
        light = next(r for r in self.roles if r["backdrop"] == "bar-light-tone")
        dark = next(r for r in self.roles if r["backdrop"] == "bar-dark-tone")
        for role in (light, dark):
            self.assertNotIn("exempt", role)
            self.assertGreaterEqual(min(r for r, _ in self.table[role["id"]].values()), THRESHOLD[role["kind"]], role["id"])
        self.assertLess(self.tok.path("menubar.toneLightBelow"), self.tok.path("menubar.toneDarkAbove"))
        for wp in WALLPAPER_COLORS:
            covered = [role_ratio(self.tok, r, "dark", 0.25, wp) for r in (light, dark)]
            self.assertTrue(any(c is not None for c in covered), "no tone for wallpaper %s" % (wp,))
        # Glyphs (icons) are held to the same ratio by the text roles; the thresholds follow from the pure foregrounds.
        self.assertEqual(self.tok.color("darkColors", "dark", "barText"), (255, 255, 255))
        self.assertEqual(self.tok.color("lightColors", "dark", "barText"), (0, 0, 0))

    ACCENTS = ("multicolor", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite")

    def test_every_accent_passes_the_accent_roles(self):
        # appearance.accent: every accent, both appearances, every role that puts text or a graphic on the accent fill
        # (text 4.5:1, the lock band 3:1 against its field) over every wallpaper colour and transparency.
        ids = ("accent text on accent", "apps selected chip text",
               "lock password selection (dots on the accent band)", "lock password selection band against the field",
               "selection text on selection", "text and glyphs in the accent colour on an app window")
        roles = [r for r in self.roles if r["id"] in ids]
        self.assertEqual(len(roles), len(ids))
        for accent in self.ACCENTS:
            tok = AccentTokens(self.tok.data, accent)
            for role in roles:
                need = THRESHOLD[role["kind"]]
                for ap in APPEARANCES:
                    for t in TRANSPARENCIES:
                        for wp in WALLPAPER_COLORS:
                            r = role_ratio(tok, role, ap, t, wp)
                            if r is not None:
                                self.assertGreaterEqual(r, need, "%s / %s / %s t=%s wp=%s: %.2f:1" % (accent, role["id"], ap, t, wp, r))

    # Text and glyphs drawn in the accent colour on glass (Appearance.colors.accentGlass, the legibility-adjusted accent that
    # macOS also draws on vibrancy): every accent holds 4.5:1 on every wallpaper and transparency up to 0.6, in both
    # appearances. The role carries no exemption (gate A2, audit rc7 R7-A11Y-01).
    def test_accent_text_on_glass_holds_4_5(self):
        role = next(r for r in self.roles if r["id"] == "text and glyphs in the accent colour on material")
        self.assertNotIn("exempt", role)
        self.assertEqual(role["fg"], "colors.accentGlass")
        for accent in self.ACCENTS:
            tok = AccentTokens(self.tok.data, accent)
            for ap in APPEARANCES:
                for t in TRANSPARENCIES:
                    for wp in WALLPAPER_COLORS:
                        r = role_ratio(tok, role, ap, t, wp)
                        if r is not None:
                            self.assertGreaterEqual(r, 4.5, "%s / %s t=%s wp=%s: %.2f:1" % (accent, ap, t, wp, r))
        # Negative control: the raw accent (what the role read before) is far under it, so the variant is what holds the ratio.
        raw = dict(role, fg="colors.accentInk")
        worst = min(role_ratio(AccentTokens(self.tok.data, a), raw, ap, t, wp) or 99 for a in self.ACCENTS
                    for ap in APPEARANCES for t in TRANSPARENCIES for wp in WALLPAPER_COLORS)
        self.assertLess(worst, 3.0)

    # The 18 colours, pinned (tests/unit/tst_accent.qml pins the same literals, so the two implementations cannot drift apart:
    # this side does the arithmetic of Accent.glassInk step for step, the QML side runs the function).
    GLASS_PINNED = {
        "dark": {"multicolor": "#cfe5d0", "blue": "#d2e1f4", "purple": "#e8dcf0", "pink": "#f6d7e1", "red": "#f7d7d1",
                 "orange": "#f7e1c8", "yellow": "#f7ecc8", "green": "#deedc9", "graphite": "#e3e2e0"},
        "light": {"multicolor": "#1b3728", "blue": "#1e3864", "purple": "#442a60", "pink": "#62243d", "red": "#612420",
                  "orange": "#503011", "yellow": "#473a0e", "green": "#2e401e", "graphite": "#37383b"},
    }

    def test_accent_glass_colours_are_pinned(self):
        for ap in APPEARANCES:
            for accent in self.ACCENTS:
                got = "#%02x%02x%02x" % AccentTokens(self.tok.data, accent).color("colors", ap, "accentGlass")
                self.assertEqual(got, self.GLASS_PINNED[ap][accent], "%s %s" % (ap, accent))
        self.assertEqual(self.tok.path("glass.accentInkMixDark"), 0.76)
        self.assertEqual(self.tok.path("glass.accentInkMixLight"), 0.58)

    def test_accent_glass_worst_case_per_accent_and_glass_class(self):
        # The worst ratio of each accent over the shell's real glass (every class at its real tint alpha, worst-case and known
        # backdrops, bare and under the fills a row or tile draws), per appearance: all hold 4.5:1.
        role = next(r for r in self.roles if r["id"] == "text and glyphs in the accent colour on material")
        for accent in self.ACCENTS:
            tok = AccentTokens(self.tok.data, accent)
            for ap in APPEARANCES:
                worst = min(r for t in TRANSPARENCIES for wp in WALLPAPER_COLORS
                            for r in [role_ratio(tok, role, ap, t, wp)] if r is not None)
                self.assertGreaterEqual(worst, 4.5, "%s %s: %.3f:1" % (accent, ap, worst))

    @staticmethod
    def oklch(rgb):
        def lin(v):
            v /= 255
            return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
        r, g, b = (lin(v) for v in rgb)
        l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
        m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
        s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360

    def test_accent_glass_keeps_the_hue_of_the_accent(self):
        # The variant stays recognisable as its accent: its OKLCH hue within 12 degrees of the ink's and a visible chroma
        # (0.025 or more; the dark appearance's near-white text leaves 0.03 to 0.05, the light one 0.06 to 0.09). Graphite has none.
        for ap in APPEARANCES:
            for accent in self.ACCENTS[:-1]:
                tok = AccentTokens(self.tok.data, accent)
                c0, h0 = self.oklch(tok.color("colors", ap, "accentInk"))
                c1, h1 = self.oklch(tok.color("colors", ap, "accentGlass"))
                dh = abs((h1 - h0 + 180) % 360 - 180)
                self.assertLessEqual(dh, 12, "%s %s hue %.0f -> %.0f" % (ap, accent, h0, h1))
                self.assertGreaterEqual(c1, 0.025, "%s %s chroma %.3f" % (ap, accent, c1))

    # Which text reads which colour (the sites list of the two roles): glass text reads accentGlass, app-window text accentInk.
    def accent_readers(self, name):
        found = {}
        pat = re.compile(r"\bcolors\.%s\b" % name)
        for sub in ("shell", "apps", "ui/Grassfield"):
            for d, _, files in os.walk(os.path.join(ROOT, sub)):
                for fn in sorted(files):
                    rel = os.path.relpath(os.path.join(d, fn), ROOT)
                    if not fn.endswith(".qml") or fn == "Tokens.qml" or rel.endswith("Ui/Appearance.qml"):
                        continue
                    with open(os.path.join(d, fn), encoding="utf-8") as f:
                        n = len(pat.findall(qml_scan.strip(f.read(), True)))
                    if n:
                        found[rel] = n
        return found

    def test_accent_text_roles_list_their_real_sites(self):
        ink = next(r for r in self.roles if r["id"] == "text and glyphs in the accent colour on an app window")
        glass = next(r for r in self.roles if r["id"] == "text and glyphs in the accent colour on material")
        declared = lambda r: {s["file"]: s["count"] for s in r["readers"]}
        self.assertEqual(self.accent_readers("accentInk"), declared(ink))
        self.assertEqual(self.accent_readers("accentGlass"), declared(glass))
        # The rule itself: shell glass reads accentGlass, never accentInk; app windows read accentInk, never accentGlass.
        for f in declared(ink):
            self.assertTrue(f.startswith("apps/"), f + " reads accentInk but is not an app window")
        for f in declared(glass):
            self.assertTrue(f.startswith("shell/") and not f.startswith("shell/security/"), f + " reads accentGlass outside shell glass")
        # Negative controls: the scan sees a wrong reader.
        self.assertTrue(re.search(r"\bcolors\.accentInk\b", qml_scan.strip("Text { color: Appearance.colors.accentInk }", True)))

    # No exemption anywhere in the role table touches the accent: a role that draws text or glyphs in an accent colour is never exempt.
    def test_no_accent_text_role_is_exempt(self):
        for role in self.roles:
            if "accent" in role["fg"] and role["kind"] in ("text", "large"):
                self.assertNotIn("exempt", role, role["id"])

    # Text and glyphs never draw in the bare accent colour (a light accent is under 4.5:1 there; the integrator's review of
    # 5391761): they read Appearance.colors.accentInk. Fills, rings, tracks, dots and selections keep the accent.
    BARE_ACCENT = re.compile(r"(?:^|[;\s])color\s*:[^;\n]*\bcolors\.accent\b(?!Text|Ink)")

    def bare_accent_text(self, code, kinds):
        return [o.type for o in qml_scan.parse_objects(qml_scan.strip(code, True))
                if o.type.split(".")[-1] in kinds and self.BARE_ACCENT.search(o.own)]

    def test_text_and_glyphs_read_the_accent_ink(self):
        subdirs = ("shell", "ui/Grassfield", "apps")
        kinds = set(qml_scan.TEXT_TYPES) | {"Icon", "WidgetLabel"} | qml_scan.text_components(ROOT, subdirs)
        # The forms it must catch, and those it must leave.
        self.assertEqual(self.bare_accent_text('Text { color: Appearance.colors.accent }', kinds), ["Text"])
        self.assertEqual(self.bare_accent_text('Icon { name: "x"; color: Appearance.withAlpha(Appearance.colors.accent, 0.5) }', kinds), ["Icon"])
        self.assertEqual(self.bare_accent_text('Text { color: Appearance.colors.accentInk }\nRectangle { color: Appearance.colors.accent }\n'
                                               'Text { color: Appearance.colors.accentText }', kinds), [])
        found = []
        for sub in subdirs:
            for d, _, files in os.walk(os.path.join(ROOT, sub)):
                for name in sorted(files):
                    path = os.path.join(d, name)
                    rel = os.path.relpath(path, ROOT)
                    if not name.endswith(".qml") or rel.startswith("shell/security/"):
                        continue  # shell/security draws no text in the accent; it changes only under its own review (R12)
                    with open(path, encoding="utf-8") as f:
                        found += ["%s: %s" % (rel, t) for t in self.bare_accent_text(f.read(), kinds)]
        self.assertEqual(found, [])

    # The ink exists only where an accent needs it: a light accent under 4.5:1 on the light app window (yellow, green, pink);
    # the others draw text in themselves.
    def test_accent_ink_only_where_needed(self):
        inks = self.tok.data["color"]["accentInkLight"]
        role = next(r for r in self.roles if r["id"] == "text and glyphs in the accent colour on an app window")
        for accent in self.ACCENTS[1:]:
            plain = Tokens(self.tok.data)
            light = hex_rgb(self.tok.path("color.accentLight.%s" % accent))
            grounds = backdrops(plain, role, "light", 0.0, (128, 128, 128))
            needs = min(wcag(light, g) for g in grounds) < 4.5
            self.assertEqual(accent in inks, needs, accent)

    # The sidebar tile of a window that is not key is a mid grey under the white glyph, which holds the 3:1 icon floor in both
    # appearances (macOS keeps the white glyph on its grey tiles; the first version, the lights' #D4D1CC, was 1.52:1).
    def test_inactive_sidebar_tile_keeps_the_glyph_at_3_to_1(self):
        glyph = hex_rgb(self.tok.path("settings.sidebarTileGlyph"))
        for name in ("sidebarTileInactiveLight", "sidebarTileInactiveDark"):
            grey = hex_rgb(self.tok.path("settings." + name))
            self.assertGreaterEqual(wcag(glyph, grey), 3.0, "%s: %.2f:1" % (name, wcag(glyph, grey)))
        # Negative control: the lights' inactive grey is under it.
        self.assertLess(wcag(glyph, hex_rgb(self.tok.path("window.inactiveLightLight"))), 3.0)

    # Known macOS system colours (several releases, light and dark, the lights, and values measured on the reference captures:
    # tile ramps, swatches): Grassfield chooses its own exact colours (ADR-0003; docs/legal/visual-review.md E18, E34), so no
    # tile, swatch or light token may equal or nearly equal one. The floor, CIE76 dE 9 from each colour of this list (62, not
    # every macOS colour), was validated by the owner on 2026-11-03 (docs/legal/visual-review.md E18, E34; no legal conclusion).
    # A neutral grey (saturation under 8 %) is exempt: a grey is not a distinctive colour, and ours are the warm
    # neutrals of ADR-0040.
    MACOS_SYSTEM_COLOURS = (
        "#FF5F57 #FEBC2E #28C840 #FF5C60 #FAC800 #35C759 #FF3B30 #FF453A #FF383C #FF9500 #FF9F0A #FF8D28 #FFCC00 #FFD60A "
        "#34C759 #30D158 #00C7BE #63E6E2 #30B0C7 #00C8B3 #32ADE6 #00C0E8 #007AFF #0A84FF #0088FF #5856D6 #5E5CE6 #6155F5 "
        "#AF52DE #BF5AF2 #CB30E0 #FF2D55 #FF375F #FF2C55 #A2845E #AC8E68 #45A7FF #6CDB81 #FF6667 #FF5F7D #887CFF #73DDF9 "
        "#017AFF #0176FB #027AFF #903891 #953D96 #F24A9A #F74F9E #DB3339 #E0383E #F27E11 #F7821B #FAC31C #FFC726 #5DB541 "
        "#62BA46 #FDAB5D #FD8D26 #44D1F3 #03C0E9 #34C859").split()
    OWN_COLOUR_MIN_DE = 9.0

    @staticmethod
    def lab(rgb):
        def f(v):
            v /= 255
            return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
        r, g, b = (f(x) for x in rgb)
        x, y, z = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, 0.2126 * r + 0.7152 * g + 0.0722 * b, (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        h = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
        return (116 * h(y) - 16, 500 * (h(x) - h(y)), 200 * (h(y) - h(z)))

    def delta_e(self, a, b):
        la, lb = self.lab(a), self.lab(b)
        return sum((p - q) ** 2 for p, q in zip(la, lb)) ** 0.5

    def own_colour_tokens(self):
        d = self.tok.data
        out = {}
        for group in ("tile", "swatch"):
            for name in d["color"][group]:
                out["color.%s.%s" % (group, name)] = d["color"][group][name]["value"]
        for name in ("closeColor", "minimizeColor", "zoomColor"):
            out["window." + name] = d["window"][name]["value"]
        # Memos' papers and strips (ADR-0051 D-1): Grassfield's own pastels.
        for name, leaf in d["memos"].items():
            if name.endswith("Paper") or name.endswith("Strip"):
                out["memos." + name] = leaf["value"]
        return out

    # Memos (ADR-0051, docs/specs/memos.md MM4): the memo ink reads at 4.5:1 or more on every paper and every strip, and the
    # strip's boxes (the ink at memos.boxOpacity) at 3:1, a graphic, on every strip. Opaque here; a Translucent memo shows the
    # desktop through and is the user's choice, as on macOS.
    def test_memo_ink_reads_on_every_paper_and_strip(self):
        d = self.tok.data["memos"]
        ink = hex_rgb(d["ink"]["value"])
        names = sorted(n[:-len("Paper")] for n in d if n.endswith("Paper"))
        self.assertEqual(names, sorted(["yellow", "blue", "green", "pink", "purple", "grey"]))
        for name in names:
            paper, strip = hex_rgb(d[name + "Paper"]["value"]), hex_rgb(d[name + "Strip"]["value"])
            self.assertGreaterEqual(wcag(ink, paper), 4.5, "%s paper: %.2f:1" % (name, wcag(ink, paper)))
            self.assertGreaterEqual(wcag(ink, strip), 4.5, "%s strip: %.2f:1" % (name, wcag(ink, strip)))
            box = over(ink, d["boxOpacity"]["value"], strip)
            self.assertGreaterEqual(wcag(box, strip), 3.0, "%s box: %.2f:1" % (name, wcag(box, strip)))
            # The strip is a darker step of its paper, not another colour.
            self.assertLess(lum(strip), lum(paper), name)

    def test_no_token_copies_a_macos_system_colour(self):
        import colorsys
        known = [hex_rgb(h) for h in self.MACOS_SYSTEM_COLOURS]
        tokens = self.own_colour_tokens()
        self.assertGreater(len(tokens), 30)
        for key, value in sorted(tokens.items()):
            rgb = hex_rgb(value)
            if colorsys.rgb_to_hls(*(v / 255 for v in rgb))[2] < 0.08:
                continue  # a neutral grey or near-black: see the note above
            nearest = min(known, key=lambda k: self.delta_e(rgb, k))
            de = self.delta_e(rgb, nearest)
            self.assertGreaterEqual(de, self.OWN_COLOUR_MIN_DE, "%s %s is dE %.1f from the macOS colour #%02X%02X%02X" % (key, value, de, *nearest))
        # Negative control: the exact macOS values the first version used are caught.
        for copy in ("#FF5C60", "#FAC800", "#35C759", "#0088FF", "#FF383C", "#FF2C55", "#6155F5", "#017AFF"):
            self.assertLess(min(self.delta_e(hex_rgb(copy), k) for k in known), 1.0, copy)

    # Settings icon tiles are vivid gradients (ADR-0024 amendment 2026-11-03, colour life): no text sits on a tile, so A2's
    # darkening does not apply, but the white glyph is a graphic and holds 3:1 on the gradient's lightest point, which is
    # its top, and on its bottom; the top is the lighter of the two.
    def test_vivid_tile_gradients_keep_the_glyph_at_3_to_1(self):
        glyph = hex_rgb(self.tok.path("settings.sidebarTileGlyph"))
        tiles = self.tok.data["color"]["tile"]
        names = sorted(n for n in tiles if not n.endswith("Top") and not n.endswith("Dark"))
        self.assertEqual(names, sorted(["blue", "green", "red", "pink", "purple", "cyan", "orange", "graphite", "black"]))
        for name in names:
            top, bottom = hex_rgb(self.tok.path("color.tile.%sTop" % name)), hex_rgb(self.tok.path("color.tile.%s" % name))
            self.assertGreaterEqual(lum(top), lum(bottom), name)
            self.assertGreaterEqual(wcag(glyph, top), 3.0, "%s top: %.2f:1" % (name, wcag(glyph, top)))
            self.assertGreaterEqual(wcag(glyph, bottom), 3.0, "%s bottom: %.2f:1" % (name, wcag(glyph, bottom)))
            # A real step, not a flat fill (macOS tiles are a soft gradient).
            self.assertGreater(wcag(top, bottom), 1.1, name)
        for end in ("blackTopDark", "blackDark"):
            self.assertGreaterEqual(wcag(glyph, hex_rgb(self.tok.path("color.tile." + end))), 3.0, end)
        # Negative control: macOS's own light ramp for green (#6CDB81) is under the floor, which is why ours is darker.
        self.assertLess(wcag(glyph, hex_rgb("#6CDB81")), 3.0)
        # The accent fills that carry text keep the darkened A2 values: a vivid tile colour never replaces them.
        self.assertEqual(self.tok.path("color.accentLight.blue"), "#1F5FCC")

    # A tile reads against the sidebar panel it sits on (the reviewer of refinement batch 5: the dark black tile was 1.21:1), in
    # both appearances, and a tile of a window that is not key never reads stronger than a lit one.
    def test_tiles_read_against_the_panel_and_inactive_is_never_stronger(self):
        tiles = self.tok.data["color"]["tile"]
        names = sorted(n for n in tiles if not n.endswith("Top") and not n.endswith("Dark"))
        for appearance in ("light", "dark"):
            panel = hex_rgb(self.tok.path("color.%s.sidebarFill" % appearance))
            inactive = hex_rgb(self.tok.path("settings.sidebarTileInactive%s" % appearance.capitalize()))
            weakest = 99.0
            for name in names:
                suffix = "Dark" if appearance == "dark" and name + "Dark" in tiles else ""
                ends = [hex_rgb(self.tok.path("color.tile.%s%s" % (name, suffix))), hex_rgb(self.tok.path("color.tile.%sTop%s" % (name, suffix)))]
                for end in ends:
                    c = wcag(end, panel)
                    weakest = min(weakest, c)
                    self.assertGreaterEqual(c, 1.5, "%s tile %s on the %s panel: %.2f:1" % (name, "#%02X%02X%02X" % end, appearance, c))
            self.assertLessEqual(wcag(inactive, panel), weakest + 0.005, "%s: the inactive tile is stronger than the weakest lit end" % appearance)
            self.assertGreaterEqual(wcag(inactive, panel), 1.5, appearance)
        # Negative control: the reviewer's finding, the first dark black tile.
        self.assertLess(wcag(hex_rgb("#2E2D2D"), hex_rgb(self.tok.path("color.dark.sidebarFill"))), 1.5)

    # The swatch discs are the vivid accent colours, the hue of the accent they pick (within 40 degrees of the A2 fill's).
    def test_vivid_swatches_keep_the_hue_of_their_accent(self):
        import colorsys
        def hue(rgb):
            return colorsys.rgb_to_hls(*(v / 255 for v in rgb))[0] * 360
        swatches = self.tok.data["color"]["swatch"]
        self.assertEqual(sorted(swatches), sorted(self.ACCENTS[1:]))
        for name in swatches:
            a, b = hue(hex_rgb(self.tok.path("color.swatch.%s" % name))), hue(hex_rgb(self.tok.path("color.accentLight.%s" % name)))
            if name != "graphite":
                self.assertLess(min(abs(a - b), 360 - abs(a - b)), 40, name)

    # The traffic lights are vivid own colours; their hover glyph (black at window.glyphOpacity) holds the 3:1 icon floor on each.
    def test_vivid_lights_keep_their_glyph_legible(self):
        for name in ("closeColor", "minimizeColor", "zoomColor"):
            disc = hex_rgb(self.tok.path("window." + name))
            alpha = float(self.tok.path("window.glyphOpacity"))
            glyph = tuple(c * (1 - alpha) for c in disc)
            self.assertGreaterEqual(wcag(glyph, disc), 3.0, "%s: %.2f:1" % (name, wcag(glyph, disc)))
        # Negative control: the first glyph opacity, 0.5, was 2.64:1 on the close light.
        disc = hex_rgb(self.tok.path("window.closeColor"))
        self.assertLess(wcag(tuple(c * 0.5 for c in disc), disc), 3.0)

    def test_accent_token_groups_are_complete(self):
        for group in ("accentDark", "accentLight"):
            roles = self.tok.data["color"][group]
            for name in self.ACCENTS[1:]:
                self.assertIn(name, roles)
                self.assertIn(name + "Text", roles)
            self.assertEqual(len(roles), 2 * (len(self.ACCENTS) - 1))

    def test_selection_pair_per_appearance(self):
        # macOS keeps white text on its accent fill in both appearances (ADR-0024): the light accent's pair in the light
        # appearance; in the dark one the color.selectionDark shade (owner decision 2026-10-26: #2E8049 for the Grassfield
        # green), never darker than the light accent, white at 4.85:1 or more wherever the light pair has white text.
        roles = self.tok.data["color"]["selectionDark"]
        self.assertEqual(sorted(roles), sorted([n for n in self.ACCENTS] + [n + "Text" for n in self.ACCENTS]))
        self.assertEqual(self.tok.path("color.selectionDark.multicolor"), "#2E8049")
        for accent in self.ACCENTS:
            tok = AccentTokens(self.tok.data, accent)
            light = tok.color("lightColors", "light", "accent")
            light_text = tok.color("lightColors", "light", "accentText")
            self.assertEqual(tok.color("colors", "light", "selection"), light, accent)
            self.assertEqual(tok.color("colors", "light", "selectionText"), light_text, accent)
            fill = tok.color("colors", "dark", "selection")
            text = tok.color("colors", "dark", "selectionText")
            self.assertGreaterEqual(lum(fill), lum(light), accent)
            self.assertGreaterEqual(wcag(text, fill), 4.85 if light_text == (255, 255, 255) else 4.5, accent)
            self.assertEqual(text == (255, 255, 255), light_text == (255, 255, 255), accent)

    def test_glass_classes_hold_a2_over_any_backdrop(self):
        # ADR-0024 G-1 to G-3: a glass class whose backdrop the shell does not know takes the worst case; its text and secondary
        # text keep 4.5:1 over every wallpaper colour, with and without the fill overlay, at every slider value tested.
        for ap in APPEARANCES:
            tint = self.tok.color("colors", ap, "materialTint")
            fill = self.tok.color("colors", ap, "fill")
            inks = [self.tok.color("colors", ap, "text"), self.tok.color("colors", ap, "textSecondary")]
            for cls in GLASS_CLASSES:
                target = self.tok.path("glass." + cls)
                for t in TRANSPARENCIES + (self.tok.path("material.defaultTransparency"), 1.0):
                    a = glass_alpha(self.tok, ap, target, t, None)
                    for wp in WALLPAPER_COLORS:
                        base = over(tint, a, wp)
                        filled = over(fill, self.tok.path("material.fillOpacity"), base)
                        for ink in inks:
                            self.assertGreaterEqual(min(wcag(ink, base), wcag(ink, filled)), 4.5, "%s %s t=%s wp=%s a=%.2f" % (ap, cls, t, wp, a))

    def test_glass_classes_hold_a2_over_a_known_backdrop(self):
        # Over a bare desktop the class tint may drop to its target; each wallpaper colour as its own (exact) range, coloured
        # backdrops approximated by the grey of their luminance plus glass.contrastMargin.
        for ap in APPEARANCES:
            tint = self.tok.color("colors", ap, "materialTint")
            fill = self.tok.color("colors", ap, "fill")
            inks = [self.tok.color("colors", ap, "text"), self.tok.color("colors", ap, "textSecondary")]
            for cls in GLASS_CLASSES:
                target = self.tok.path("glass." + cls)
                for t in TRANSPARENCIES + (1.0,):
                    for wp in WALLPAPER_COLORS:
                        l = lum(wp)
                        a = glass_alpha(self.tok, ap, target, t, (l, l))
                        base = over(tint, a, wp)
                        filled = over(fill, self.tok.path("material.fillOpacity"), base)
                        for ink in inks:
                            self.assertGreaterEqual(min(wcag(ink, base), wcag(ink, filled)), 4.5, "%s %s t=%s wp=%s a=%.2f" % (ap, cls, t, wp, a))

    def test_glass_worst_case_matches_the_qml_test(self):
        # tests/unit/tst_glasstint.qml asserts the same two numbers for GlassTint.js.
        d = self.tok.path("material.defaultTransparency")
        # light 0.79 since the warm neutrals of 2026-10-30 (ADR-0040; 0.78 with the cool ones)
        self.assertEqual(glass_alpha(self.tok, "light", self.tok.path("glass.menu"), d, None), 0.79)
        self.assertEqual(glass_alpha(self.tok, "dark", self.tok.path("glass.menu"), d, None), 0.82)

    def test_search_selection_is_inside_the_material_fill_overlay(self):
        # The selected Search row is a neutral fill (colors.fill at search.selectionFillOpacity) under ordinary text (ADR-0024):
        # the material backdrop's worst case already blends that fill at material.fillOpacity, and contrast moves
        # monotonically with the alpha in between, so the text and secondary roles on material cover the row as long as it
        # is no denser.
        self.assertLessEqual(self.tok.path("search.selectionFillOpacity"), self.tok.path("material.fillOpacity"))

    def test_selection_highlight_text_both_appearances(self):
        accent = next(r for r in self.roles if r["id"] == "accent text on accent")
        for ap in APPEARANCES:
            self.assertGreaterEqual(role_ratio(self.tok, accent, ap, 0.25, (255, 255, 255)), 4.5)

    def test_files_tag_dots_are_identifiable(self):
        # Graphics need 3:1 (WCAG 1.4.11). A tag dot is identifiable when its fill or its edge (the colour darkened by
        # files.tagDotOutlineDarker, as Qt.darker does: HSV value divided by the factor) reaches 3:1 against the opaque
        # Files window colour (TagDots.qml). Yellow, orange and green fills alone fail in the light appearance.
        import colorsys
        factor = self.tok.path("files.tagDotOutlineDarker")
        for ap in APPEARANCES:
            window = self.tok.color("colors", ap, "materialTint")
            for name in ("Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"):
                fill = hex_rgb(self.tok.path("files.tag" + name))
                h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in fill))
                edge = tuple(c * 255 for c in colorsys.hsv_to_rgb(h, s, v / factor))
                best = max(wcag(fill, window), wcag(edge, window))
                self.assertGreaterEqual(best, 3.0, "%s dot in the %s appearance: %.2f:1" % (name, ap, best))
                if ap == "light":
                    self.assertGreaterEqual(wcag(edge, window), 3.0, "%s edge on the light window" % name)

    def test_swatch_mark_on_every_tag_colour(self):
        mark = hex_rgb(self.tok.path("menu.swatchMark"))
        for name in ("Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"):
            self.assertGreaterEqual(wcag(mark, hex_rgb(self.tok.path("files.tag" + name))), 3.0, name)


class WindowSurfacePairs(unittest.TestCase):
    """Visual audit 2026-10-25 (review of visual-audit-1): every foreground/background pair the opaque-window and Quick Settings
    changes introduced, in both appearances. `Appearance.windowSecondary` (windowTextSecondary) is for text drawn directly on the
    window surface or on a Settings group; fields, tabs and chips keep textSecondary on their own fills."""

    @classmethod
    def setUpClass(cls):
        cls.tok = Tokens(load_tokens())

    def window(self, ap):
        return self.tok.color("colors", ap, "windowBackground")

    def test_window_secondary_text_on_the_window_and_on_a_settings_group(self):
        for ap in APPEARANCES:
            fg = self.tok.color("colors", ap, "windowTextSecondary")
            win = self.window(ap)
            on_group = self.tok.color("colors", ap, "groupFill")
            for bg, what in ((win, "the window"), (on_group, "a Settings group")):
                self.assertGreaterEqual(wcag(fg, bg), 4.5, "windowTextSecondary on %s, %s: %.2f:1" % (what, ap, wcag(fg, bg)))
                self.assertGreaterEqual(wcag(self.tok.color("colors", ap, "text"), bg), 7.0, "text on %s, %s" % (what, ap))

    def test_dark_window_secondary_text_on_the_window_its_groups_and_its_sidebar(self):
        # ADR-0039 Q3 (the owner, 2026-10-29: #A1A1A6, warm since ADR-0040's warm neutrals): the dark window's secondary text
        # holds A2 where it is drawn, on the window, a group and the sidebar, and reads as secondary: the primary text keeps at
        # least twice its contrast there (it had 10.7:1 against the text's 13.4:1, so subtitles read like titles).
        ap = "dark"
        fg = self.tok.color("colors", ap, "windowTextSecondary")
        text = self.tok.color("colors", ap, "text")
        for name, what in (("windowBackground", "the window"), ("groupFill", "a group"), ("sidebarFill", "the sidebar")):
            bg = self.tok.color("colors", ap, name)
            self.assertGreaterEqual(wcag(fg, bg), 4.5, "windowTextSecondary on %s, dark: %.2f:1" % (what, wcag(fg, bg)))
            self.assertGreaterEqual(wcag(text, bg) / wcag(fg, bg), 2.0,
                                    "text %.2f:1 against secondary %.2f:1 on %s, dark" % (wcag(text, bg), wcag(fg, bg), what))

    def test_field_placeholder_on_every_field_of_an_app_window(self):
        # UI audit 2026-11-05 U4: a field's placeholder in an app window (TextField, SearchField: colors.fieldPlaceholder) holds
        # 4.5:1 on the field (light: the window colour; dark: the fill at material.fillOpacity over the window, a group or the
        # sidebar), on the search field's fill (the text colour at toolbar.fieldFillOpacity) and on the toolbar capsule (white
        # at toolbar.capsuleFillOpacity), and reads lighter than the typed text.
        for ap in APPEARANCES:
            fg = self.tok.color("colors", ap, "fieldPlaceholder")
            text = self.tok.color("colors", ap, "text")
            sfx = "Dark" if ap == "dark" else ""
            grounds = [self.tok.color("colors", ap, n) for n in ("windowBackground", "groupFill", "sidebarFill")]
            fields = [self.window(ap)] if ap == "light" else \
                [over(self.tok.color("colors", ap, "fill"), self.tok.path("material.fillOpacity"), g) for g in grounds]
            for g in grounds:
                fields.append(over(text, self.tok.path("toolbar.fieldFillOpacity" + sfx), g))
                fields.append(over(self.tok.color("colors", ap, "knob"), self.tok.path("toolbar.capsuleFillOpacity" + sfx), g))
            for bg in fields:
                self.assertGreaterEqual(wcag(fg, bg), 4.5, "fieldPlaceholder on %s, %s: %.2f:1" % (bg, ap, wcag(fg, bg)))
                self.assertGreater(wcag(text, bg), wcag(fg, bg) * 1.4, "the placeholder reads lighter than the text, %s" % ap)

    def test_permission_alert_symbol_on_the_window(self):
        # grassfield-portal's permission alert (apps/files/qml/AccessAlert.qml): the frontend's symbolic icon, for an application
        # without an icon of its own, in the text colour on the opaque window (a graphic, 3:1). The theme's own grey was 1.2:1 on
        # the dark window (integrator nested pass of PR #49 on 1745c0c, MINOR 3).
        for ap in APPEARANCES:
            r = wcag(self.tok.color("colors", ap, "text"), self.window(ap))
            self.assertGreaterEqual(r, 3.0, "the alert's symbol in the %s appearance: %.2f:1" % (ap, r))

    def test_sound_table_rows(self):
        # Settings > Sound's device table: the text on a striped row, on the column header and on the grey selection (the table
        # without the focus), all over a Settings group; the empty-table note in the window grey on the group.
        for ap in APPEARANCES:
            group = self.tok.color("colors", ap, "groupFill")
            fill = self.tok.color("colors", ap, "fill")
            text = self.tok.color("colors", ap, "text")
            for name in ("settings.soundTableStripeOpacity", "settings.soundTableSelectionOpacity"):
                bg = over(fill, self.tok.path(name), group)
                self.assertGreaterEqual(wcag(text, bg), 7.0, "text on %s, %s: %.2f:1" % (name, ap, wcag(text, bg)))

    def test_row_secondary_on_the_hover_fill(self):
        # A Settings row with secondary text and a hover fill: while hovered, the fill sits on the window or on a Settings group.
        # The window grey is under 4.5:1 there (3.62:1 in light), so such a row switches to textSecondary on hover.
        for ap in APPEARANCES:
            win = self.window(ap)
            on_group = self.tok.color("colors", ap, "groupFill")
            for base, what in ((win, "the window"), (on_group, "a Settings group")):
                hov = over(self.tok.color("colors", ap, "hover"), self.tok.path("material.hoverOpacity"), base)
                r = wcag(self.tok.color("colors", ap, "textSecondary"), hov)
                self.assertGreaterEqual(r, 4.5, "textSecondary on the hover fill over %s, %s: %.2f:1" % (what, ap, r))

    def test_text_secondary_on_the_fields_and_tabs_of_a_window(self):
        # The sidebar and toolbar search placeholders, the inactive Files tab titles, a rename field: the translucent fill over the window.
        for ap in APPEARANCES:
            win = self.window(ap)
            fill = over(self.tok.color("colors", ap, "fill"), self.tok.path("material.fillOpacity"), win)
            fg = self.tok.color("colors", ap, "textSecondary")
            for bg, what in ((win, "the window"), (fill, "a 0.14 fill")):
                self.assertGreaterEqual(wcag(fg, bg), 4.5, "textSecondary on %s, %s: %.2f:1" % (what, ap, wcag(fg, bg)))

    def test_status_dots_on_a_settings_group(self):
        # Wi-Fi's "Connected", the Network pane's services: a dot in front of the status text (a graphic, 3:1).
        for ap in APPEARANCES:
            group = self.tok.color("colors", ap, "groupFill")
            for name in ("statusOn", "statusWarn", "statusOff"):
                r = wcag(self.tok.color("colors", ap, name), group)
                self.assertGreaterEqual(r, 3.0, "%s on a Settings group, %s: %.2f:1" % (name, ap, r))

    def test_activity_graph_colours(self):
        # Activity Monitor's summary (spec AM7): each graph colour is a graphic, 3:1 or more against the graph's fill (the group
        # fill) and the window around it, in both appearances.
        names = ("activityGraphSystem", "activityGraphUser", "activityGraphRead", "activityGraphWrite", "activityGraphIn",
                 "activityGraphOut", "activityGraphBattery", "activityPressureGreen", "activityPressureYellow", "activityPressureRed")
        for ap in APPEARANCES:
            for bg_name in ("groupFill", "windowBackground"):
                bg = self.tok.color("colors", ap, bg_name)
                for name in names:
                    r = wcag(self.tok.color("colors", ap, name), bg)
                    self.assertGreaterEqual(r, 3.0, "%s on %s, %s: %.2f:1" % (name, bg_name, ap, r))
        # Negative control: the light appearance's text-free yellow of Files' tags is below 3:1 on the light group fill.
        self.assertLess(wcag(hex_rgb(self.tok.path("files.tagYellow")), self.tok.color("colors", "light", "groupFill")), 3.0)

    def test_dark_settings_groups_stay_visible_against_the_window(self):
        win = self.window("dark")
        group = self.tok.color("colors", "dark", "groupFill")
        # ADR-0024 lot 1: macOS 27 groups are #313131 on a #292929 window, a step the eye reads as a surface (1.1:1).
        self.assertGreaterEqual(wcag(group, win), 1.1, "dark group against the window: %.2f:1" % wcag(group, win))

    def test_toolbar_capsules_and_their_selected_pill(self):
        # Priority 11: back/forward, the view group and the search capsule are a 6 % grey (light) or 14 % (dark) fill over the window;
        # the selected view is a lighter pill (white 0.85 in light, the dark fill again in dark). Text and icons on all of them.
        for ap in APPEARANCES:
            win = self.window(ap)
            fillc = self.tok.color("colors", ap, "fill")
            if ap == "light":
                group = over(fillc, self.tok.path("material.fillOpacityLight"), win)
                pill = over(self.tok.color("colors", ap, "chipFill"), self.tok.path("material.chipFillOpacityLight"), group)
            else:
                group = over(fillc, self.tok.path("material.fillOpacity"), win)
                pill = over(fillc, self.tok.path("material.fillOpacity"), group)
            for bg, what in ((group, "the capsule"), (pill, "the selected pill")):
                for name in ("text", "textSecondary"):
                    r = wcag(self.tok.color("colors", ap, name), bg)
                    self.assertGreaterEqual(r, 4.5, "%s on %s, %s: %.2f:1" % (name, what, ap, r))

    def test_settings_sidebar_surfaces(self):
        # ADR-0024 lot 1: the flush sidebar (sidebarFill) carries the text, the secondary text and the search placeholder.
        for ap in APPEARANCES:
            side = self.tok.color("colors", ap, "sidebarFill")
            for name in ("text", "textSecondary"):
                r = wcag(self.tok.color("colors", ap, name), side)
                self.assertGreaterEqual(r, 4.5, "%s on the sidebar, %s: %.2f:1" % (name, ap, r))

    def test_window_backdrop_holds_the_window_the_sidebar_and_the_capsule_fills(self):
        # The `window` backdrop (RimmedCapsule's role, Search's clipboard page): the window and the sidebar, each bare and under the
        # field and toolbar capsule fills, whatever the transparency and the wallpaper.
        role = {"fg": "colors.textSecondary", "backdrop": "window", "kind": "text"}
        for ap in APPEARANCES:
            got = backdrops(self.tok, role, ap, 0.6, (0, 0, 0))
            self.assertEqual(got, backdrops(self.tok, role, ap, 0.0, (255, 255, 255)))
            self.assertIn(self.window(ap), got)
            self.assertIn(self.tok.color("colors", ap, "sidebarFill"), got)
            self.assertEqual(len(got), 6)

    def test_quick_settings_slider_fill_against_its_track(self):
        # WCAG 1.4.11: the white fill against the track, and the empty track against the module (1.5:1), every wallpaper colour and
        # transparency. Light: the shadow colour darkens the module; dark: the fill colour lightens it (a shadow on a dark module is invisible).
        for ap in APPEARANCES:
            fill = self.tok.color("colors", ap, "knob")
            if ap == "light":
                tc, op = self.tok.color("colors", ap, "shadow"), self.tok.path("quicksettings.sliderTrackOpacity")
            else:
                tc, op = self.tok.color("colors", ap, "fill"), self.tok.path("quicksettings.sliderTrackOpacityDark")
            worst = groove = None
            for t in TRANSPARENCIES:
                for wp in WALLPAPER_COLORS:
                    module = over(self.tok.color("colors", ap, "materialTint"), self.tok.tint_alpha(t), wp)
                    track = over(tc, op, module)
                    r = wcag(fill, track)
                    worst = r if worst is None else min(worst, r)
                    g = wcag(track, module)
                    groove = g if groove is None else min(groove, g)
            self.assertGreaterEqual(worst, 3.0, "slider fill against the track, %s appearance: %.2f:1" % (ap, worst))
            self.assertGreaterEqual(groove, 1.5, "slider track against the module, %s appearance: %.2f:1" % (ap, groove))


if __name__ == "__main__":
    _tok = Tokens(load_tokens())
    _roles = load_roles()
    print_table(_tok, _roles, role_table(_tok, _roles))
    if "--table" in sys.argv:
        sys.exit(0)
    unittest.main(verbosity=1, argv=[sys.argv[0]])
