# Third-party components

Facts taken from local files (installed headers, `pacman -Qi`, `/usr/share/licenses`, headers of files in this
repository), as of 2026-10-18. No legal conclusion is stated. Items marked **needs legal review** are open
questions for counsel; details and evidence are in `docs/legal/licenses-audit.md`.

Grassfield's own code is MIT (root `LICENSE`, ADR-0005 accepted by the owner 2026-10-18). Package licence fields
(`packaging/arch/PKGBUILD`, checked by `scripts/dev/check-licenses.sh`):

| Package | `license=` | Why |
|---|---|---|
| `grassfield-desktop` | `MIT`, `CC-BY-SA-4.0`, `Unicode-3.0`, `BSD-3-Clause`, `LicenseRef-Grassfield-logo-all-rights-reserved` | own code; own art (symbolic icons, cursor templates, `BRANDING.md`), the Grassfield logo excepted: all rights reserved, the owner's mark, installed in the same package (owner decision 2026-10-27); the Unicode-derived grapheme tables (section 5a); the clipboard helper's code generated from `hyprland-lock-notify-v1.xml` (section 2a) |
| `grassfield-compositor` | `MIT`, `LGPL-2.1-or-later`, `BSD-3-Clause` | own code; server code generated from the KDE appmenu protocol XML; server code generated from wayland-protocols' xdg-toplevel-drag XML (MIT, section 1); Hyprland headers compiled in |
| `grassfield-icons` | `MIT`, `GPL-3.0-only` | own glyphs; the third-party icon pack (risk accepted by the owner, decision D-9, 2026-10-23; the composed pack accepted for publication at the owner's risk, amendment of 2026-10-27) |

Licence texts shipped with the packages (`/usr/share/licenses/<package>/`):

| File | Package | Content |
|---|---|---|
| `THIRD_PARTY.md` | both | this file |
| `hyprland-BSD-3-Clause.txt` | grassfield-compositor | Hyprland BSD-3-Clause text, copied from `/usr/share/licenses/hyprland/LICENSE` |
| `appmenu-LGPL-2.1-or-later.txt` | grassfield-compositor | notice of the KDE appmenu protocol and the LGPL-2.1-or-later text |
| `compositor-protocols-notices.txt` | grassfield-compositor | the `<copyright>` block of `xdg-toplevel-drag-v1.xml` (MIT), whose generated server code is in `grassfield-compositor.so` (section 1) |
| `BRANDING.md` | grassfield-desktop | `branding/LICENSES.md`, provenance of icons and wallpaper |
| `omarchy-MIT.txt` | grassfield-desktop | Omarchy's LICENSE, verbatim (v4.0.4: "Copyright (c) David Heinemeier Hansson"), for Omarchy-derived QML |
| `unicode-license-v3.txt` | grassfield-desktop | Unicode License v3 notice for the derived grapheme tables (section 5a) |
| `clipboard-protocols-notices.txt` | grassfield-desktop | the `<copyright>` blocks of `ext-data-control-v1.xml` (MIT) and `hyprland-lock-notify-v1.xml` (BSD-3-Clause), whose generated code is in `grassfield-clipboard-helper` (section 2a) |

## 1. Built against, linked or generated from (grassfield-compositor)

### Hyprland headers (and Hypr libraries)

- Hyprland 0.56.2: BSD-3-Clause, "Copyright (c) 2022-2026, vaxerski" (`/usr/share/licenses/hyprland/LICENSE`).
  The installed headers carry no per-file licence line (ADR-0009, section "Header licence check"). Full text:
  `hyprland-BSD-3-Clause.txt`.
- aquamarine, hyprutils, hyprlang, hyprgraphics, hyprcursor: BSD-3-Clause per `pacman -Qi` (aquamarine and
  hyprutils: "Copyright (c) 2024, Hypr Development" per the audit). Headers are included and the shared
  libraries are linked by the plugin.
- hyprwayland-scanner 0.4.6: BSD-3-Clause, build tool that generated the appmenu server code.
- The plugin is loaded into Hyprland's process and compiled from its C++ headers.
  **Needs legal review:** whether the BSD-3 notice must accompany the binary plugin (it is shipped as a precaution),
  and the licence status of scanner-generated code.

### KDE appmenu protocol and generated code

- `compositor/protocols/appmenu.xml`: KDE `org_kde_kwin_appmenu`, "SPDX-FileCopyrightText: 2017 David Edmundson",
  "SPDX-License-Identifier: LGPL-2.1-or-later" (notice kept in the file). Grassfield's copy is version 2.
- The server code generated from it by hyprwayland-scanner (`appmenu.hpp`/`.cpp`, copying the same notice) is
  compiled into `grassfield-compositor.so`.
- The same protocol ships with Qt (`/usr/share/qt6/wayland/protocols/appmenu/qt_attribution.json`: LGPL-2.1-or-later,
  "Copyright 2017 David Edmundson"). Hyprland's `kde-server-decoration.hpp` carries LGPL-2.1-or-later in the same way.
- Notice and licence text shipped: `appmenu-LGPL-2.1-or-later.txt`.
  **Needs legal review:** obligations for the MIT plugin that compiles code generated from this XML.

### xdg-toplevel-drag protocol and generated code

- `staging/xdg-toplevel-drag/xdg-toplevel-drag-v1.xml` of the installed wayland-protocols (1.49 when written; not copied
  into the repository: the build reads it through `pkg-config --variable=pkgdatadir wayland-protocols`): MIT, "Copyright 2023
  David Redondo" (the `<copyright>` block of the XML).
- The server code generated from it by hyprwayland-scanner (`xdg-toplevel-drag-v1.hpp`/`.cpp`, which copy that block) is
  compiled into `grassfield-compositor.so` (ADR-0036 amendment 2026-11-08).
- Notice shipped (integrator decision, 2026-11-08): `compositor-protocols-notices.txt`, that block verbatim, installed with
  the plugin package as `clipboard-protocols-notices.txt` is with the desktop package.

### DBusMenu and AppMenu Registrar interfaces

The menu bridge calls `com.canonical.dbusmenu` and implements `com.canonical.AppMenu.Registrar` from interface names
and method signatures (`bridges/menu-bridge/src/DBusObjects.cpp`). No upstream XML file is in the repository and no
upstream licence text was available locally. **Needs legal review.**

### Other libraries linked by the plugin (dynamic, unmodified, not shipped by Grassfield)

cairo, libxkbcommon, libinput, wayland, libxcb, pixman, libdrm, libglvnd, libstdc++/libgcc, glibc. Licences per
`pacman -Qi` are listed in `docs/legal/licenses-audit.md` section 4.1 row 5. They are installed by the distribution.

## 2. Runtime dependencies (grassfield-desktop; dynamically linked or run, unmodified, not shipped)

| Component | Use | Licence per local files |
|---|---|---|
| Quickshell 0.3.1 | host that runs the QML shell; `Grassfield.I18n` plugin loads into it | LGPL-3.0-only (`/usr/share/licenses/quickshell/LICENSE`) |
| Qt 6.11.2 (base, declarative, wayland, svg, imageformats, tools) | linked and loaded | headers: "LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only" |
| QtPdf, QtPdfQuick (package qt6-webengine) | Preview | as Qt; Chromium/PDFium notices in `/usr/share/licenses/qt6-webengine/LICENSE.chromium` |
| QtMultimedia + FFmpeg backend | Preview, and the shell for video wallpapers (ADR-0016 W7) | as Qt; ffmpeg 9.0.1 is GPL-3.0-only per pacman. **Needs legal review** (docs/legal/licenses-audit.md, gap G9: now also loaded into the shell process). |
| ffmpeg and ffprobe programs | `grassfield-wallpaper` transcodes and probes video wallpapers (argument vector, a separate process, plain-file protocol whitelist; ADR-0016) | GPL-3.0-only per pacman (ffmpeg 9.0.1). The programs are run, not linked. **Needs legal review.** |
| curl | `grassfield-wallpaper fetch` downloads the online pictures of the day (argument vector, https only) | curl licence (MIT-style); run, not linked |
| KF6 KIO, Solid, CoreAddons, Service 6.29.0 | linked by `grassfield-files` and `grassfield-portal` (the Files library) | headers: LGPL-2.0-or-later (`kio/job.h`, `kio/renamedialog.h`); "LGPL-2.0-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL" (`kio/openurljob.h`); "LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL" (`solid/device.h`) |
| KF6 WindowSystem 6.31.0 | linked by `grassfield-portal`: an Open or Save panel becomes the child of the application's window (xdg-foreign v2, ADR-0035 D-4); already installed as a dependency of KIO | header: LGPL-2.1-or-later (`kwindowsystem.h`) |
| libgcr-4 4.4.1 (package gcr-4) and GLib/GIO 2.90 (package glib2) | linked by `grassfield-prompter`: gcr's system prompter protocol, its `sx-aes-1` exchange and secure memory, and GDBus (ADR-0035 D-9); gcr-4 is already installed with gnome-keyring, glib2 with qt6-base | LGPL-2.1-or-later per pacman; header: LGPL-2.1-or-later (`gcr/gcr-system-prompter.h`) |
| libsecret 0.21.8 (package libsecret) | linked by `grassfield-prompter`: KIO's remembered network passwords stored in and read from the Secret Service, through its asynchronous calls (ADR-0035 D-12 b, step 9e); already installed with gcr-4 | LGPL-2.1-or-later per pacman; header: LGPL-2.1-or-later (`libsecret/secret-password.h`) |
| extra-cmake-modules (build) | CMake modules | pacman "LGPL"; module headers BSD-3-Clause/BSD-2-Clause |
| uwsm | session launcher | MIT |

Grassfield patches none of these. **Needs legal review:** obligations for MIT code and plugins running inside or
linked to LGPL hosts, and for the GPL-3.0 ffmpeg loaded by Preview and, through QtMultimedia, by the shell (video wallpapers).

## 2a. Protocol definitions vendored for the clipboard helper (grassfield-desktop, ADR-0034)

| File | Source | Licence per the file | Use |
|---|---|---|---|
| `apps/clipboard-helper/protocols/ext-data-control-v1.xml` | wayland-protocols 1.49, `staging/ext-data-control/` (copied from the Arch package's `/usr/share/wayland-protocols`) | MIT (its `<copyright>`: Simon Ser, Ivan Molodetskikh, Neal Gompa) | `wayland-scanner` client code compiled into `grassfield-clipboard-helper` |
| `apps/clipboard-helper/protocols/hyprland-lock-notify-v1.xml` | hyprwm/hyprland-protocols (copied from the Arch package's `/usr/share/hyprland-protocols`) | BSD-3-Clause (its `<copyright>`: Maximilian Seidler; the project's LICENSE: Hypr Development) | the same |

Both notices ship as `clipboard-protocols-notices.txt`. Test only, never shipped: `tests/fixtures/fake-clipboard-server` compiles their
server code.

## 3. Omarchy-derived code (MIT)

Portions adapted from Omarchy (`pacman -Qi omarchy` 4.0.4: MIT, URL `https://github.com/basecamp/omarchy`; the
Grassfield source headers name `omacom/omarchy`, branch quattro; both are recorded as observed, not decided):

| Grassfield file | Adapted from | What |
|---|---|---|
| `shell/security/lock/Lock.qml` | `shell/plugins/lock/Service.qml` | PamContext wiring, WlSessionLock secure state, stranded-lock signal |
| `shell/security/idle/Idle.qml` | `shell/plugins/services/idle/Service.qml` | IdleMonitor with respectInhibitors |
| `shell/security/polkit/AuthAgent.qml` | `shell/plugins/polkit/PolkitAgent.qml` | PolkitAgent/AuthFlow wiring |

These three files are security modules; their headers say "Copyright (c) David Heinemeier Hansson, MIT License", as
upstream's LICENSE at tag v4.0.4 (basecamp/omarchy@c668141e9c42b13c80c9ca4ea108e11708c5e8a5, the installed version;
identical at v4.0.6). The installed omarchy package carries no licence file; the text below is upstream's LICENSE,
verbatim (also shipped as `omarchy-MIT.txt`; `scripts/dev/check-licenses.sh` compares the text from the copyright line on with
SHA-256 `717ba1949502290f8e47688ae2e323acd06c8ca47aec9f7596b15f678c1af4a2`, the hash of that LICENSE).

```
Copyright (c) David Heinemeier Hansson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Run-time use without copying: `config/hypr/grassfield/omarchy.lua` requires Omarchy's Lua modules from
`/usr/share/omarchy`; the lock uses the PAM service `omarchy-lock-password`. Trademark use of "Omarchy" in the UI:
**needs legal review**.

## 4. Fonts

Inter 4.1 (package `inter-font`): SIL OFL 1.1, "Copyright (c) 2016 The Inter Project Authors
(https://github.com/rsms/inter)" (`/usr/share/licenses/inter-font/LICENSE.txt`); pacman says `OFL-1.1-RFN`.
Referenced by family name, not bundled or modified. Noto Sans is the fallback family (OFL-1.1-no-RFN per pacman).
No font file is in this repository. The session fontconfig (`packaging/fontconfig/fonts.conf`, ADR-0003) only names
Inter and Inter Display; the `SF Pro*`, `-apple-system`, `BlinkMacSystemFont` and `.AppleSystemUIFont` entries are aliases that resolve to Inter, and
no Apple font is used, shipped or required.

## 5. Icons and wallpaper

Provenance per file: `branding/LICENSES.md` (shipped as `BRANDING.md`). The symbolic icons are Grassfield's own (`ls branding/icons/symbolic/*.svg | wc -l` prints 127 (125 symbolic icons and the two logo files))
(CC-BY-SA-4.0); the procedural wallpaper is QML code in `shell/desktop/WallpaperArt.qml`.
No Apple asset is used. Licence of Grassfield-made art (symbolic icons, cursors, wallpaper): CC-BY-SA-4.0, decided by the
owner on 2026-10-27 (an earlier text attributed this to decision D-9, which concerned the icon pack). The Grassfield
logo is excluded: all rights reserved, the owner's mark. It is two files: `branding/icons/symbolic/grassfield-logo-full.svg`
(the full mark) and `branding/icons/symbolic/grassfield-logo.svg` (its 16-24 px optical version).

AI assistance: parts of the artwork and of the code were produced with AI assistance under the owner's direction, and
are published by the owner under the licences stated in this file and in `branding/LICENSES.md`.

Cursors (ADR-0014): the `grassfield-cursors` theme (hyprcursor SVG theme plus XCursor fallback, installed under
`/usr/share/icons/grassfield-cursors`) is generated at package build time from Grassfield's own templates in
`branding/cursors/` (CC-BY-SA-4.0, listed in `BRANDING.md`). No file of Adwaita, Yaru or capitaine is
used; only cursor names (a vocabulary shared by CSS and X11) were read from installed themes. The build uses
`hyprcursor-util` (BSD-3-Clause), `rsvg-convert` (librsvg, LGPL-2.1-or-later) and Python as build tools; the XCursor
writer is Grassfield's own stdlib script. The runtime regeneration for the pointer colours (Settings > Accessibility >
Pointer, `grassfield-cursors-custom` under `$XDG_DATA_HOME/icons`, owner decision 2026-10-19) runs the same script
(`/usr/share/grassfield/cursors/build.sh`) with the same three tools, so `python`, `librsvg` and `hyprcursor` are runtime
dependencies of `grassfield-desktop` (declared in `packaging/arch/PKGBUILD`); they are used as separate programs, nothing
of them is linked or copied. The generated custom theme is derived from the same CC-BY-SA-4.0 templates.

App icon theme (ADR-0017; owner decision 2026-10-23): `grassfield-icons` (`/usr/share/icons/grassfield-icons`, its own
package `grassfield-icons`, a dependency of `grassfield-desktop`) is ONE theme composed at build time by
`packaging/arch/icons-compose.py` (header of the script: layers, directory layout) from two pinned third-party themes and
Grassfield's own glyphs (`branding/icons/theme`, MIT); it inherits `breeze,Adwaita,hicolor`. First layer that provides an
icon name wins: Grassfield's own app icons, MacTahoe, Pebble, Grassfield's device glyphs. Pebble supplies the folders and the
store icon; the files and names listed in `packaging/arch/icons-apple-logos.txt` (the Apple logo, alone or inside a larger
drawing, and the Finder face) are removed, and the composer refuses an output that draws or embeds a fingerprinted Apple
mark (`packaging/arch/icons-apple-signatures.txt`) or holds a copy of a listed file. Look-alikes of Apple's app icons
(Calendar, Clock, Maps, Music, Notes, Photos, Safari, ...) are NOT removed: owner decision 2026-10-23, risk accepted. The
session selects the theme with `QT_QPA_SYSTEM_ICON_THEME` (uwsm `env-grassfield`) and, for GTK, a locked dconf database that
holds only `icon-theme='grassfield-icons'`. Grassfield's own apps and some system tools are mapped to pack drawings by
`packaging/arch/icons-aliases.txt` (links inside the theme). Dev sessions compose the same theme with `scripts/dev/icons.sh` (`just icons`).
**Modification notice (GPL-3.0 section 5a):** the composer edits a small number of the upstream SVG files it copies
(`clean_svg` in `icons-compose.py`): an empty `<pattern href="#x"/>` is written out with the attributes and content of the
pattern it references, and a fill or stroke that points to a missing or contentless paint server is replaced by `none`, so
that Qt's renderer can read the file. Nothing else in the drawings changes; the changed files are found by comparing the
pack with the pinned upstream sources. The same notice is in `/usr/share/licenses/grassfield-icons/NOTICE`.
- MacTahoe icon theme, `https://github.com/vinceliuice/MacTahoe-icon-theme` at commit
  `839848b9a8a38a92a6936e30c4abe35cc6f2546d`, author Vince Liuice (AUTHORS). Licence: `COPYING` (GPL version 3, unmodified
  text) is present; the README states no licence and no file carries an "or later" notice: GPL-3.0-only. COPYING and AUTHORS
  ship in `/usr/share/licenses/grassfield-icons/`. Only the base variant, default colour; no upstream script runs.
- Pebble icon theme, `https://github.com/a-shewale/Pebble-Icon-Theme` at commit
  `185da58c2f4caf3c2a038aa0869fd2772acc0933`, only its main `Pebble/` variant. **Pebble: no licence file at the pin; its
  README states GPL-3.0 (and links a LICENSE file that does not exist); owner accepted the risk 2026-10-23 and kept it on 2026-10-27.** It credits
  MacTahoe, Hatter (`https://github.com/Mibea/Hatter`, the base of its folders and structure; its licence was not verified
  here) and Adwaita (pacman licence field CC-BY-SA-3.0 OR LGPL-3.0-only) as its sources. The credit note ships as `/usr/share/licenses/grassfield-icons/PEBBLE`, the
  two sources and commits as `SOURCE`.
- The composed package declares `license=(MIT GPL-3.0-only)`: MIT for Grassfield's own glyphs, GPL-3.0 for the third-party art.
  **needs legal review:** Apple trademark artwork that the by-eye sweep and the fingerprints may have missed in either
  theme (rasters are checked only against known fingerprints), the Apple look-alike app icons kept by owner decision, the
  missing Pebble licence and the licences of the art Pebble took from Hatter and Adwaita, and the aggregation with the
  MIT packages. The theme's `index.theme` and the UI name neither theme.

Runtime theme dependencies (installed by pacman, read by Qt and GTK as data; nothing of them is vendored, copied or
modified by Grassfield):
- Breeze icon theme (`breeze-icons`, a dependency of `grassfield-desktop`): KDE's own icon art; pacman licence field
  LGPL-3.0-or-later and LGPL-2.1-only;
- Adwaita icon theme (`adwaita-icon-theme`, installed with GTK and Omarchy): GNOME's own icon art; pacman licence field
  CC-BY-SA-3.0 OR LGPL-3.0-only;
- hicolor (`hicolor-icon-theme`): the freedesktop fallback.
Their licence texts ship with their packages. The WhiteSur icon theme was evaluated and dropped on 2026-10-21 (ADR-0017
amendment): nothing of it is installed, fetched, filtered or referenced at runtime. **needs legal review:** the
aggregation of these data packages with the MIT packages of this project, as for any dependency.

## 5b. Online pictures of the day (fetched at run time, opt-in, never shipped)

Settings > Wallpaper > Online (ADR-0016 step 2) lets the user turn on one of two daily pictures. Grassfield ships none of
them; `grassfield-wallpaper fetch` downloads one picture a day to the user's cache (curl, https only, fixed host
allow-list) and shows it with its credit. **Needs legal review** (ADR-0016, REQ-ADR0016-29).

| Source | Hosts | Terms as Grassfield applies them | Shown with the picture |
|---|---|---|---|
| Wikimedia Commons, Picture of the Day (MediaWiki Action API) | `commons.wikimedia.org`, `thumb.wikimedia.org`, `upload.wikimedia.org` | each file has its own licence: only public-domain marks, CC0, CC BY and CC BY-SA are accepted (NC, ND, GFDL and any other are skipped, the previous picture stays); the Wikimedia User-Agent policy is followed (product, version and the project contact) | Title, Author, Source (link) and Licence (link to its URL), as plain text |
| NASA Astronomy Picture of the Day (`api.nasa.gov/planetary/apod`, shared `DEMO_KEY`) | `api.nasa.gov`, `apod.nasa.gov` | NASA material is generally not copyrighted in the US, but many APOD pictures belong to third parties: the entry's `copyright` field is shown with the picture (owner decision 2026-10-20); a picture is accepted only under `apod.nasa.gov/apod/image/`, which excludes the NASA logo; a video entry is never downloaded; no NASA insignia or logo is used, "NASA" is only the name of the source | Title, credit and copyright holder (or "Public domain (NASA)" when there is none), link to the APOD page |

The names "Wikimedia", "Wikimedia Commons", "NASA" and "APOD" appear in the interface only to name these sources (no
logo). Resizing and re-encoding the picture for local display is the only processing; whether that needs anything beyond
the attribution above is a question for counsel.

## 5c. Wallpaper photographs (grassfield-wallpapers, shipped)

Sixteen photographs from Wikimedia Commons (ADR-0040 step 2c; the owner's call of 2026-10-31), installed under
`/usr/share/grassfield/wallpapers/photos/` and shown in Settings > Wallpaper > Photographs with their author, source and
licence. The list is `packaging/arch/wallpaper-photos.json`; the build downloads each original from
`upload.wikimedia.org`, checks its SHA-1 and changes it as follows: Resized to at most 5120 pixels wide, re-encoded as JPEG (quality 90), metadata removed (packaging/arch/PKGBUILD, apps/wallpaper-tool grassfield-wallpaper-shrink). Each photograph keeps its own
licence; none of them is under Grassfield's licences. Details and the owner's decisions are in the maintainers' private legal review
E40.

| Photograph | Source (Commons file page) | Credit | Licence |
|---|---|---|---|
| Golden Mist / Brume dorée | [Matt Palmer 2016 (Unsplash).jpg](https://commons.wikimedia.org/wiki/File:Matt_Palmer_2016_(Unsplash).jpg) | Matt Palmer / Unsplash, CC0, via Wikimedia Commons | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Frosted Meadow / Prairie givrée | [Łąki nad Wisłą pod Brzeźnicą po wschodzie słońca, 20241116 0725 2676.jpg](https://commons.wikimedia.org/wiki/File:%C5%81%C4%85ki_nad_Wis%C5%82%C4%85_pod_Brze%C5%BAnic%C4%85_po_wschodzie_s%C5%82o%C5%84ca,_20241116_0725_2676.jpg) | Jakub Hałun, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Valley Fog / Brouillard sur la vallée | [Zamglona dolina w Witowie w powiecie proszowickim, 20241020 0808 6322.jpg](https://commons.wikimedia.org/wiki/File:Zamglona_dolina_w_Witowie_w_powiecie_proszowickim,_20241020_0808_6322.jpg) | Jakub Hałun, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| River Mist / Brume sur la rivière | [Desna river Vinn meadow 2016 G2.jpg](https://commons.wikimedia.org/wiki/File:Desna_river_Vinn_meadow_2016_G2.jpg) | George Chernilevsky, public domain, via Wikimedia Commons | [Public domain](https://commons.wikimedia.org/wiki/Template:PD-self) |
| Steppe Storm / Orage sur la steppe | [Чуйский хребет и Курайская степь.jpg](https://commons.wikimedia.org/wiki/File:%D0%A7%D1%83%D0%B9%D1%81%D0%BA%D0%B8%D0%B9_%D1%85%D1%80%D0%B5%D0%B1%D0%B5%D1%82_%D0%B8_%D0%9A%D1%83%D1%80%D0%B0%D0%B9%D1%81%D0%BA%D0%B0%D1%8F_%D1%81%D1%82%D0%B5%D0%BF%D1%8C.jpg) | Aleksandr Rudny (Александр Рудный), CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Evening Fields / Champs du soir | [Tatry - panorama z Polskiego Spiszu.jpg](https://commons.wikimedia.org/wiki/File:Tatry_-_panorama_z_Polskiego_Spiszu.jpg) | Qvidemus, CC BY 3.0 <https://creativecommons.org/licenses/by/3.0>, via Wikimedia Commons | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| Mountain Pasture / Pâturage | [Ingushetia, Закатный золотой свет на склонах долины Армхи, горы Ингушетии, Кавказ.jpg](https://commons.wikimedia.org/wiki/File:Ingushetia,_%D0%97%D0%B0%D0%BA%D0%B0%D1%82%D0%BD%D1%8B%D0%B9_%D0%B7%D0%BE%D0%BB%D0%BE%D1%82%D0%BE%D0%B9_%D1%81%D0%B2%D0%B5%D1%82_%D0%BD%D0%B0_%D1%81%D0%BA%D0%BB%D0%BE%D0%BD%D0%B0%D1%85_%D0%B4%D0%BE%D0%BB%D0%B8%D0%BD%D1%8B_%D0%90%D1%80%D0%BC%D1%85%D0%B8,_%D0%B3%D0%BE%D1%80%D1%8B_%D0%98%D0%BD%D0%B3%D1%83%D1%88%D0%B5%D1%82%D0%B8%D0%B8,_%D0%9A%D0%B0%D0%B2%D0%BA%D0%B0%D0%B7.jpg) | © Vyacheslav Argenberg, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Rice Terraces / Rizières en terrasses | [Hyogo-Rice terraces in Ueyama.(early autumn.)-xl.jpg](https://commons.wikimedia.org/wiki/File:Hyogo-Rice_terraces_in_Ueyama.(early_autumn.)-xl.jpg) | photo by rikky_photography -- FIND/47, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Morning Dew / Rosée du matin | [Dew on grass (21677746153).jpg](https://commons.wikimedia.org/wiki/File:Dew_on_grass_(21677746153).jpg) | Andrey Nagaycev, CC BY 2.0 <https://creativecommons.org/licenses/by/2.0>, via Wikimedia Commons | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| Summer Grass / Herbe d’été | [Grass (14448015527).jpg](https://commons.wikimedia.org/wiki/File:Grass_(14448015527).jpg) | Yuri Samoilov, CC BY 2.0 <https://creativecommons.org/licenses/by/2.0>, via Wikimedia Commons | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| Seed Heads / Graminées | [Grass at Sunrise (36993588030).jpg](https://commons.wikimedia.org/wiki/File:Grass_at_Sunrise_(36993588030).jpg) | Михаил Лазарев (Mikhail Lazarev), CC BY 2.0 <https://creativecommons.org/licenses/by/2.0>, via Wikimedia Commons | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| Terraces at Dusk / Rizières au crépuscule | [Kyoto-Evening view of Sodeshi rice terraces.-xl.jpg](https://commons.wikimedia.org/wiki/File:Kyoto-Evening_view_of_Sodeshi_rice_terraces.-xl.jpg) | photo by rikky_photography -- FIND/47, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Winter Sunrise / Lever d’hiver | [Wschód słońca nad łąkami pod Tyńcem w Krakowie, 20260301 0636 4894.jpg](https://commons.wikimedia.org/wiki/File:Wsch%C3%B3d_s%C5%82o%C5%84ca_nad_%C5%82%C4%85kami_pod_Ty%C5%84cem_w_Krakowie,_20260301_0636_4894.jpg) | Jakub Hałun, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Autumn Dew / Rosée d’automne | [Dew on grass (22309335571).jpg](https://commons.wikimedia.org/wiki/File:Dew_on_grass_(22309335571).jpg) | Andrey Nagaycev, CC BY 2.0 <https://creativecommons.org/licenses/by/2.0>, via Wikimedia Commons | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| Silver Grass / Eulalies | [Waving grass under mountains (Unsplash).jpg](https://commons.wikimedia.org/wiki/File:Waving_grass_under_mountains_(Unsplash).jpg) | Thomas Rohlfs / Unsplash, CC0, via Wikimedia Commons | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Starlit Hill / Colline étoilée | [Milky Way over Cronan Ranch (52321033535).jpg](https://commons.wikimedia.org/wiki/File:Milky_Way_over_Cronan_Ranch_(52321033535).jpg) | Bureau of Land Management California, public domain, via Wikimedia Commons | [Public domain](https://commons.wikimedia.org/wiki/Template:PD-USGov-BLM) |

## 5a. Unicode character data (derived tables)

`ui/Grassfield/Ui/GraphemeData.js` (shipped with the shell) and `apps/files/src/graphemedata.inc` (compiled into
Files) are generated by `scripts/dev/gen-glyph-tables.sh` from the Unicode properties (Grapheme_Cluster_Break,
Extended_Pictographic, Indic_Conjunct_Break, Emoji, general category) of the installed ICU (ICU 78.3, Unicode 17.0),
read at generation time only: no product code links ICU. `scripts/dev/glyph-icu-compare.sh` (development, not shipped)
links it to check the rule.
The data is under the Unicode License v3 as shipped with ICU, "Copyright © 2016-2025 Unicode, Inc."
(`/usr/share/licenses/icu/LICENSE`); the licence asks that the copyright and permission notice accompany copies of the
Data Files or appear in associated documentation.
The notice ships as `unicode-license-v3.txt` in the grassfield-desktop package (`license=` lists `Unicode-3.0`).
**Needs legal review:** whether tables generated from ICU's character properties count as a copy of the Data Files
(the notice is shipped in any case).

## 6. Test and build only (not shipped)

- googletest 1.18.0: BSD-3-Clause, "Copyright 2008, Google Inc." (`/usr/share/licenses/gtest`). Used by unit tests
  built in `check()`; no test binary is installed.
- `tests/tools/vpointer/wlr-virtual-pointer-unstable-v1.xml`: reconstructed from the generated Hyprland header
  `/usr/include/hyprland/protocols/wlr-virtual-pointer-unstable-v1.hpp`, which carries MIT, "Copyright © 2019 Josef
  Gajdusek". Test tool, not packaged; the file itself has no notice yet (audit gap G11).
- `tests/tools/vkbd/virtual-keyboard-unstable-v1.xml`: the `zwp_virtual_keyboard_v1` protocol
  (wlroots / Purism), reduced to its requests and arguments, MIT: "Copyright © 2008-2011 Kristian Høgsberg, © 2010-2013
  Intel Corporation, © 2012-2013 Collabora, Ltd., © 2018 Purism SPC". The file carries the full notice verbatim (as
  reproduced in Hyprland's generated `/usr/include/hyprland/protocols/virtual-keyboard-unstable-v1.hpp`). Test tooling
  (`tests/tools/vkbd/`), not packaged.
- Lua 5.5.1 headers (MIT) at build time; CMake, Ninja, Qt tools (build tools).
