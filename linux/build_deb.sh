#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-1.4.6}"
ARCH="$(dpkg --print-architecture)"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "$PKG_DIR"' EXIT
[ -f "$ROOT/kurocatwork" ] || bash "$ROOT/build.sh"
mkdir -p "$PKG_DIR/DEBIAN" "$PKG_DIR/usr/bin" "$PKG_DIR/usr/share/applications" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps" "$PKG_DIR/usr/share/kurocatwork/WorkSounds" "$PKG_DIR/usr/share/doc/kurocatwork"
install -m 755 "$ROOT/kurocatwork" "$PKG_DIR/usr/bin/kurocatwork"
install -m 644 "$ROOT/kurocatwork.desktop" "$PKG_DIR/usr/share/applications/kurocatwork.desktop"
install -m 644 "$ROOT/kurocatwork.png" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/kurocatwork.png"
cp -R "$ROOT/../Resources/WorkSounds/." "$PKG_DIR/usr/share/kurocatwork/WorkSounds/"
cp "$ROOT/../LICENSE" "$PKG_DIR/usr/share/doc/kurocatwork/copyright"
cat > "$PKG_DIR/DEBIAN/control" <<CONTROL
Package: kurocatwork
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Depends: libc6 (>= 2.28), libstdc++6 (>= 8), libgtk-3-0 (>= 3.22) | libgtk-3-0t64, libcairo2, libx11-6, libxi6
Recommends: curl, pulseaudio-utils
Maintainer: andyforfun168 <348137253+andyforfun168@users.noreply.github.com>
Homepage: https://github.com/andyforfun168/KuroCatWork
Description: Native cat companion for Codex and Claude work
 Desktop cat with native keyboard and mouse interaction, work-mode usage
 and task bubbles. Built on KuroCat by chanke17.
CONTROL
chmod -R u=rwX,go=rX "$PKG_DIR"
dpkg-deb --build --root-owner-group "$PKG_DIR" "$ROOT/KuroCatWork-Linux-${ARCH}.deb"
