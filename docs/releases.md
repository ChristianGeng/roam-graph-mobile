# Releases and installing with Obtainium

Every push to `main` builds a signed APK on GitHub Actions
(`.github/workflows/build.yml`) and publishes it as a GitHub release named
`v0.1.<run number>`. Pull requests only test and build; they publish nothing.

## What changed: the changelog

`CHANGELOG.md` lists what changed, newest first. Every pull request adds
one entry at the top (see `AGENTS.md`); CI's "Changelog" check fails a pull
request that changes `lib/` or `android/` without one, unless it has the
label `skip-changelog`.

The release text is written by `tool/release_notes.dart`: the entries that
are in `CHANGELOG.md` now but were not in the previous published release's
copy, then "Built from <sha>". If there are none (for example when a
release is built again), it uses the top entry. The version is not in the
changelog, because it is only known when the release is built; the release
text carries it. Entries written before the changelog existed name their
version at their end.

## The signing key

Android installs an update only if it is signed with the same key as the
installed app. So every release is signed with one release key, stored as
four repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the `.jks` file, base64-encoded on one line |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `release` |
| `ANDROID_KEY_PASSWORD` | the key password |

The key is never in the repo; the repo is public. Keep a private copy of the
`.jks` file and the password. If the key is lost, the app cannot be updated
any more; it must be uninstalled and installed again with a new key.

The build on `main` checks all four before Gradle runs and fails with an
error that names each missing secret.

Only code that is already on `main` sees the key. Pull requests and manual
runs on other branches build with the debug key, with read-only permissions,
and publish nothing. A separate release job, the only one allowed to write,
publishes the APK. A new release stays a draft until its APK is attached, so Obtainium never sees a release without one; re-running the job reuses the release and replaces the APK.

## Install with Obtainium

1. In Obtainium, tap **Add App**.
2. App source URL: `https://github.com/ChristianGeng/roam-graph-mobile`
3. Tap **Add**, then **Install**.

Obtainium checks the releases for new versions and updates in one tap. The
repo is public, so no GitHub token is needed; a token only raises GitHub's
rate limit for frequent update checks.

In Obtainium's settings for the app, keep the APK filter on `\.apk$`: the
releases also carry the desktop app.

## Install on Linux (#116)

Each release also carries `roam-graph-<version>-linux-x64.tar.gz`, built on
Ubuntu 24.04.

1. Download it from the release and unpack it, for example to
   `~/.local/opt/roam-graph`:
   `tar -xzf roam-graph-*-linux-x64.tar.gz -C ~/.local/opt/roam-graph`
2. Start `~/.local/opt/roam-graph/bundle/roam-graph`.
3. Choose the org folder, the one that holds `roam/`.

It needs GTK 3 and libsecret, which Ubuntu has. "Open in Emacs" runs
`emacsclient`; Emacs needs `(server-start)`, which Doom runs. A newer
release is installed by unpacking it over the old one.

