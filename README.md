# roam-graph-mobile

Browse my org-roam node graph on Android (tablet and phone), offline and
without Emacs. The org files reach the devices through Syncthing.

Status: v1 in progress. The app reads the org folder and builds the graph
(#3, #4), and shows its counts; there is no graph view yet. What is decided and why is in
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
both sides, and every difference. Nothing leaves the laptop. CI runs the
same comparison on the sample files in `test/fixtures/roam/`, against a
database real org-roam built from them
(`tool/org_roam_parity/build-fixture-expectations.sh`).

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
