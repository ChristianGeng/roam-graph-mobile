# roam-graph-mobile

Browse my org-roam node graph on Android (tablet and phone), offline and
without Emacs. The org files reach the devices through Syncthing.

Status: v1 in progress. The app reads the org folder, builds the graph
(#3, #4), stores it in an SQLite database with org-roam's schema (#5),
shows its counts, and draws the graph like `org-roam-graph`, as a whole or
around one node, with a circular (`circo`) or a force-directed layout (#6).
A tap on a node opens it as formatted Org, with tappable `id:` links and its
backlinks (#8). Search finds nodes by title, alias and tag as you type (#9).
A button opens the node's file in Orgro, read-only (#10). On a tablet in
landscape, graph and node view are side by side (#16). Graph views show
communities, importance and shortest paths, as my org-roam MCP server
computes them (#7). A "New node" button creates a node as org-roam's
capture would, in a file Syncthing brings to the laptop (#11); captured
from a node, it links back to it, so it shows as a backlink (#12). Files are
written safely next to Syncthing, and its conflict copies are listed (#13).
Text shared from another app, such as the Claude app, becomes a new node
(#15), and the graph's structure (#40) and chosen nodes with their texts
(#41) can be shared to such an app. Source blocks are coloured as Emacs
colours them (#45), and images from the notes folder, also SVG, are
shown at their Org width (#46, #47). What is decided and why is in
[docs/decisions.md](docs/decisions.md); the work is in the
[issues](https://github.com/ChristianGeng/roam-graph-mobile/issues).

## Stack

Flutter (decided in #1). `org_parser` and `org_flutter` are the parser and
renderer that Orgro uses, so my files are already known to parse and render
correctly; Flutter can also hand a file to Orgro with `ACTION_VIEW`. The full
reasoning, including the comparison with a PWA, is in
[docs/decisions.md](docs/decisions.md).

## Check the parser against org-roam

The app builds the graph from the org files itself. To compare it with the
`org-roam.db` Emacs keeps on the laptop, with Flutter and Python 3 installed:

```
python3 tool/org_roam_parity.py check \
    ~/doom-emacs/.local/cache/org-roam.db ~/work/cgeng/org/roam
```

It prints the counts of files, nodes, `id:` links, tags, aliases and refs on
both sides, and every difference; for a link, also the file and line where
only one side finds it, with the lines around it. Nothing leaves the laptop. CI runs the
same comparison on the sample files in `test/fixtures/roam/`, against a
database real org-roam built from them
(`tool/org_roam_parity/build-fixture-expectations.sh`).

## Check the database against org-roam

The app keeps the graph in an SQLite database with org-roam's tables and
encoding (#5). To build the same database on the laptop and compare every
table with Emacs's, with Flutter and Python 3 installed, first run
`M-x org-roam-db-sync` in Emacs, so its database is current, then:

```
flutter pub get
uv run tool/org_roam_parity.py check-db \
    ~/doom-emacs/.local/cache/org-roam.db ~/work/cgeng/org/roam
```

To get the database itself, for example to run the org-roam MCP server's
queries on it:

```
dart run tool/build_roam_db.dart ~/work/cgeng/org/roam /tmp/app-org-roam.db
```

Point the MCP server's database path at `/tmp/app-org-roam.db`; its read-only
queries should return the same results as on `org-roam.db`. Running the
command again reads only new and changed files.

## Install

Install and update with Obtainium from this repo's GitHub releases. See
[docs/releases.md](docs/releases.md), which also explains the signing key.

## Build locally

With Flutter 3.47.7 installed (the version the workflow pins):

```
flutter pub get
flutter test
flutter build apk --release
```

A local release build is signed with the debug key, so it cannot update an
APK installed from a GitHub release.
