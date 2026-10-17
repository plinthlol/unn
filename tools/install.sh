#!/bin/sh
# usage: tools/install.sh [prefix]   (default ~/.local; builds a release binary first)
# Runs ./build.sh release, then installs the binary under <prefix>/bin plus the desktop
# entry and icon under <prefix>/share; best-effort refreshes of the desktop and icon
# caches afterwards (each skipped silently when its tool is missing). This is the repo's
# only install script.
set -e
cd "$(dirname "$0")/.."
prefix=${1:-$HOME/.local}
./build.sh release
install -Dm755 build/unn "$prefix/bin/unn"
install -Dm644 assets/unn.desktop "$prefix/share/applications/unn.desktop"
install -Dm644 assets/icons/unn.svg "$prefix/share/icons/hicolor/scalable/apps/unn.svg"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$prefix/share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qtf "$prefix/share/icons/hicolor" 2>/dev/null || true
echo "installed to $prefix"
