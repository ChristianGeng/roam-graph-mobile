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
      - A link to a heading in the same text by its title or custom ID
        (`[[*Heading]]`, `[[#custom-id]]`) opens the heading if it is a
        node. Another heading cannot be shown alone, and a message says
        so.
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

27. **Search works like `org-roam-node-find` with my Doom Emacs** (#9),
    `lib/graph/node_search.dart`:
    - **Candidates:** each node's title, and each alias as a candidate of
      its own, as `org-roam-node-list` makes them. A node can be found
      twice, by its title and by an alias; the alias says whose it is. A
      node without a title is found by its file name, which the app shows
      for it; org-roam's title for it is empty.
    - **Matching:** the words typed, separated by spaces, must each occur
      in the candidate, anywhere, in any order, ignoring case. This is how
      Doom's completion (`vertico` with `orderless`) matches literal
      words. Orderless also reads a word as a regular expression; the app
      does not.
    - **Case:** the app always ignores case, as #9 asks. This differs from
      Emacs on purpose: orderless's `orderless-smart-case` (on by default,
      and Doom keeps it) matches case-sensitively as soon as any word
      contains a capital letter. Android keyboards capitalize the first
      letter typed, so smart case would make the first word fail.
    - **Order:** the newest file first, as `org-roam-node-default-sort`
      (`file-mtime`). Candidates from files with the same time keep their
      order: path order, a title before its aliases. For this the graph
      now carries each file's modification time, which the database
      already stored (`files.mtime`).
    - **Tags:** chips for every tag, the most used first. A node must have
      every selected tag. In Emacs, tags are part of the text that
      completion matches; the app keeps them apart, as #9 asks.
    - **Actions:** a result opens the node view (#8); Enter opens the
      first result. A second button shows the node in the graph (#6).
      Both remember the node, so the graph starts there next time.
    - **Where:** a search button in the graph view and in the node view.

28. **"Open in Orgro" hands Orgro the file, read-only** (#10). A button in
    the node view sends the node's file to Orgro with Android's
    `ACTION_VIEW`.
    - **Which file:** the file's document URI from the folder access (#3).
      Orgro accepts `content:` URIs of any type (its `AndroidManifest.xml`).
    - **Only Orgro:** the intent names Orgro's application ID,
      `com.madlonkay.orgro` (its `build.gradle`), so Android does not ask
      which app to use. If Orgro is not installed, the app says so.
    - **Headings:** a heading node opens its file at the top, and the app
      says so. Orgro has no external way to jump to a heading
      (decision 6).
    - **Read-only:** Orgro gets read access to the file only. The app holds
      only read access to the folder (decisions 9 and 19), and it can pass
      on no more than it holds. So Orgro can show and fold the file but not
      save changes to it. The intent grants read access only, even if the
      app should ever hold more. Editing in Orgro from here would need the
      app to ask for write access to the folder; that belongs with v2
      capture, as decided with the owner on 2026-10-15.

29. **Two panes on a tablet in landscape, one screen at a time otherwise**
    (#16), as decision 12 planned:
    - **When:** two panes when the screen's shortest side is at least 600
      (Material's medium width, so a tablet) and it is wider than high.
      A phone held sideways is wide, but its shortest side is about 400,
      so it keeps one screen at a time, as #16 asks.
    - **Two panes:** the graph on the left (3/5 of the width), the node
      view on the right (2/5). The node view starts with the graph's
      centre node.
      - There is one selected node: the graph marks it, and the right
        pane always shows it. A tap in the graph, a link, a backlink, a
        search result and "Show in graph" all select a node; the view
        does not move.
      - The pane's Back goes through the nodes selected before. A node
        deleted from the notes leaves that history.
      - A node outside the part of the graph drawn around another node
        gets that part drawn around it.
      - "Show in graph" centres the graph on the pane's node.
    - **One screen at a time:** as before, a tap opens the node view on a
      new page, and "Show in graph" returns. A button in the graph's bar,
      "Open node", is the quick switch to the node view of the graph's
      centre node.
    - **Search** stays in both bars.
    - **Turning the device** switches the layout. The graph is centred
      again whenever its part of the screen changes width; not when only
      its height changes, as when the keyboard of the search opens. A node
      page already open stays open, and a search open while turning opens
      its result the way the new layout does.

30. **Graph views compute what my MCP server computes** (#7),
    `lib/graph/graph_algorithms.dart`, as decision 8 planned. The server
    (`cgeng-ai-skills`, `mcps/org_roam`) is the reference. It builds a
    directed graph with every node and one edge for each pair of nodes
    with an `id:` link; a link to a missing ID adds a bare node. The app
    builds the same graph. The "View" menu of the graph offers:
    - **Communities:** coloured by Louvain communities, as the server's
      `best_partition` from python-louvain finds them on the undirected
      graph. The app ports that algorithm. Louvain visits nodes in a random
      order and the server uses no seed, so its own communities differ a
      little between runs. The app uses a fixed seed, so the colours stay.
      The ten largest communities get colours; the others stay plain.
    - **Importance:** node size by PageRank (networkx's `pagerank`, with
      its defaults), or by number of links (org_roam_central: the distinct
      nodes a node links to plus those linking to it). The area grows
      with the value.
    - **Shortest path:** from the selected node to a tapped one, following
      links in their direction, at most 8 links, as org_roam_shortest_path.
      In this view a tap chooses the target instead of opening the node.
      When a path passes through nodes outside the part of the graph that
      is drawn, the note under the bar says so and suggests the whole
      graph.
    - **Drawing:** Louvain, PageRank and the link counts run on another
      isolate, once per index update; until they arrive the view says
      "Computing…". Enlarged dots keep arrow heads at their edge and open
      on their whole area. The selected node keeps its community colour
      and gets a ring.
    - **Neighbourhood** stays as #6 built it, as `org-roam-graph` draws it
      (links in both directions). The server's org_roam_bfs follows links
      out of a node only. The graph view keeps org-roam's, which is what
      the drawing imitates.
    - **The check:** `tool/graph_algorithms.py` runs the server's
      libraries (networkx 3.6.1, python-louvain 0.16) on the sample files'
      org-roam database and on a random graph of 300 nodes, and writes
      `test/fixtures/graph_algorithms_expected.json`. The tests require:
      - the same PageRank (to 1e-9), link counts and path lengths;
      - the same modularity for python-louvain's own partition;
      - Louvain communities as good as the worst of 20 python-louvain
        runs, with a similar number of communities.

31. **New nodes are written as org-roam's default capture writes them**
    (#11), `lib/capture/`:
    - **Write access:** the folder picker now asks for read and write
      access (decision 19 took read only, for v1). A folder chosen before
      v2 keeps read access only; capture then asks to choose the folder
      again. Browsing works either way.
    - **File name:** `roam/<%Y%m%d%H%M%S>-<slug>.org`, the default
      `org-roam-capture-templates` target, which my config does not
      change. The slug is `org-roam-node-slugify`:
      - Remove the accents: Unicode decomposition (`unorm_dart`), drop 21
        combining marks, compose again.
      - Turn everything that is not a letter or a decimal digit (Emacs's
        `[:alnum:]`) into `_`.
      - Remove `_` at the ends and repeated `_`, then use lower case.

      `tool/org_roam_parity/slugs.el` runs the real function in Emacs on
      30 titles (accents, CJK, Greek, `ß`, `İ`, `²`, ligatures, emoji),
      and a test requires the same slugs.
    - **ID:** a random UUID in lower case, as `org-id-new` makes it with
      `org-id-method` `uuid` (`uuidgen`).
    - **Text:** `:PROPERTIES:` / `:ID:       <id>` / `:END:`, then
      `#+title:` (the template's head), then `#+filetags: :a:b:` as
      `org-roam-tag-add` writes it, then the text. Tags are separated by
      spaces, commas or colons, which Org tags cannot contain.
    - **Writing:** the file is never written in place:
      - The app writes it as `.syncthing.<name>.tmp`, the name Syncthing
        gives its own temporary files. Syncthing's scanner skips these, so
        a half-written file is never synced.
      - Then it renames the file into place.
      - A name that exists already is never replaced: the capture says so,
        and saving a second later gives a new name.
    - **Indexing:** the folder is indexed right after writing, so the new
      node is in the graph at once, and the capture opens it. The laptop
      picks it up with `org-roam-db-sync` after Syncthing has synced. If
      that indexing fails, the capture says the file is saved and offers
      no second save, which would write a second file.
    - **Where:** a "New node" button on the graph. The graph opens also
      for a folder without nodes, so the first node can be made.

32. **A captured node links to the node it came from, in its own file**
    (#12), as decision 10 planned:
    - The link goes into the **new** file only, as the first line after
      the header: `[[id:<id>][<title>]]`. The node it came from then
      shows the new node as a backlink, in org-roam and in the app. Its
      file is never changed: the laptop may be editing it, and Syncthing
      would make a conflict copy.
    - The link is written as Org's `org-link-make-string` writes it:
      - The target is escaped as `org-link-escape` does, so an ID with `[`
        or `]` still gives a backlink.
      - The description gets zero-width spaces after a final `]` and in
        each `]]`, so a title like `Draft [2]` cannot end the link early.

      The tests use the values Emacs 31 returns.
    - Both "New node from here" in the node view and "New node" in the
      graph link to the current node, the selected one in the graph, by
      default, as decision 10 says. The link can be switched off before
      saving.

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
