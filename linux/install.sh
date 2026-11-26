#!/usr/bin/env bash
# Per-user KuroCatWork installation. Does not replace upstream KuroCat.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PET_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/kurocatwork"
PET_APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
PET_ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
"$HERE/kurocatwork" --version
mkdir -p "$PET_DATA/Resources" "$PET_APPS" "$PET_ICONS" "$HOME/.local/bin"
install -m 755 "$HERE/kurocatwork" "$PET_DATA/kurocatwork"
cp -R "$HERE/Resources/WorkSounds" "$PET_DATA/Resources/"
install -m 644 "$HERE/kurocatwork.png" "$PET_ICONS/kurocatwork.png"
printf '#!/bin/sh\nexec "%s/kurocatwork" "$@"\n' "$PET_DATA" > "$HOME/.local/bin/kurocatwork"
chmod 755 "$HOME/.local/bin/kurocatwork"
sed "s|^Exec=.*|Exec=\"$PET_DATA/kurocatwork\"|" "$HERE/kurocatwork.desktop" > "$PET_APPS/kurocatwork.desktop"
printf 'KuroCatWork installed to %s\nSearch KuroCatWork in your launcher.\n' "$PET_DATA"
