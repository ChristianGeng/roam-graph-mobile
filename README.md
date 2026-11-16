# roam-graph-mobile

Roam Graph shows an org-roam knowledge graph on Android (phone and tablet)
and on Linux, Windows and macOS, offline and without Emacs. The org files
reach the devices through Syncthing; the app reads the folder, builds the
same graph org-roam builds, and draws it. It can also create and edit
notes, and it has an AI chat that works on the notes.

## What it does

**Graph**
- Draws the graph like `org-roam-graph`: the whole graph, the part
  connected to a node, or its neighbourhood of 1 to 3 links.
- Layouts: circular, force-directed, radial, grouped by communities and
  hierarchical; the one at start is a setting.
- Views from graph algorithms: communities, PageRank, number of links and
  shortest paths.
- On a tablet held sideways, graph and note side by side, with a divider
  to drag and a graph to fold away.

**Note view**
- Notes as formatted Org, with tappable `id:` links (also to a heading),
  links and backlinks, and web, mail and phone links that open in their
  app.
- Sections open collapsed or expanded, as set; a note's own `#+STARTUP:`
  line comes first.
- Images from the notes folder at their Org width, SVG too.
- Mermaid and PlantUML blocks show the image Emacs made; a block without
  one is drawn on the device.
- LaTeX formulas on Android, display formulas on their own line.
- Source blocks coloured as Emacs colours them, code in a monospace font.
- Search inside a note; tick checkboxes and change TODO states.
- On Android, a note opens read-only in another app, such as Orgro, and
  can be shared as text or as an Org file.

**Search**
- Finds notes by title, alias and tag as you type, and the words inside
  notes.
- Selected results can be shared with an AI app, deleted, or given a
  language.

**Capture and editing**
- New notes as org-roam's capture makes them; one made from a note can
  link to it.
- Text, text files and Org files shared from another app become new
  notes; a shared audio file becomes a transcribed voice memo.
- Edit a note's text, title, tags and aliases, its headings and links;
  delete notes.
- Every edit shows a diff first, is saved only over the version it was
  made on, and keeps the old version, so it can be undone. The `:ID:` and
  the property drawer stay as they are.
- Files are written safely next to Syncthing; its conflict copies are
  listed.

**AI chat**
- The chat works on the app's own index of the notes, with the tools of
  the org-roam MCP server (search, backlinks, paths, PageRank,
  communities and others).
- Providers: Anthropic, Claude on AWS Bedrock (EU), Mistral, Scaleway,
  Vercel AI Gateway, DeepSeek, Qwen, OpenRouter, Hugging Face, or a custom
  one, with your own key. The model is chosen from the provider's list.
- In agent mode (the default) the AI creates, edits and links notes
  itself, under the same rules as hand edits, with "Undo all"; in review
  mode it proposes edits that are saved only after the diff.
- "Edit with AI" changes a note, or also its linked notes, by an
  instruction.
- Images, infographics and charts made by the AI and added to a note.
- Optional web access; chats are kept on the device and can run in
  parallel and in the background.
- Notes with a tag such as `:private:` are never sent to an AI.

**Desktop**
- Notes open in Emacs at their heading.
- The graph follows the node at point in Emacs, with
  `roam-graph-follow-mode` from `emacs/roam-graph-follow.el`, which the
  desktop packages carry.
- Files and text can be dropped on the window; keys can be set, with an
  Emacs set.
- The app checks for a new release; on Linux it can update and restart
  itself.

Read more:

- [The help pages](assets/help/start.org): how to use each part, also in
  the app.
- [CHANGELOG.md](CHANGELOG.md): what changed when.
- [docs/decisions.md](docs/decisions.md): what was decided and why.
- [docs/releases.md](docs/releases.md): releases, the signing key and the
  desktop installs.
- [docs/development.md](docs/development.md): checks against org-roam
  for developers.
- The work: [issues](https://github.com/ChristianGeng/roam-graph-mobile/issues).

## Install

### Android, with Obtainium

[Obtainium](https://github.com/ImranR98/Obtainium) installs the app from this
repository's GitHub releases and keeps it updated. No GitHub account is
needed.

1. Install Obtainium (from its GitHub releases or from F-Droid).
2. In Obtainium, choose **Add App**, paste
   `https://github.com/ChristianGeng/roam-graph-mobile`, and choose **Add**.
   Or open this link on the phone, which fills it in:
   [obtainium://add/https://github.com/ChristianGeng/roam-graph-mobile](obtainium://add/https://github.com/ChristianGeng/roam-graph-mobile)
3. Install. Obtainium reports every new full release from then on.

Good to know:

- Obtainium installs *full* releases. The pre-releases that every merge
  publishes (`v<version>-dev.<n>`, APK only) come only with "Include
  prereleases" turned on for the app.
- Every release is signed with the same release key, so updates install over
  the old version. A build signed with another key (a local build, see below)
  can't update it.
- The app needs an org-roam folder on the phone, for example kept in step
  with Syncthing; it asks for the folder at the first start. The AI chat uses
  your own provider and API key, set in Settings → AI.

### Linux

Download the installer of the newest full release with its checksum into a
new, empty folder and check it (the `&&` stops at a failed download, so no
older file is checked):

```
d=$(mktemp -d) && cd "$d" &&
  curl -fsSLO https://github.com/ChristianGeng/roam-graph-mobile/releases/latest/download/install.sh &&
  curl -fsSLO https://github.com/ChristianGeng/roam-graph-mobile/releases/latest/download/install.sh.sha256 &&
  sha256sum -c install.sh.sha256
```

It must print `install.sh: OK`. The checksum file comes from the same release
as the script. To check against GitHub's own record as well, compare the hex
string `sha256sum install.sh` prints with the digest GitHub shows next to
`install.sh` on the release page ("sha256:…"), or prints with:

```
gh release view --repo ChristianGeng/roam-graph-mobile --json assets \
  --jq '.assets[] | select(.name == "install.sh") | .digest'
```

If the two differ, stop and do not run the script. Otherwise run the
installer in the same folder; the `&&` runs it only if the checksum still
matches:

```
sha256sum -c install.sh.sha256 && sh install.sh --update
```

The installer is a file of the release, the same one as in the Linux
package, not whatever `main` holds now. It installs the newest full release
into `${XDG_DATA_HOME:-$HOME/.local/share}/roam-graph/app` and adds Roam
Graph to the app menu, after checking the package it downloads against the
SHA-256 that GitHub gives for it. To update later, run the installed copy:
`${XDG_DATA_HOME:-$HOME/.local/share}/roam-graph/app/install.sh --update`.
The app runs on Ubuntu 22.04 and newer.

### Windows and macOS

Each full release has a zip file for Windows and one for macOS. The apps are
not signed yet; [docs/releases.md](docs/releases.md) says how to open them
the first time, and explains the signing key.

## Build locally

The app is written in Flutter, with `org_parser` and `org_flutter`, the
parser and renderer that Orgro uses; the reasons are in
[docs/decisions.md](docs/decisions.md). With Flutter 3.47.7 installed (the
version the workflow pins):

```
flutter pub get
flutter test
flutter build apk --release
```

A local release build is signed with the debug key, so it cannot update an
APK installed from a GitHub release.
