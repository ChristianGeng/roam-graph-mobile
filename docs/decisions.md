# Decisions so far

Input for the spec, not the spec itself. Collected in the brainstorming
session of 2026-10-11, which also created the issues. Each decision has its
reason, so a later session can tell a deliberate choice from an accident.
Change a decision here, with its new reason, before building against a
different one.

## What the app is for

I keep my knowledge graph in org-roam, in Emacs on my laptop. I want to
browse that graph on my Android tablet and phone without the laptop, and in
v2 extend it there: create new nodes. The org files already reach both
devices through Syncthing.

## Decided

1. **A native Android app**, not Emacs on Android and not Python in Termux
   with a browser. Both alternatives work in principle but feel clumsy on a
   touchscreen.

2. **Entirely Emacs-free on the device.** The app parses the org files
   itself, keeps its own database and renders nodes itself. The only link to
   the laptop is the Syncthing folder: Emacs edits files on the laptop, the
   app reads them, and from v2 it also writes new ones. The laptop builds its
   own `org-roam.db` from the same files. No Emacs is reached remotely.

3. **The device has no `org-roam.db`.** It lives in the Emacs cache on the
   laptop (`~/doom-emacs/.local/cache/org-roam.db`), outside the synced
   folder, and is a cache only Emacs maintains. So the app must build the
   graph from the files.

4. **Index `roam/` only.** That is `org-roam-directory`. Journals are left
   out on purpose, although the laptop database also lists `journal/` files.
   Hundreds of other org files carry `:ID:` (`.archive/`, `ref.org`, ...) and
   are not part of the graph.

5. **Store the graph in org-roam's SQLite schema and encoding.** Tables
   `files`, `nodes`, `aliases`, `citations`, `refs`, `tags`, `links`.
   org-roam stores every value as an Emacs Lisp string, quotation marks
   included: an ID is `"37c2520b-..."` with the quotes. Matching both means
   the queries of my org-roam MCP server (`cgeng-ai-skills`,
   `mcps/org_roam`) work on the app's database unchanged.

6. **Render nodes in the app, plus "Open in Orgro".** I already read org on
   the phone with Orgro. Checked in Orgro's source (commit 53f6398):
   - It opens a file sent by another app (`ACTION_VIEW`).
   - It has no external way to jump to a heading. Its `org-protocol` handles
     only `capture`. It has `narrowByFragment`, but only for web documents.
   - Its FAQ says `id:` links between files do not resolve in a file that
     another app opened.

   So the app renders the node itself, with tappable `id:` links and
   backlinks, and offers "Open in Orgro" at file level for full reading and
   editing. This loses little: 451 of my 452 nodes are whole files.

7. **The graph view mirrors my `org-roam-graph` settings.** Only `id:` links
   are edges. `file`, `https`, `http`, `fuzzy` and `mailto` links are hidden
   (`org-roam-graph-link-hidden-types`). Layout `circo`, plus a
   force-directed one. (My Emacs does not actually use `circo`; see 24.)

8. **Graph algorithms as views:** neighbourhood, communities (Louvain),
   importance (PageRank, degree), shortest path. My MCP server computes the
   same with `networkx`, so its results are the reference.

9. **v1 is read-only. Capture is v2.** Read-only cannot damage my notes.
   Capture brings org-roam-compatible file names and IDs and Syncthing
   conflicts, which deserve their own milestone.

10. **v2 capture writes only new files**, never into existing ones. A new
    node links to the current node from inside the new file, so it shows up
    as a backlink. Editing an existing file risks a Syncthing conflict with
    the laptop. File names follow my capture template, which is org-roam's
    default: `roam/<%Y%m%d%H%M%S>-<slug>.org`.

