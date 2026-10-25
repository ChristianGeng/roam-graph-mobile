#!/usr/bin/env bash
# Installs Ubuntu packages in CI and keeps their .deb files in a folder
# that actions/cache saves, so a slow Ubuntu mirror does not slow every
# build (#166, decision 99).
#
#   tool/apt_cached.sh list <package>...
#       After apt-get update: prints the files apt would download now,
#       one "<file> <SHA256>" line each, from the signed package index.
#       The cache key is a hash of this list.
#   tool/apt_cached.sh install <folder> <list> <package>...
#       Keeps only the files in <folder> that are in <list> with the same
#       SHA256, then installs the packages, taking those files from
#       <folder> and downloading the rest into it.
#
# apt itself does not check a file that is already in its download
# folder, so the SHA256 check here is what makes a cached file safe.
set -euo pipefail

list() {
  local tmp
  tmp=$(mktemp)
  trap "rm -f '$tmp' '$tmp.sha' '$tmp.files'" EXIT
  # "Inst <name> [<old version>] (<version> <release>, ... [<arch>]) [...]"
  apt-get install -s -y --no-install-recommends "$@" |
    awk '$1 == "Inst" {
      version = ""; arch = ""
      for (i = 3; i <= NF; i++) {
        if (version == "" && $i ~ /^\(/) version = substr($i, 2)
        if ($i ~ /^\[[^]]+\]\)$/) { arch = substr($i, 2, length($i) - 3); break }
      }
      if (version == "" || arch == "") { print "Cannot read: " $0 > "/dev/stderr"; exit 1 }
      print $2, version, arch
    }' > "$tmp"
  local wanted
  wanted=$(wc -l < "$tmp")
  # One apt-cache call for all packages: one call each took 30 seconds.
  # shellcheck disable=SC2046
  apt-cache show --no-all-versions $(awk '{ print $1 ":" $3 "=" $2 }' "$tmp") |
    awk '
      $1 == "Package:" { name = $2 }
      $1 == "Version:" { version = $2; gsub(/:/, "%3a", version) }
      $1 == "Architecture:" { arch = $2 }
      $1 == "SHA256:" { sha = $2 }
      $0 == "" { if (name != "") print name "_" version "_" arch ".deb", sha; name = sha = "" }
      END { if (name != "") print name "_" version "_" arch ".deb", sha }
    ' | sort -u > "$tmp.sha"
  # apt's own file name: a ":" in the version (an epoch) is "%3a".
  awk '{ v = $2; gsub(/:/, "%3a", v); print $1 "_" v "_" $3 ".deb" }' "$tmp" | sort > "$tmp.files"
  if ! awk '$2 != ""' "$tmp.sha" | cut -d' ' -f1 | cmp -s - "$tmp.files"; then
    echo "No SHA256 in the package index for:" >&2
    awk '$2 != "" { print $1 }' "$tmp.sha" | comm -13 - "$tmp.files" >&2
    exit 1
  fi
  [ "$(wc -l < "$tmp.files")" -eq "$wanted" ]
  cat "$tmp.sha"
}

install() {
  local folder=$1 wanted=$2
  shift 2
  mkdir -p "$folder"
  local kept=0 file
  for file in "$folder"/*.deb; do
    [ -e "$file" ] || continue
    local name sha
    name=$(basename "$file")
    sha=$(awk -v f="$name" '$1 == f { print $2 }' "$wanted")
    if [ -n "$sha" ] && [ "$(sha256sum < "$file" | cut -d' ' -f1)" = "$sha" ]; then
      kept=$((kept + 1))
    else
      rm -f "$file"
    fi
  done
  echo "Taken from the cache: $kept of $(wc -l < "$wanted") files."
  sudo apt-get install -y -q --no-install-recommends \
    -o Dir::Cache::Archives="$folder" "$@"
  # apt's lock and partial folder belong to root; the cache needs only the
  # .deb files.
  sudo rm -rf "$folder/partial" "$folder/lock"
}

command=$1
shift
case "$command" in
  list) list "$@" ;;
  install) install "$@" ;;
  *) echo "Usage: $0 list|install ..." >&2; exit 2 ;;
esac
