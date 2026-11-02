#!/usr/bin/env bash
# Byte-compiles emacs/roam-graph-follow.el (warnings are errors) and runs
# its ERT tests with real org-roam.
#
# Usage: emacs/run-tests.sh [DEPS-DIR]
#
# DEPS-DIR holds org-roam and its dependencies as
# tool/org_roam_parity/fetch-deps.sh fetches them; without it, they are
# fetched into a temporary folder.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
out=$(mktemp -d)
cleanup=("$out")
trap 'rm -rf "${cleanup[@]}"' EXIT
deps=${1:-}
if [ -z "$deps" ]; then
  deps=$(mktemp -d)
  cleanup+=("$deps")
  "$repo/tool/org_roam_parity/fetch-deps.sh" "$deps"
fi

load=()
for dir in compat dash.el llama cond-let emacsql magit/lisp org-roam; do
  load+=(-L "$deps/$dir")
done

cp "$here/roam-graph-follow.el" "$out/"
emacs --batch "${load[@]}" -L "$out" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$out/roam-graph-follow.el"

emacs --batch "${load[@]}" -L "$here" \
  -l "$here/test/roam-graph-follow-test.el" \
  -f ert-run-tests-batch-and-exit
