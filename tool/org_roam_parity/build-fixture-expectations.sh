#!/usr/bin/env bash
# Rebuilds test/fixtures/org_roam_expected.json and
# org_roam_expected_tables.json with real org-roam.
#
# It builds an org-roam database from the sample files in
# test/fixtures/roam/ and exports it: as normalized JSON for the parser
# test (test/graph/org_roam_parity_test.dart), and every table for the
# database test (test/graph/org_roam_tables_test.dart).
# Run this after changing a sample file.
#
# Needs: git, Emacs 29 (with SQLite support), Python 3. Emacs 29's Org (9.6)
# is the Org the expectations were made with; a different Org may differ.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# org-roam and its dependencies, pinned.
fetch() { # repository, commit, folder
  git -C "$work" init -q "$3"
  git -C "$work/$3" fetch -q --depth 1 "https://github.com/$1" "$2"
  git -C "$work/$3" checkout -q FETCH_HEAD
}
fetch org-roam/org-roam 903bd4ec56d29247990d005ed9052c201e18b812 org-roam
fetch magit/emacsql 7a4c607912c8fdd1fca4def4915d68f43b12d4da emacsql
fetch magnars/dash.el d746dd9edcb67a108818beb0cdc78dc1cb466832 dash.el
fetch magit/magit be42a74513f15221dc364aa668822e05890e3a2f magit
fetch emacs-compat/compat 90880f81419577e1d3f68424d2a3adf31e6d663e compat
fetch tarsius/llama 6850d0c91b629da14fdff2300c222289d1a0029a llama
fetch tarsius/cond-let 09292a77001434f59ab55c775dec2b98cb18d028 cond-let

emacs --batch -l "$here/build-db.el" \
  "$work" "$repo/test/fixtures/roam" "$work/org-roam.db"
python3 "$repo/tool/org_roam_parity.py" export \
  "$work/org-roam.db" "$repo/test/fixtures/roam" \
  > "$repo/test/fixtures/org_roam_expected.json"
python3 "$repo/tool/org_roam_parity.py" export-tables \
  "$work/org-roam.db" "$repo/test/fixtures/roam" \
  > "$repo/test/fixtures/org_roam_expected_tables.json"
echo "Wrote test/fixtures/org_roam_expected.json and org_roam_expected_tables.json"
