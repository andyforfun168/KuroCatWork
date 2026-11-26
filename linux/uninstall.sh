#!/usr/bin/env bash
# Removes only files installed by KuroCatWork's per-user installer. Keeps settings and skins.
set -euo pipefail
PET_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
rm -f "$HOME/.local/bin/kurocatwork" "$PET_DATA/applications/kurocatwork.desktop" "$PET_DATA/icons/hicolor/256x256/apps/kurocatwork.png"
printf 'Launcher removed. App files remain in %s/kurocatwork; settings and skins are preserved.\n' "$PET_DATA"
