# Releases and installing with Obtainium

All builds run on GitHub Actions (`.github/workflows/build.yml`), in
three kinds (#167, decision 100):

| Build | Started by | Builds | Publishes |
|---|---|---|---|
| Pull request | every push to a pull request | the tests, Android, Linux, Windows, macOS | nothing |
| Pre-release | every merge to `main` | the tests, the signed APK | a GitHub pre-release `v0.2.1-dev.<run number>`, with the APK only |
| Full release | the owner, by hand ([below](#make-a-full-release)) | the tests and all four platforms | the latest GitHub release `v0.3.0`, with all four files |

## Versions

Versions follow semantic versioning: `<major>.<minor>.<patch>`.

- **A full release** gets the version of the last full release, raised
  by the step chosen when it is started: `patch` (0.2.0 → 0.2.1), `minor`
  (0.2.0 → 0.3.0, the default) or `major` (0.2.0 → 1.0.0). A version
  typed in (for example `1.0.0`) is taken instead; it must be higher than
  the last full release, or the build stops at once.
- **A pre-release** gets the next patch version with `-dev.<run number>`:
  after `v0.2.0`, a merge in run 412 is `v0.2.1-dev.412`. Semantic
  versioning sorts it below 0.2.1, so the next full release is always
  newer.
- **The old releases `v0.1.<run number>`** count as full releases before
  0.2.0. The first full release after them is 0.2.0 (1.0.0 with
  `major`), and until it exists the pre-releases are
  `0.2.0-dev.<run number>`.
- **The Android version code** is the run number, for both kinds, so each
  build is higher than every earlier one and installs as an update.
- `tool/release_version.dart` computes the version in the `version` job,
  from the published releases (`gh release list`). Only the releases made
  before that job first ran count, so a run that is run again gets the
  same version and replaces its own release.

## What changed: the changelog

`CHANGELOG.md` lists what changed, newest first. Every pull request adds
one entry at the top (see `AGENTS.md`); CI's "Changelog" check fails a pull
request that changes `lib/` or `android/` without one, unless it has the
label `skip-changelog`.

The release text is written by `tool/release_notes.dart`: the entries that
are in `CHANGELOG.md` now but were not in the previous release's copy,
then "Built from <sha>". For a full release the previous release is the
last full release, so its text lists everything merged since; for a
pre-release it is the last release of either kind. If there are no new
entries (for example when a release is built again), it uses the top
entry. The version is not in the
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

1. `version` (about half a minute) decides the kind of build and sets
   the version name, the version code `<run number>` and the previous
   release for the notes (`tool/release_version.dart`).
2. `build` (tests and the Android APK), `linux`, `windows` and `macos`
   need only `version`, so the four start together. For a pre-release
   the three desktop jobs are skipped. `org-roam` needs nothing and
   starts at once.
3. `release` (only on `main`) publishes: for a pre-release the APK, once
   `build` and `org-roam` have passed; for a full release the four files,
   once every job has passed.

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

## Make a full release

In the GitHub web UI:

1. Open the repository's **Actions** tab and choose the workflow
   **Build** on the left.
2. Click **Run workflow** (on the right, above the list of runs).
3. Leave **Use workflow from** on `main`.
4. Check **Make a full release with all platforms**.
5. Choose the step in **The step from the last full release**: `patch`,
   `minor` (the default) or `major`. Or type the version in **Or the
   version itself**, for example `1.0.0`; it is used instead of the step.
6. Click the green **Run workflow**.

From a terminal (or for Claude), the same:
`gh workflow run build.yml --ref main -f release=true -f bump=minor`
(or `-f version=1.0.0`).

The run's `version` job shows the version it chose. It stops with an
error if the version is not higher than the last full release, or if the
run is not on `main`. Without the check box, a run on `main` makes a
pre-release, as a merge does.

Runs on `main` wait for each other. If a merge comes while a full release
waits for an earlier run, GitHub cancels the waiting full release (it
keeps only the newest waiting run): start it again.

## Live image tests

The workflow `live-images.yml` makes real pictures with the app's image
code, to find out when a provider changes its API. Add these secrets under
Settings, Secrets and variables, Actions: `MISTRAL_API_KEY`,
`VERCEL_AI_GATEWAY_API_KEY` and `OPENROUTER_API_KEY`. A case whose secret
is missing fails with "The secret ... is not set".

It runs every Monday at 06:00 UTC, by hand (Actions, **Live image test**,
**Run workflow**), and as part of a full release when the image code
changed since the last full release. At a full release a failure only
warns: the release notes start with the failed cases. A weekly or manual
failure opens the issue "Live image test failed", or comments on it if it
is open. The result of each case is an annotation on the run.

Each run makes five pictures, so it costs a few cents. The normal test
step skips these tests (`--exclude-tags live`).

## Install with Obtainium

1. In Obtainium, tap **Add App**.
2. App source URL: `https://github.com/ChristianGeng/roam-graph-mobile`
3. Turn on **Include prereleases**, to get the APK of every merge. With
   it off, Obtainium installs only the full releases.
4. Tap **Add**, then **Install**.

The setting can be changed later in the app's settings in Obtainium.

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
downloads the newest full release from GitHub (GitHub's "latest"
release, never a pre-release) and installs it over the old one. Running
`install.sh` from a newer unpacked release does the same.
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
