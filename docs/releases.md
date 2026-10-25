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

## The build jobs

All jobs are in `.github/workflows/build.yml`. They run in this order
(decision 99):

1. `version` (a few seconds) sets the version name `0.1.<run number>` and
   the version code `<run number>`.
2. `build` (tests and the Android APK), `linux`, `windows` and `macos`
   need only `version`, so the four start together. `org-roam` needs
   nothing and starts at once.
3. `release` (only on `main`) needs all of them and publishes the four
   files.

`build` is still the only job that loads the release key, and only on
`main`; it also writes the release notes, which travel with the APK.
With the Linux packages in the cache, the longest job is `build`, and a
whole run takes about 9 minutes (measured on #178) instead of 22 when
every platform waited for it. With a cold cache and a slow Ubuntu mirror,
`linux` can take longer than `build`, and the run takes as long as
`linux`.

The Linux job keeps the Ubuntu packages it installs (GTK, CMake and the
rest, 30 MB) in the GitHub Actions cache. The Ubuntu mirror is sometimes
very slow, and the download then took 12 minutes instead of 20 seconds.
`tool/apt_cached.sh` uses a cached file only if its SHA256 is the one in
Ubuntu's signed package index, and downloads the rest.

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

Each release carries `roam-graph-<version>-linux-x64.tar.gz`, built on
Ubuntu 24.04. It needs GTK 3 and libsecret, which Ubuntu has.

1. Download it from the release and unpack it anywhere, for example in
   Downloads: `tar -xzf roam-graph-*-linux-x64.tar.gz`
2. Run `bundle/install.sh`. It copies the app to
   `~/.local/share/roam-graph/app` and adds **Roam Graph** to the app menu.
3. Start it from the menu and choose the org folder, the one that holds
   `roam/`.

**Updates:** run `~/.local/share/roam-graph/app/install.sh --update`. It
downloads the newest release from GitHub and installs it over the old
one. Running `install.sh` from a newer unpacked release does the same.
`install.sh --remove` takes the app and its menu entry away.

**What stays where:** the app's own data (its database of the graph,
settings, the edit history) is in `~/.local/share/io.github.christiangeng.roamgraph`;
API keys are in the system keyring; the notes stay in their folder. An
update or `--remove` changes none of them.

"Open in Emacs" runs `emacsclient`; Emacs needs `(server-start)`, which
Doom runs. Another command can be set in Settings.

## Install on Windows (#116)

Each release carries `roam-graph-<version>-windows-x64.zip`.

1. Unpack it, for example to `%LOCALAPPDATA%\Programs\Roam Graph`.
2. Start `roam_graph_mobile.exe`; to have it in the Start menu, right-click
   it and choose "Pin to Start".
3. "Open in Emacs" runs `emacsclientw.exe`; if Emacs is not on the `PATH`,
   set its full path in Settings, for example
   `C:\Program Files\Emacs\emacs-30.1\bin\emacsclientw.exe`.

The app is not signed, so Windows SmartScreen may warn the first time:
"More info", then "Run anyway". An update is unpacked over the old folder.

## Install on macOS (#116)

Each release carries `roam-graph-<version>-macos.zip`, the app for Apple
silicon and Intel.

1. Unpack it and move **Roam Graph** to Applications.
2. The app is not signed: the first time, macOS refuses to open it. Open
   System Settings → Privacy & Security and choose "Open Anyway" for Roam
   Graph, once.
3. "Open in Emacs" runs `emacsclient`. Apps started from the Dock do not
   see the shell's `PATH`, so set the full path in Settings, for example
   `/opt/homebrew/bin/emacsclient`.

An update replaces the app in Applications.
