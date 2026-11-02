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
"$here/fetch-deps.sh" "$work"

emacs --batch -l "$here/build-db.el" \
  "$work" "$repo/test/fixtures/roam" "$work/org-roam.db"
python3 "$repo/tool/org_roam_parity.py" export \
  "$work/org-roam.db" "$repo/test/fixtures/roam" \
  > "$repo/test/fixtures/org_roam_expected.json"
python3 "$repo/tool/org_roam_parity.py" export-tables \
  "$work/org-roam.db" "$repo/test/fixtures/roam" \
  > "$repo/test/fixtures/org_roam_expected_tables.json"
echo "Wrote test/fixtures/org_roam_expected.json and org_roam_expected_tables.json"
