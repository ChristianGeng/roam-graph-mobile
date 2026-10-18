#!/bin/sh
# Installs Roam Graph for the current user, from the unpacked release
# (#116), and adds it to the app menu. Run it again from a newer release
# to update, or with --update to fetch the newest release from GitHub.
#
#   ./install.sh            install this copy
#   ./install.sh --update   download the newest release and install it
#   ./install.sh --remove   remove the app and its menu entry (the notes,
#                           settings and API keys stay)
set -eu

REPO="ChristianGeng/roam-graph-mobile"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/roam-graph/app"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ENTRY="$APPS/io.github.christiangeng.roamgraph.desktop"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

install_from() {
  src="$1"
  if [ ! -x "$src/roam-graph" ]; then
    echo "No roam-graph in $src." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$DEST")" "$APPS"
  # The new copy goes next to the old one first, then takes its place.
  rm -rf "$DEST.new"
  cp -R "$src" "$DEST.new"
  rm -rf "$DEST"
  mv "$DEST.new" "$DEST"
  cat > "$ENTRY" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Roam Graph
Comment=Browse and edit the org-roam graph
Exec="$DEST/roam-graph"
Icon=$DEST/roam-graph.png
Terminal=false
Categories=Office;Utility;
StartupWMClass=io.github.christiangeng.roamgraph
DESKTOP
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$APPS" >/dev/null 2>&1 || true
  echo "Installed $(cat "$DEST/VERSION" 2>/dev/null || echo Roam Graph) in $DEST."
  echo "Start it from the app menu, or with $DEST/roam-graph."
}

case "${1:-}" in
  --remove)
    rm -rf "$DEST" "$ENTRY"
    echo "Removed. Notes, settings and API keys are untouched."
    ;;
  --update)
    command -v curl >/dev/null 2>&1 || { echo "curl is needed." >&2; exit 1; }
    url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
      grep -o '"browser_download_url": *"[^"]*-linux-x64\.tar\.gz"' |
      sed 's/.*"\(https[^"]*\)"$/\1/' | head -n 1)
    if [ -z "$url" ]; then
      echo "No Linux package in the newest release." >&2
      exit 1
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    echo "Downloading $url"
    curl -fsSL "$url" -o "$work/roam-graph.tar.gz"
    tar -xzf "$work/roam-graph.tar.gz" -C "$work"
    install_from "$work/bundle"
    ;;
  "")
    install_from "$HERE"
    ;;
  *)
    echo "Usage: $0 [--update | --remove]" >&2
    exit 2
    ;;
esac