11. **AI input through Android's share menu, not MCP.** The Claude Android
    app cannot write to device storage, but it can share text. The app
    accepts shared text as a new node (#15).

12. **Tablet and phone layouts differ** (#16): graph and node side by side
    on the tablet in landscape, one screen at a time on the phone.

13. **APK from GitHub Actions, installed with Obtainium.** One stable signing
    key as a repository secret, so updates install over the old version.
    Obtainium installs and updates from the GitHub releases.

14. **No real notes in the repo.** The repo is public. Tests use synthetic
    org files; the comparison with my real data is a local script.

15. **Stack: Flutter** (#1), decided on 2026-10-11. `org_parser` and
    `org_flutter` are the parser and the renderer Orgro uses, by the same
    author, so my files are already known to parse and render correctly with
    them. Graph in a WebView with Cytoscape.js, algorithms with `graphology`
    in the same WebView. The alternatives were Kotlin with Jetpack Compose
    (org rendering via `uniorg` in a WebView, algorithms with JGraphT) and a
    PWA; "Flutter or PWA" below says why Flutter won. The graph view is
    drawn by Flutter instead of Cytoscape.js (decision 24).

16. **Flutter is pinned** in the build workflow (3.47.7 at the start). The
    files under `android/` come from that version's `flutter create`
    templates, so the Android Gradle Plugin, Kotlin and Gradle versions match
    what that Flutter expects. Update Flutter and the `android/` files
    together. As in Flutter's own template, `gradlew` and
    `gradle-wrapper.jar` are not committed: `flutter build` creates them, so
    a fresh clone builds with only Flutter installed.

17. **Application ID `io.github.christiangeng.roamgraph`.** Android treats a
    different ID as a different app, so it never changes.

18. **Release versions are `0.1.<run number>`**, with the workflow run
    number as the version code, so every release installs as an update.

19. **Folder access through Android's Storage Access Framework, called
    directly** (#3). A small Kotlin class (`FolderAccess.kt`) opens the
    folder picker, takes a persistable read permission and lists files over
    a method channel. No plugin: the APIs are stable and short, and it adds
    no dependency. Which files belong to the graph is decided in Dart
    (`lib/folder/org_files.dart`), so those rules are unit-tested. The app
    remembers the chosen folder, so it can tell "never chosen" from
    "permission lost" and ask again in the second case. The chosen folder
    must be `roam/` itself (by its name) or contain `roam/`; any other
    folder counts nothing and the app says so, so notes outside `roam/`
    never enter the graph.

20. **The graph is read by a parser that reproduces org-roam's rules**
    (#4), `lib/graph/org_roam_parser.dart`, not by walking `org_parser`'s
    syntax tree. This differs from decision 15 for the graph only: matching
    org-roam's counts is the goal, and org-roam's rules are partly its own,
    not Org's syntax tree. It finds headings and properties by regular
    expressions, searches the whole buffer for links and then excludes some
    places, and reads `ROAM_REFS` and `ROAM_ALIASES` with Emacs's string
    splitting. `org_parser` and `org_flutter` stay the plan for rendering a
    node (#8). The rules are checked against real org-roam:
    `tool/org_roam_parity/build-fixture-expectations.sh` builds an
    `org-roam.db` from the sample files in `test/fixtures/roam/` with
    org-roam itself, a test and a CI job compare the parser with it, and
    `tool/org_roam_parity.py check` does the same with my real notes on the
    laptop. Some rules this found:
    - Only comment lines may come before a file's property drawer. One
      blank line, or `#+title:` first, and the file is not a node.
    - A file without `#+title:` gets an empty title in org-roam (its
      `string-join` of nothing is `""`, not the file name). The app shows
      the file name instead but stores the empty title.
    - A plain `id:…` in text is a link, like `[[id:…]]`. Links in code,
      verbatim, comments, and source, example, export and comment blocks are
      not. Links in `#+title:`, other keywords and property values are,
      except `ROAM_REFS` and `#+transclude:`.
    - A link belongs to the nearest node above it. A link under a top-level
      heading that is not a node goes to the file node; if the file starts
      with a heading, to that first heading.

21. **Two settings of my Emacs are assumed** (#4), since they change what
    org-roam stores: Doom Emacs's default TODO keywords (`PROJ`, `WAIT`,
    `[ ]`, …), which decide where a heading's title starts, and the link
    types registered when org-roam is loaded, which decide which plain
    links and `ROAM_REFS` count (`cite:key` does not; `@key` does). Both are
    parameters of the parser. If my Emacs differs, the laptop comparison
    shows it.

22. **`roam/daily/` is not part of the graph** (#4). It is a symlink to the
    journal folder (`../journal/`), so the dailies are the journal, which
    decision 4 leaves out. My Emacs config excludes it with
    `org-roam-file-exclude-regexp` (`"^daily/"`, relative to `roam/`), and
    the app applies the same pattern (`roamExcludePatterns` in
    `lib/folder/org_files.dart`). If the Emacs setting changes, change the
    app with it; the laptop check (`tool/org_roam_parity.py check`) shows a
    mismatch as files only one side has.

23. **The app stores the graph in an SQLite database with org-roam's schema**
    (#5): the same tables and columns (`files`, `nodes`, `aliases`,
    `citations`, `refs`, `tags`, `links`), the same `user_version` (20), and
    the same values, written the way emacsql writes them (Emacs Lisp
    strings in quotes, lists, property lists). So the org-roam MCP server's
    queries work on the phone's database unchanged. Details:
    - Paths are stored as on the laptop, starting with
      `/home/cgeng_local/work/cgeng/org/roam/`, so queries and results match
      the laptop's database.
    - The database is `org-roam.db` in the app's support folder, not in the
      Syncthing folder, so the app never writes into my notes.
    - Only new and changed files are read: first by modification time, then
      by content hash (SHA-1, as org-roam). A file without a modification
      time is always read. A file that disappeared is removed. "Rebuild
      index" reads every file again and replaces the index in one
      transaction, so a failed rebuild keeps the old one, and a file it
      cannot read keeps its stored rows; choosing another folder replaces
      the index too. The folder the index holds is kept in
      `org-roam.db.folder`, removed before such a change and written after
      it commits, so an interrupted change leads to a full rebuild. The app updates the index when it comes back
      to the foreground. Index updates run one at a time, in order.
    - `files.atime` holds the modification time: Android's folder access
      gives no access time.
    - The parser fills every column, not only what the graph needs: `pos`,
      `level`, `todo`, `priority`, `scheduled`, `deadline`, `olp`, the
      `properties` list org-roam stores, all link types with their
      properties, and citations. CI compares every table with the database
      real org-roam builds from `test/fixtures/roam/`, and
      `tool/org_roam_parity.py check-db` does the same with my notes.
    - A node ID used twice keeps the first node, as in org-roam. The app
      reports it only while it reads the second file; after that the
      database has only one of them.

24. **The graph view is drawn by Flutter itself, not by Cytoscape.js in a
    WebView** (#6). This changes decision 15 for the graph view. Reasons:
    - The graph already exists in Dart (#4, #5). A WebView would need it
      as JSON, and taps would come back over a channel.
    - The app works offline, so Cytoscape.js would have to be bundled
      into the APK.
    - Cytoscape.js has no `circo` layout.
    - Widget tests can drive Flutter's drawing and taps, but not a
      WebView.

    Whether the algorithms of #7 also run in Dart is decided in #7.

    How it is built:
    - A `CustomPainter` inside an `InteractiveViewer` (pan and pinch-zoom).
      All edges are one path. Labels are drawn only for nodes on screen,
      and only from scale 0.45, where they become readable. The layouts
      run on another isolate. On the laptop, for 500 nodes and 2469
      edges, the force-directed layout takes 0.25 s and circo 10 ms.
    - What is drawn is what `org-roam-graph` writes into its Graphviz
      file (`lib/graph/graph_scope.dart`):
      - One edge per pair of nodes with an `id:` link.
      - The whole graph also shows the nodes without links.
      - The target of a link to a missing ID is a node labelled
        `id:<target>`.
      - Titles wider than 100 columns are cut to 97 columns plus `...`
        (`org-roam-graph-max-title-length`), counted as Emacs counts
        them: a CJK character takes two columns, and `"` and `\` two as
        well, because org-roam escapes them first. The widths come from
        Emacs's `char-width` (`tool/char_width.el` writes
        `lib/graph/char_width.dart`).
    - "Neighbourhood: N steps" is `C-u N M-x org-roam-graph`, and
      "Connected part" is `C-u M-x org-roam-graph`. org-roam's query for
      N steps keeps the nodes up to N - 1 links away, plus every edge
      that touches them. So the nodes N links away are shown, but not the
      edges between them. A test runs org-roam's SQL from
      `org-roam-graph--connected-component` on the sample files and on a
      random graph, and compares it with the app for every node and N.
      Two deliberate differences:
      - The app follows only `id:` links. org-roam's query follows links
        of every type, so two notes that link the same web page count as
        neighbours. With my hidden link types, the page is not drawn, and
        such a note would appear without any visible connection.
      - The centre node is always drawn. org-roam draws only the ends of
        edges, so a node without links gives an empty graph.
    - **My Emacs draws the graph with `dot`, not `circo`.** My config
      sets `org-roam-graph-layout "circo"`. org-roam has no such
      variable: its source (`org-roam-graph.el`) never reads it, and the
      word `circo` does not occur in it. `org-roam-graph` runs
      `org-roam-graph-executable`, which defaults to `dot`. To get circo
      in Emacs: `(setq org-roam-graph-executable "circo")`.
    - The app's circo follows the idea of Graphviz's `circo`:
      - Each part of the graph that stays connected after removing any
        one node (a biconnected block) lies on its own circle.
      - Blocks hang outside the block they share a node with.
      - A part that is a tree is drawn around its node with the most
        blocks.
      - Separate parts are packed in rows.

      The order on a circle is the order of a depth-first search;
      Graphviz also reorders nodes to reduce crossings. So positions
      differ from Graphviz's.
    - The force-directed layout is Fruchterman and Reingold's, with a
      weak pull to the centre so that unlinked nodes stay near the rest.
      It starts from fixed random positions, so a graph always gets the
      same drawing.
    - The graph starts centred on the node opened last, which is stored in
      `last-node` next to the database. Without one, it starts on the node
      with the most links. A tap on a node opens it. Until the node view
      (#8) exists, opening shows a short summary with a button for its
      neighbourhood.
    - The graph opens from "Show graph" on the screen with the counts. The
      tablet and phone layouts (#16) will change where it lives. An open
      graph follows the index: when the app comes back to the foreground
      and the scan finds changes, the graph is drawn again. When nothing
      it shows has changed, the view stays where it is.

25. **Material comes from the `material_ui` package**, not from
    `package:flutter/material.dart` (#8). Since Flutter 3.47, Material
    Design is also a separate package, `material_ui`, and `org_flutter`
    (Orgro's renderer, decision 6) uses it. The two libraries are separate
    copies whose widgets do not see each other:
    - Org text inside a Flutter `Scaffold` found no `Material` and failed.
    - Org text would not follow the app's theme or dark mode.

    So every file imports `package:material_ui/material_ui.dart`, and there
    is one Material library in the app.

26. **The node view** (#8), `lib/node_view/node_screen.dart`:
    - **What it shows:** `org_flutter` renders the node as Org.
      - A file node shows its whole file.
      - A heading node shows its heading and subtree. `org_parser` finds
        the heading by its `:ID:`. A test renders every node of the
        sample files and checks that it finds every heading node.
      - Headings start unfolded; property drawers start folded, as in
        `org_flutter`.
    - **Reading the file:** the node view reads the file through the
      folder access (#3) when it opens. It reads it again when the index
      changes.
    - **`id:` links:**
      - A tap opens the linked node on a new page, so Back returns. This
        includes a link to a heading in the same text, which `org_flutter`
        reports as a section.
      - A link to a missing ID says so.
      - Other link types are not opened, and a message says so. Opening
        web links could come later.
    - **Backlinks:** listed below the text, as `org-roam-backlinks-section`
      lists them by default:
      - One entry for each `id:` link, not one for each node.
      - Sorted by the linking node's title, keeping the order of links
        from nodes with the same title.
      - Each entry shows the title and, below it, where the link is: the
        headings around it joined by ` > `, with links shown by their
        description (`org-link-display-format`), or `Top`.
      - A tap opens the linking node.
      - org-roam also shows the text around each link. The app leaves
        that out: it would read every linking file each time a node
        opens.
    - **"Show in graph":** returns to the graph, centred on the node. A
      part of the graph around another node is drawn again around this
      one.
    - **Starting the graph:** opening a node remembers it, so the graph
      starts there next time.

## Recommended, not decided

Nothing at the moment.

### Flutter or PWA

This comparison is from 2026-10-11, when the graph was planned in a WebView
with Cytoscape.js. Since decision 24, Flutter draws the graph itself; the
reasons for Flutter below still hold.

A PWA was also suggested. Two common objections to it do not hold:

- **Graph size is not a reason against a PWA.** 452 nodes and 2519 edges
  are small for browser graph libraries (Cytoscape.js, Sigma.js with WebGL),
  and the Flutter design runs the graph in a WebView, i.e. the same browser
  engine.
- **Folder access is not a reason either.** Chrome for Android supports
  `showDirectoryPicker` since version 132 (MDN `browser-compat-data`,
  `api/Window.json`), so a PWA can read the Syncthing folder.

The real differences:

| | PWA | Flutter (APK) |
|---|---|---|
| Graph and algorithms | Cytoscape.js or Sigma.js and `graphology` directly in the page | the same libraries, inside a WebView |
| Org parser and renderer | `uniorg` (JS), new to my files | `org_parser` and `org_flutter`, Orgro's own, already proven on my files |
| "Open in Orgro" | hard: a web page cannot hand a local file to another app; the share menu reaches only Orgro's capture | `ACTION_VIEW`, which Orgro accepts (see 6) |
| Folder access | Chrome 132+; unverified whether the permission survives a restart on Android | Android's folder permission is kept permanently |
| AI input via the share menu (#15) | possible (Web Share Target) | possible |
| Distribution | GitHub Pages; no APK, no signing key | APK from GitHub Actions, installed with Obtainium |
| Also runs on the laptop | yes, in the browser | no |

So the Orgro research decides it, not performance: "Open in Orgro" and the
parser Orgro has proven on my files favour Flutter. The PWA's strengths
matter less here, because the laptop has Emacs.

## Open

- **MCP on the device** (#14). Adding nodes needs no MCP (see 11). MCP would
  only matter if an AI on the device had to read or query the graph without
  the laptop, and it needs a client there. The Claude Android app only
  connects to remote MCP servers. Possibly never needed.

## My data, for checks

From the laptop `org-roam.db`, `roam/` only, on 2026-10-11:

| What | Count |
|---|---|
| `.org` files in `roam/` | 485 |
| Files in the database | 457 |
| Nodes | 452 (451 files, 1 heading) |
| `id:` links | 2519 |
| Tags | 192 |
| Refs | 125 |
| Aliases | 2 |
