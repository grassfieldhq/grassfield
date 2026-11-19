#!/usr/bin/env bash
# A build sysroot for compiling the plugin against a Hyprland other than the installed one (developers and CI only; not
# part of the rebuild sources). It is the machine's own /usr (symlinks), with the Hyprland package and the
# aquamarine/hyprutils/hyprgraphics versions it was built with taken from archive.archlinux.org (pinned by sha256) in place
# of the installed ones, so no header of the installed Hyprland can be picked up by mistake.
#
#   compositor/hypr-sysroot.sh <dir>        downloads (once) into <dir>/pkgs, extracts into <dir>/root, links <dir>/sysroot
#   then:  PKG_CONFIG_SYSROOT_DIR=<dir>/sysroot PKG_CONFIG_LIBDIR=<dir>/sysroot/usr/lib/pkgconfig:<dir>/sysroot/usr/share/pkgconfig \
#          cmake -S compositor -B <build> -G Ninja -DCMAKE_SYSROOT=<dir>/sysroot -DGRASSFIELD_OUTPUT_DIR=<out>
#
# Pinned set: Hyprland 0.57.2-1 (Arch, 2026-11) and the versions its version.h names (aquamarine 0.16.0, hyprutils 0.14.3,
# hyprgraphics 0.6.0). hyprlang (0.6.8) and hyprcursor are the machine's own (same minor, headers only).
set -euo pipefail
dir=${1:?usage: hypr-sysroot.sh <dir>}
archive=https://archive.archlinux.org/packages
pkgs=(
  "h/hyprland/hyprland-0.57.2-1-x86_64.pkg.tar.zst b927522ddf55b39b0ba652ab1bf652216fe45bd7733454e2a3ce59f15f3956a6"
  "a/aquamarine/aquamarine-0.16.0-1-x86_64.pkg.tar.zst 355e5919b3485811617eaf7a16032d3c811492c23154d84a3962ed99176ebbef"
  "h/hyprutils/hyprutils-0.14.3-1-x86_64.pkg.tar.zst 4e30d54567ff3324cf003aca5d1ab85df4fe3215c3f378eb6bcaaec941da39df"
  "h/hyprgraphics/hyprgraphics-0.6.0-2-x86_64.pkg.tar.zst ea0bdead023bc66469340c3c4255555521042e8a57bbbfa287116ee97d8d6ca3"
)
mkdir -p "$dir/pkgs"
for p in "${pkgs[@]}"; do
  read -r path sum <<<"$p"
  f=$dir/pkgs/$(basename "$path")
  if [[ ! -f $f ]]; then
    curl -fsSL -o "$f.part" "$archive/$path"
    mv "$f.part" "$f"
  fi
  echo "$sum  $f" | sha256sum -c --quiet - || { echo "hypr-sysroot: checksum mismatch: $f" >&2; rm -f "$f"; exit 1; }
done

rm -rf "$dir/root" "$dir/sysroot"
mkdir -p "$dir/root" "$dir/sysroot/usr/include" "$dir/sysroot/usr/lib/pkgconfig" "$dir/sysroot/usr/share/pkgconfig"
for p in "${pkgs[@]}"; do
  read -r path _ <<<"$p"
  bsdtar -xf "$dir/pkgs/$(basename "$path")" -C "$dir/root" --exclude '.*'
done
shopt -s nullglob
# Every entry of the machine's /usr/{include,lib,share} and of its pkg-config directories, except what the packages replace.
replaced_lib() { [[ $1 == libaquamarine* || $1 == libhyprutils* || $1 == libhyprgraphics* ]]; }
for e in /usr/include/*; do n=${e##*/}; [[ -e $dir/root/usr/include/$n ]] || ln -s "$e" "$dir/sysroot/usr/include/$n"; done
for e in "$dir"/root/usr/include/*; do ln -s "$e" "$dir/sysroot/usr/include/"; done
for e in /usr/lib/*; do n=${e##*/}; [[ $n == pkgconfig ]] || replaced_lib "$n" || ln -s "$e" "$dir/sysroot/usr/lib/$n"; done
for e in "$dir"/root/usr/lib/lib*; do ln -s "$e" "$dir/sysroot/usr/lib/"; done
for e in /usr/share/*; do n=${e##*/}; [[ $n == pkgconfig ]] || ln -s "$e" "$dir/sysroot/usr/share/$n"; done
for sub in lib/pkgconfig share/pkgconfig; do
  for e in /usr/"$sub"/*.pc; do n=${e##*/}; [[ -e $dir/root/usr/$sub/$n ]] || ln -s "$e" "$dir/sysroot/usr/$sub/$n"; done
  for e in "$dir"/root/usr/"$sub"/*.pc; do ln -s "$e" "$dir/sysroot/usr/$sub/"; done
done
ln -s usr/lib "$dir/sysroot/lib"
ln -s usr/lib "$dir/sysroot/lib64"
ln -s lib "$dir/sysroot/usr/lib64"
ln -s /usr/bin "$dir/sysroot/usr/bin"
PKG_CONFIG_SYSROOT_DIR=$dir/sysroot PKG_CONFIG_LIBDIR=$dir/sysroot/usr/lib/pkgconfig:$dir/sysroot/usr/share/pkgconfig \
  pkg-config --modversion hyprland >/dev/null
echo "hypr-sysroot: $dir/sysroot (hyprland $(PKG_CONFIG_SYSROOT_DIR=$dir/sysroot PKG_CONFIG_LIBDIR=$dir/sysroot/usr/lib/pkgconfig:$dir/sysroot/usr/share/pkgconfig pkg-config --modversion hyprland))"
