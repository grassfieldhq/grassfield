#!/usr/bin/env python3
"""The update hold names what the build records (ADR-0041 step 2a, SQ-3 option A).

  python3 -I tests/ci/hold_parity.py

One list, kept in five places, must agree:
  - the packages PKGBUILD's prepare() records in BUILD-DEPS (`pacman -Q <names> >BUILD-DEPS`);
  - GU_TRACKED, what grassfield-update-helper compares (U27);
  - the table of ADR-0033 s3.4 and the five names in docs/specs/updates.md U27;
  - the packages grassfield-hold bounds (packaging/arch/hold-bounds.sh): exactly quickshell and qt6-base, both recorded,
    never hyprland (ADR-0009) and never kcoreaddons (a monthly public ABI);
  - the PKGBUILD itself: the two split packages exist, grassfield-desktop depends on `grassfield-hold` and names no bound of
    its own, grassfield-unhold provides and conflicts with grassfield-hold and has no `depends`, grassfield-hold's depends come
    from BUILD-DEPS (gf_hold_depends), never typed, and the bounds library is installed for grassfield-channel-set.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
errors = []


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def need(cond, message):
    if not cond:
        errors.append(message)


pkgbuild = read("packaging/arch/PKGBUILD")
helper = read("packaging/pacman/grassfield-update-helper")
adr33 = read("docs/decisions/ADR-0033-software-update.md")
spec = read("docs/specs/updates.md")
bounds = read("packaging/arch/hold-bounds.sh")

m = re.search(r"pacman -Q ((?:[a-z0-9-]+ )+[a-z0-9-]+) >\"\$srcdir/BUILD-DEPS\"", pkgbuild)
recorded = m.group(1).split() if m else []
need(recorded, "PKGBUILD: the `pacman -Q ... >BUILD-DEPS` line was not found")

m = re.search(r"^GU_TRACKED=\(([^)]*)\)", helper, re.M)
tracked = m.group(1).split() if m else []
need(sorted(recorded) == sorted(tracked), f"BUILD-DEPS records {sorted(recorded)}, the update helper tracks {sorted(tracked)}")

table = re.findall(r"^\s*\| `([a-z0-9-]+)` \| [^|]+ \| ", adr33[adr33.index("### s3.4 The compatibility check"):].split("- **The rule.**")[0], re.M)
need(sorted(table) == sorted(recorded), f"ADR-0033 s3.4 table names {sorted(table)}, BUILD-DEPS records {sorted(recorded)}")

m = re.search(r"- U27\. Compatibility.*?\((`[^)]*)\)", spec, re.S)
u27 = re.findall(r"`([a-z0-9-]+)`", m.group(1)) if m else []
need(sorted(u27) == sorted(recorded), f"updates.md U27 names {sorted(u27)}, BUILD-DEPS records {sorted(recorded)}")

# The hold bounds quickshell and qt6-base, both recorded: the names its depends are made of.
held = sorted(set(re.findall(r'"(quickshell|qt6-base)[=<>]', bounds)) | set(re.findall(r"gf_hold_recorded \"\$1\" ([a-z0-9-]+)", bounds)))
need(held == ["qt6-base", "quickshell"], f"hold-bounds.sh bounds {held}, expected exactly qt6-base and quickshell")
need(all(p in recorded for p in held), "the hold bounds a package BUILD-DEPS does not record")
for never in ("hyprland", "kcoreaddons", "aquamarine"):
    need(not re.search(rf'gf_hold_recorded[^\n]*{never}|"{never}[=<>]', bounds), f"hold-bounds.sh bounds {never} (ADR-0041 SD-3, ADR-0009)")

# PKGBUILD.
m = re.search(r"^pkgname=\(([^)]*)\)", pkgbuild, re.M)
names = m.group(1).split() if m else []
need("grassfield-hold" in names and "grassfield-unhold" in names, "PKGBUILD: grassfield-hold and grassfield-unhold are not both in pkgname")


def function(name):
    m = re.search(rf"^{name}\(\) \{{\n(.*?)^\}}", pkgbuild, re.M | re.S)
    need(m is not None, f"PKGBUILD: {name}() not found")
    return m.group(1) if m else ""


desktop = function("package_grassfield-desktop")
m = re.search(r"^  depends=\(([^)]*)\)", desktop, re.M)
deps = m.group(1).split() if m else []
need("grassfield-hold" in deps, "PKGBUILD: grassfield-desktop does not depend on grassfield-hold")
need(not any(re.match(r"(quickshell|qt6-base)[<>=]", d) for d in deps), "PKGBUILD: grassfield-desktop carries a toolkit bound of its own")
need(not re.search(r"grassfield-unhold", m.group(1) if m else ""), "PKGBUILD: grassfield-desktop depends on grassfield-unhold")

unhold = function("package_grassfield-unhold")
need(re.search(r"^  provides=\(grassfield-hold\)$", unhold, re.M) is not None, "PKGBUILD: grassfield-unhold does not provide exactly grassfield-hold")
need(re.search(r"^  conflicts=\(grassfield-hold\)$", unhold, re.M) is not None, "PKGBUILD: grassfield-unhold does not conflict with grassfield-hold")
need(re.search(r"^  depends=\(\)$", unhold, re.M) is not None, "PKGBUILD: grassfield-unhold has a bound (depends must be empty)")

hold = function("package_grassfield-hold")
need("gf_hold_depends \"$srcdir/BUILD-DEPS\"" in hold, "PKGBUILD: grassfield-hold's depends do not come from BUILD-DEPS")
need(re.search(r"^  depends=\(", hold, re.M) is None, "PKGBUILD: grassfield-hold's depends are typed by hand")
need(not re.search(r"^  (provides|conflicts|install|backup)=", hold, re.M), "PKGBUILD: grassfield-hold has more than depends")
need('source "$_here/hold-bounds.sh"' in pkgbuild, "PKGBUILD does not source the bounds library")
need("grassfield-hold-bounds.sh" in desktop, "PKGBUILD: the bounds library is not installed for grassfield-channel-set")

need("grassfield-hold-helper" in desktop, "PKGBUILD: grassfield-hold-helper is not installed")
need((ROOT / "packaging/pacman/grassfield-hold-helper").stat().st_mode & 0o111 != 0, "grassfield-hold-helper is not executable")
policy = read("packaging/pacman/org.grassfield.packages.policy")
need("org.grassfield.packages.hold" in policy and "/usr/lib/grassfield/grassfield-hold-helper" in policy, "the polkit policy lacks the hold's own action")

if errors:
    print("hold parity: FAIL")
    for e in errors:
        print("  - " + e)
    sys.exit(1)
print(f"hold parity: ok (BUILD-DEPS {', '.join(recorded)}; the hold bounds {', '.join(held)})")
