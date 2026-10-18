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
BASE="${XDG_DATA_HOME:-$HOME/.local/share}/roam-graph"
DEST="$BASE/app"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ENTRY="$APPS/io.github.christiangeng.roamgraph.desktop"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCK="$BASE/.install.lock"
WORK=""

cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  rmdir "$LOCK" 2>/dev/null || true
}

# One install, update or removal at a time: mkdir is atomic.
lock() {
  mkdir -p "$BASE"
  if ! mkdir "$LOCK" 2>/dev/null; then
    echo "Another install or update is running (or one was cut off: then" >&2
    echo "remove $LOCK)." >&2
    exit 1
  fi
  trap cleanup EXIT
  trap 'exit 130' INT TERM
}

# The number of "Roam Graph 0.1.249", for comparing versions.
version_of() {
  sed -n 's/^Roam Graph \([0-9.]*\).*/\1/p' "$1/VERSION" 2>/dev/null | head -n 1
}

install_from() {
  src="$1"
  if [ ! -x "$src/roam-graph" ]; then
    echo "No roam-graph in $src." >&2
    exit 1
  fi
  mkdir -p "$APPS"
  # The new copy is made next to the old one; the old one is moved aside
  # only when the new one is complete, and comes back if the swap fails.
  rm -rf "$DEST.new" "$DEST.old"
  cp -R "$src" "$DEST.new"
  if [ -e "$DEST" ]; then
    mv "$DEST" "$DEST.old"
  fi
  if ! mv "$DEST.new" "$DEST"; then
    [ -e "$DEST.old" ] && mv "$DEST.old" "$DEST"
    echo "The new copy could not be moved into place; the old one stays." >&2
    exit 1
  fi
  rm -rf "$DEST.old"
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

update() {
  command -v curl >/dev/null 2>&1 || { echo "curl is needed." >&2; exit 1; }
  fetch="curl -fsSL --proto =https --connect-timeout 20 --max-time 600"
  WORK=$(mktemp -d)
  $fetch "https://api.github.com/repos/$REPO/releases/latest" -o "$WORK/release.json"
  # The Linux package of this repository's newest release, and its SHA-256
  # as GitHub gives it.
  url=$(tr ',' '\n' < "$WORK/release.json" |
    sed -n 's/.*"browser_download_url": *"\([^"]*-linux-x64\.tar\.gz\)".*/\1/p' |
    head -n 1)
  case "$url" in
    "https://github.com/$REPO/releases/download/"*) ;;
    *)
      echo "No Linux package of $REPO in the newest release." >&2
      exit 1
      ;;
  esac
  digest=$(tr '{' '\n' < "$WORK/release.json" | grep -F "\"$url\"" |
    sed -n 's/.*"digest": *"sha256:\([0-9a-f]*\)".*/\1/p' | head -n 1)
  echo "Downloading $url"
  $fetch "$url" -o "$WORK/roam-graph.tar.gz"
  if [ -n "$digest" ]; then
    actual=$(sha256sum "$WORK/roam-graph.tar.gz" | cut -d ' ' -f 1)
    if [ "$actual" != "$digest" ]; then
      echo "The download does not match its SHA-256; nothing is installed." >&2
      exit 1
    fi
  fi
  # Only plain files and folders under bundle/: no absolute paths, no
  # "..", no links, so nothing is written outside the work folder.
  if tar -tzf "$WORK/roam-graph.tar.gz" | grep -Ev '^bundle(/|$)' | grep -q . ||
     tar -tzf "$WORK/roam-graph.tar.gz" | grep -Eq '(^|/)\.\.(/|$)' ||
     tar -tvzf "$WORK/roam-graph.tar.gz" | grep -Eq '^[^-d]'; then
    echo "The package holds unexpected paths; nothing is installed." >&2
    exit 1
  fi
  tar -xzf "$WORK/roam-graph.tar.gz" -C "$WORK" --no-same-owner
  new=$(version_of "$WORK/bundle")
  old=$(version_of "$DEST")
  if [ -n "$old" ] && [ -n "$new" ]; then
    if [ "$new" = "$old" ]; then
      echo "Roam Graph $old is the newest release already."
      return 0
    fi
    newest=$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n 1)
    if [ "$newest" = "$old" ]; then
      echo "The newest release ($new) is older than the installed $old;" >&2
      echo "nothing is changed." >&2
      return 0
    fi
  fi
  install_from "$WORK/bundle"
}

case "${1:-}" in
  --remove)
    lock
    rm -rf "$DEST" "$DEST.new" "$DEST.old" "$ENTRY"
    echo "Removed. Notes, settings and API keys are untouched."
    ;;
  --update)
    lock
    update
    ;;
  "")
    lock
    install_from "$HERE"
    ;;
  *)
    echo "Usage: $0 [--update | --remove]" >&2
    exit 2
    ;;
esac
