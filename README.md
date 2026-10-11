# roam-graph-mobile

Browse my org-roam node graph on Android (tablet and phone), offline and
without Emacs. The org files reach the devices through Syncthing.

Status: planning. The app skeleton builds and installs, but shows only its
name and version. What is decided and why is in
[docs/decisions.md](docs/decisions.md); the work is in the
[issues](https://github.com/ChristianGeng/roam-graph-mobile/issues).

## Stack

Flutter (decided in #1). `org_parser` and `org_flutter` are the parser and
renderer that Orgro uses, so my files are already known to parse and render
correctly; Flutter can also hand a file to Orgro with `ACTION_VIEW`. The full
reasoning, including the comparison with a PWA, is in
[docs/decisions.md](docs/decisions.md).

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
