#!/usr/bin/env bash
# Installs Ubuntu packages in CI and keeps their .deb files in a folder
# that actions/cache saves, so a slow Ubuntu mirror does not slow every
# build (#166, decision 97).
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
    }' |
    while read -r name version arch; do
      sha=$(apt-cache show --no-all-versions "$name:$arch=$version" |
        awk '$1 == "SHA256:" { print $2; exit }')
      if [ -z "$sha" ]; then
        echo "No SHA256 for $name $version $arch in the package index." >&2
        exit 1
      fi
      # apt's own file name: a ":" in the version (an epoch) is "%3a".
      echo "${name}_${version//:/%3a}_${arch}.deb $sha"
    done | sort
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
