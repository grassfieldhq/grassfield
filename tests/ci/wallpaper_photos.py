#!/usr/bin/env python3
"""The shipped wallpaper photographs (ADR-0040 step 2c): one list, and everything that repeats it held to it.

  python3 -I tests/ci/wallpaper_photos.py             check the tree; exit 1 on any problem
  python3 -I tests/ci/wallpaper_photos.py --selftest  the checks on planted mutants of the real files

packaging/arch/wallpaper-photos.json is the one list (the owner's call of 2026-10-31). Checked:
  - each entry: a plain id (it becomes a file name), a name in English and in French, an author, a credit, a licence of the
    allowed set (CC0, CC BY 2.0, 3.0 or 4.0; "Public domain" only for the two the owner accepted, river-mist and
    starlit-hill), an https licence address, its Commons page, its original on upload.wikimedia.org, a 40-digit SHA-1, its
    size and a width of 3840 or more; a CC BY credit names the author and the licence; each id and each original once;
  - packaging/arch/wallpaper-pins.sh repeats the ids, the originals and the SHA-1 in the list's order;
  - packaging/arch/PKGBUILD sources the pins, adds each original to source=, checks each by the same SHA-1 (sha1sums, after
    the two icon commits, as long as source=), shrinks them in build(), builds grassfield-wallpapers, installs photos.json,
    and grassfield-desktop depends on it;
  - THIRD_PARTY.md and docs/legal/visual-review.md name each photograph's Commons file and its licence.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FILES = {
    "list": "packaging/arch/wallpaper-photos.json",
    "pins": "packaging/arch/wallpaper-pins.sh",
    "pkgbuild": "packaging/arch/PKGBUILD",
    "third": "THIRD_PARTY.md",
    "legal": "docs/legal/visual-review.md",
}
LICENCES = {"CC0", "CC BY 2.0", "CC BY 3.0", "CC BY 4.0", "Public domain"}
PUBLIC_DOMAIN_ACCEPTED = {"river-mist", "starlit-hill"}  # the owner's call of 2026-10-31 (ADR-0040)
ID = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
SHA1 = re.compile(r"[0-9a-f]{40}")
FIELDS = ("id", "name", "author", "credit", "licenseShort", "licenseUrl", "sourceUrl", "file", "original", "sha1", "bytes", "width", "height")


def bash_array(text, name):
    """The words of a multi-line `NAME=(` ... `)` assignment, or None."""
    m = re.search(r"^%s=\(\n(.*?)\n\)$" % re.escape(name), text, re.M | re.S)
    return None if m is None else m.group(1).split()


def entry_problems(p, index):
    out = []
    where = "entry %d" % index
    missing = [f for f in FIELDS if f not in p]
    if missing:
        return ["%s: missing %s" % (where, ", ".join(missing))]
    pid = p["id"]
    where = "%s (%s)" % (where, pid)
    if not isinstance(pid, str) or not ID.fullmatch(pid):
        out.append("%s: the id is not a plain name" % where)
    name = p["name"]
    if not isinstance(name, dict) or not all(isinstance(name.get(k), str) and name.get(k).strip() for k in ("en", "fr")):
        out.append("%s: a name in English and in French is needed" % where)
    for f in ("author", "credit", "file"):
        if not isinstance(p[f], str) or not p[f].strip():
            out.append("%s: empty %s" % (where, f))
    lic = p["licenseShort"]
    if lic not in LICENCES:
        out.append("%s: licence %r is not CC0, CC BY or the accepted public domain" % (where, lic))
    elif lic == "Public domain" and pid not in PUBLIC_DOMAIN_ACCEPTED:
        out.append("%s: public domain was accepted for %s only" % (where, ", ".join(sorted(PUBLIC_DOMAIN_ACCEPTED))))
    if lic.startswith("CC BY") and isinstance(p["credit"], str) and (p["author"] not in p["credit"] or lic not in p["credit"]):
        out.append("%s: a CC BY credit names the author and the licence" % where)
    if not str(p["licenseUrl"]).startswith("https://"):
        out.append("%s: the licence address is not https" % where)
    if not str(p["sourceUrl"]).startswith("https://commons.wikimedia.org/wiki/File:"):
        out.append("%s: the source is not a Commons file page" % where)
    if not str(p["original"]).startswith("https://upload.wikimedia.org/wikipedia/commons/") or "?" in str(p["original"]):
        out.append("%s: the original is not a plain upload.wikimedia.org address" % where)
    if not isinstance(p["sha1"], str) or not SHA1.fullmatch(p["sha1"]):
        out.append("%s: the SHA-1 is not 40 hex digits" % where)
    if not isinstance(p["bytes"], int) or p["bytes"] <= 0:
        out.append("%s: no size" % where)
    if not isinstance(p["width"], int) or p["width"] < 3840 or not isinstance(p["height"], int) or p["height"] <= 0:
        out.append("%s: narrower than 3840 px" % where)
    return out


def problems(texts):
    out = []
    try:
        photos = json.loads(texts["list"])["photos"]
    except (ValueError, KeyError, TypeError) as e:
        return ["%s: not a list of photographs (%s)" % (FILES["list"], e)]
    if not isinstance(photos, list) or not photos:
        return ["%s: no photographs" % FILES["list"]]
    for i, p in enumerate(photos):
        out += entry_problems(p, i) if isinstance(p, dict) else ["entry %d: not an object" % i]
    if out:
        return out
    ids = [p["id"] for p in photos]
    originals = [p["original"] for p in photos]
    sha1 = [p["sha1"] for p in photos]
    for label, values in (("id", ids), ("original", originals)):
        dup = sorted({v for v in values if values.count(v) > 1})
        if dup:
            out.append("%s: %s more than once: %s" % (FILES["list"], label, ", ".join(dup)))

    pins = texts["pins"]
    for name, want in (("GF_PHOTO_IDS", ids), ("GF_PHOTO_URLS", originals), ("GF_PHOTO_SHA1", sha1)):
        got = bash_array(pins, name)
        if got != want:
            out.append("%s: %s is not the list's, in its order" % (FILES["pins"], name))

    pk = texts["pkgbuild"]
    if 'source "$_here/wallpaper-pins.sh"' not in pk:
        out.append("PKGBUILD: does not source wallpaper-pins.sh")
    if 'source+=("photo-${GF_PHOTO_IDS[_i]}.jpg::${GF_PHOTO_URLS[_i]}")' not in pk:
        out.append("PKGBUILD: the originals are not added to source=")
    sums = re.search(r"^sha1sums=\((.*?)\)$", pk, re.M | re.S)
    values = re.findall(r"'([^']*)'", sums.group(1)) if sums else []
    if values[:2] != ["SKIP", "SKIP"] or values[2:] != sha1:
        out.append("PKGBUILD: sha1sums are not SKIP twice (the icon commits) then the list's SHA-1 in its order")
    sha256 = re.search(r"^sha256sums=\((.*?)\)$", pk, re.M | re.S)
    if not sha256 or len(re.findall(r"'([^']*)'", sha256.group(1))) != 2 + len(photos):
        out.append("PKGBUILD: sha256sums do not have one entry per source")
    if "grassfield-wallpaper-shrink\" --width 5120 --quality 90" not in pk:
        out.append("PKGBUILD: build() does not shrink the photographs")
    if not re.search(r"^pkgname=\([^)]*\bgrassfield-wallpapers\b[^)]*\)", pk, re.M) or "package_grassfield-wallpapers() {" not in pk:
        out.append("PKGBUILD: no grassfield-wallpapers package")
    if '"$dir/photos.json"' not in pk:
        out.append("PKGBUILD: photos.json is not installed beside the pictures")
    desktop = re.search(r"^package_grassfield-desktop\(\) \{.*?^\}", pk, re.M | re.S)
    if not desktop or not re.search(r"^  depends=\(.*\bgrassfield-wallpapers\b", desktop.group(0), re.M):
        out.append("PKGBUILD: grassfield-desktop does not depend on grassfield-wallpapers")

    for key in ("third", "legal"):
        if texts.get(key) is None:  # the legal review is private: absent from the public repository
            continue
        for p in photos:
            if p["file"] not in texts[key] or p["sourceUrl"] not in texts[key]:
                out.append("%s: does not name %s (%s) with its Commons page" % (FILES[key], p["id"], p["file"]))
    return out


OPTIONAL = {"legal"}  # kept in the maintainers' private notes; absent here, its check is skipped with a note


def read():
    out = {}
    for k, v in FILES.items():
        path = ROOT / v
        if k in OPTIONAL and not path.exists():
            print("NOTE: %s is not in this checkout; its photograph entries are NOT checked here" % v)
            out[k] = None
        else:
            out[k] = path.read_text(encoding="utf-8")
    return out


def selftest():
    base = read()
    first = json.loads(base["list"])["photos"][0]
    other = json.loads(base["list"])["photos"][1]

    def list_with(change):
        d = json.loads(base["list"])
        change(d["photos"])
        return json.dumps(d)

    def setp(i, key, value):
        return lambda ps: ps[i].__setitem__(key, value)

    mutants = [
        ("an id that climbs out of the folder", {"list": list_with(setp(0, "id", "../etc"))}),
        ("no French name", {"list": list_with(lambda ps: ps[0]["name"].pop("fr"))}),
        ("a CC BY-SA licence", {"list": list_with(setp(1, "licenseShort", "CC BY-SA 4.0"))}),
        ("public domain for another photograph", {"list": list_with(setp(0, "licenseShort", "Public domain"))}),
        ("a credit without its author", {"list": list_with(setp(1, "credit", "someone, CC BY 4.0"))}),
        ("an http licence address", {"list": list_with(setp(0, "licenseUrl", "http://creativecommons.org/"))}),
        ("an original with a query", {"list": list_with(setp(0, "original", first["original"] + "?x=1"))}),
        ("a short SHA-1", {"list": list_with(setp(0, "sha1", "abc"))}),
        ("a picture under 3840 px", {"list": list_with(setp(0, "width", 2000))}),
        ("an id twice", {"list": list_with(setp(1, "id", first["id"]))}),
        ("a pin dropped", {"pins": base["pins"].replace("  %s\n" % other["id"], "", 1)}),
        ("the pins in another order", {"pins": base["pins"].replace("  %s\n  %s\n" % (first["id"], other["id"]), "  %s\n  %s\n" % (other["id"], first["id"]), 1)}),
        ("a SHA-1 changed in the PKGBUILD", {"pkgbuild": base["pkgbuild"].replace("'%s'" % first["sha1"], "'%s'" % ("0" * 40), 1)}),
        ("no grassfield-wallpapers in pkgname", {"pkgbuild": re.sub(r"^(pkgname=\([^)]*?)\s+grassfield-wallpapers\b", r"\1", base["pkgbuild"], count=1, flags=re.M)}),
        ("grassfield-desktop without the dependency", {"pkgbuild": base["pkgbuild"].replace("grassfield-icons grassfield-wallpapers networkmanager", "grassfield-icons networkmanager", 1)}),
        ("no shrink in build()", {"pkgbuild": base["pkgbuild"].replace("--width 5120 --quality 90", "--width 9999 --quality 90", 1)}),
        ("THIRD_PARTY.md without a photograph", {"third": base["third"].replace(first["sourceUrl"], "", 1)}),
    ]
    if base["legal"] is not None:
        mutants.append(("the legal entry without a photograph", {"legal": base["legal"].replace(other["file"], "", 1)}))
    fails = 0
    clean = problems(base)
    if clean:
        print("FAIL: selftest: the real files have problems: %s" % clean[:3])
        fails += 1
    for name, change in mutants:
        texts = dict(base)
        texts.update(change)
        if texts == base:
            print("FAIL: selftest: the mutant '%s' changed nothing" % name)
            fails += 1
        elif not problems(texts):
            print("FAIL: selftest: the mutant '%s' passed" % name)
            fails += 1
    if not fails:
        print("PASS: wallpaper_photos selftest (%d mutants caught)" % len(mutants))
    return 1 if fails else 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    found = problems(read())
    for p in found:
        print("FAIL: " + p)
    if found:
        return 1
    n = len(json.loads(read()["list"])["photos"])
    print("PASS: wallpaper_photos: %d photographs, the pins, the PKGBUILD and THIRD_PARTY.md agree%s"
          % (n, " (and the legal entry)" if (ROOT / FILES["legal"]).exists() else " (no private legal file here: not checked)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
