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
   the queries of my org-roam MCP server
   ([org-roam-mcp](https://github.com/ChristianGeng/org-roam-mcp), until
   2026-10 `mcps/org_roam` in `cgeng-ai-skills`) work on the app's
   database unchanged.

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

10. **Existing notes are edited only under five rules** (#34, agreed on
    2026-10-17). Until v4 the app wrote only new files (v2 capture): a new
    node links to the current node from inside the new file, so it shows
    up as a backlink, and file names follow my capture template, which is
    org-roam's default: `roam/<%Y%m%d%H%M%S>-<slug>.org`. v4 lets the app
    change existing notes, also with an AI, while the laptop edits the same
    graph with Emacs and the org-roam MCP server. So:
    1. **Only what was shown is replaced.** The app saves an edit only if
       the file is still the version it read: the same content hash,
       checked just before writing. Otherwise it refuses and shows the
       newer version (#35).
    2. **Whole files, written safely.** An edit writes the new text to a
       temporary file under a name Syncthing does not sync, as capture
       does (decision 31), and then puts it in place of the old file, so
       Syncthing never sees half a file. Unlike a capture, an edit's
       rename replaces the existing name; a capture's rename still refuses
       to.
    3. **Nothing is lost.** Before replacing a file, the app keeps the old
       version in its own storage, and a wrong edit can be undone from
       there (#35).
    4. **The laptop stays the reference.** Syncthing's conflict copies are
       listed (decision 33) and resolved in Emacs; the app does not merge
       them.
    5. **Text only.** A file node's whole text, or a heading node's
       subtree, can be edited. The `:ID:` and the property drawer stay as
       they are. Editing tags, the title or aliases (`ROAM_ALIASES`) is
       left for later, since the index must follow such changes.

    Rules 1, 2, 3 and 5 do not depend on Syncthing; rule 4 is Syncthing's.
    The writing is kept behind an interface, so that notes could later
    reach the device through git instead: rule 4 would then become "pull
    before an edit, push after; if the push is refused, pull, merge, and
    show a conflict when the same lines changed", and git's history would
    cover rule 3. For now Syncthing stays the transport, and git runs only
    on the laptop.

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
    - Code `~…~` and verbatim `=…=` may span line breaks up to the end of
      their paragraph, as in Org 9.7: a blank line, or a line that starts
      another element (heading, list item, table, keyword, fixed width,
      comment, drawer, rule). They also end where an enclosing bold or
      italic ends (`*a =x=* b`). The laptop check found such a code span
      hiding a link in my notes.
    - `[fn:label]` is a footnote, not an `fn:` link, also where `fn` is a
      link type (Doom registers one). Links inside an inline footnote
      count.
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
    - **The link types are my Doom Emacs's** (`myEmacsLinkTypes`, read
      from `org-link-parameters` on 2026-10-16). The laptop check found
      that they differ from a plain Emacs's: Doom adds `org`, `doom`,
      `kbd`, `fn` and others, and leaves out `eww`, `info`, `doi` and
      others. So `#+filetags: :org:setup:` holds a plain `org:` link in
      org-roam on the laptop, and in the app.
    - The sample files' expected database was built by a plain Emacs, so
      the tests and CI's comparisons on them use the plain list
      (`plainOrgRoamLinkTypes`, the tools' `--plain-org-roam`).
    - With both changes, `tool/org_roam_parity.py check-db` finds no
      differences on my notes (2026-10-16: 461 files, 456 nodes, 5757
      links, every table and column).

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
    - An index made by another parser is rebuilt once: the folder marker
      also holds the parser's version and link types
      (`parserFingerprint`), and a different one counts as no index. So an
      update that changes how notes are read reaches unchanged notes too.
      `tool/build_roam_db.dart` keeps the same in `OUT.db.parser`.
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
    ([org-roam-mcp](https://github.com/ChristianGeng/org-roam-mcp),
    `src/org_roam_mcp`) is the reference. It builds a
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
      - A name that exists already is never replaced by a capture: the
        capture says so, and saving a second later gives a new name. Only
        an edit of an existing note replaces a file, under decision 10.
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
      shows the new node as a backlink, in org-roam and in the app. A
      capture never changes its file: the laptop may be editing it, and
      Syncthing would make a conflict copy. Edits of existing notes follow
      decision 10.
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

33. **Writing next to Syncthing is safe, and conflicts are shown** (#13):
    - **No partial files, no overwriting:** a new file is written under
      Syncthing's own temporary name and renamed into place, and a capture
      never replaces an existing name (decision 31) or writes into an
      existing file (decision 32). Edits of existing notes follow decision
      10.
    - **Conflict copies:** Syncthing names them
      `<name>.sync-conflict-<date>-<time>-<device>.<ext>`. They were
      already left out of the graph (#4); now the counts screen counts
      and lists every one in the chosen folder, outside Syncthing's own
      folders, so they can be resolved in Emacs. The list has every name,
      and it is shown also when the folder has no `roam/` yet.
      - The counts screen is the first screen on start, so copies found
        by the first scan are shown there.
      - A copy that appears later, for example when the app comes back
        to the foreground while the graph is open, is also reported in a
        message on top of the graph. "Later" means not seen by the last
        scan of that folder, compared by path, so a new copy is reported
        also when another one was resolved meanwhile.
    - **The check:** a test captures five nodes in quick succession. It
      requires five distinct files, each written once, none overwritten,
      all indexed, and no conflict copies or temporary files left. The
      writing itself (temporary name, rename, name check) is Android code
      (`FolderAccess.kt`) that the tests do not run. Checking it is the
      owner's task on the device, against the laptop.

34. **Shared text becomes a new node** (#15), as decision 11 planned:
    - **Share target:** the app is in Android's share menu for plain text
      (`ACTION_SEND`, `text/plain`).
      - `MainActivity.kt` keeps shared texts in a queue, oldest first,
        until the app takes them one at a time through the channel
        `roam_graph/share`.
      - The queue is kept in the activity's saved state, so a share is
        not lost when Android recreates the activity before the app took
        it.
      - A share that starts the app waits until the folder is indexed.
      - Shares that come during a capture open one after another when it
        closes.
    - **Capture:** the share opens the capture screen of #11.
      - The title is the share's subject if the sending app gives one.
        Otherwise it is the first line that is not empty, without the `#`
        of a Markdown heading and without `**` bold marks, in pairs, since
        AI apps share Markdown: `**Summary:** the points` gives
        `Summary: the points`.
      - The text is the rest, so the title is not repeated in it.
      - Both can be edited before saving, and tags added.
      - The text is stored as it came; it is not converted from Markdown
        to Org.
    - **Link:** a link to the node viewed last is offered (#12), off by
      default: a shared text is often about something else.
    - **Writing:** as #11 and #13: `<timestamp>-<slug>.org`, a new
      `:ID:`, written safely next to Syncthing. The new node opens after
      saving.

35. **The graph's connectivity can be shared with an AI** (#40). The Claude
    Android app cannot read device folders and runs no local MCP server
    (#14), but it reads text shared to it. "Share graph with AI" in the
    graph view sends, through Android's share menu, the structure of the
    whole graph (`lib/graph/ai_share.dart`):
    - Every node: a short number (`n1`, `n2`, …, in title order), its ID,
      its tags (`-` for none) and its title, in that order: the title comes
      last, so a ` | ` in it cannot look like another column. Then every
      pair of nodes with an `id:` link, as
      `n3 -> n17`. The numbers keep the 2589 links from repeating 36-letter
      IDs; for my notes the text is about 57 KB, some 14,000 tokens.
    - No note texts: all of them are 3.4 MB, some 850,000 tokens, too much
      for one chat. A node's text is shared on request (#41).
    - A header says what it is and how to answer: link to a node with
      `[[id:<ID>][<title>]]`, put a new note's title on its first line, and
      ask for a node's text by title. An answer shared back to the app
      becomes a linked new node (#15).
    - Built from the app's index, so it is the graph org-roam has (#5).
      Links to IDs that are no node are left out. Nothing is written.
    - The action is in the graph's "More" menu, with Centre and the
      layouts, so the bar fits a phone. A share Android refuses says so; a
      text over 400 KB is not sent, since Android hands shared text over in
      one transaction of about 1 MB.

36. **Nodes can be shared with an AI, with their texts** (#41): the reading
    half of decision 35. When an AI asks to see notes, I pass them on.
    - "Share with AI" in the node view shares the node; in search, a long
      press selects nodes (a tap then adds or removes one), and "Share with
      AI" shares the selection together.
    - Each node comes with its ID, file, tags, the nodes it links to and
      those linking to it (as `[[id:<ID>][<title>]]`), and its Org text:
      the whole file for a file node, the heading and its subtree for a
      heading node. The heading is found by its `:ID:` in the file as it is
      now, with org_parser, as the node view finds it; if the file no longer
      has it, the share says so instead of sending what is now at the
      indexed line. Links are written as `orgLink` writes them (#12), and
      the text is fenced with more backticks than it contains. A header
      asks the AI to link with the same `[[id:…]]` form.
    - Over 400 KB is not sent (Android's limit for shared text is about
      1 MB); the app asks to select fewer. A share Android refuses says
      so.
    - Shared through Android's share menu, as text; nothing is written.
    - So an AI on the device reads on demand with me as the messenger. An
      AI that fetches notes itself would need a remote MCP server (#42).

37. **Source blocks are coloured as Emacs colours them** (#45),
    `lib/node_view/src_languages.dart`. `org_flutter` already highlights
    source blocks (with the `highlighting` package, a port of
    highlight.js, and Emacs-like colours for light and dark), but only when
    the block's language is a highlight.js name. So the app maps each
    block's language first, the way Emacs picks a mode:
    - The language gives Emacs's mode through `org-src-lang-modes` (copied
      from Org 9.7.39), or the mode of its own name, as
      `org-src-get-lang-mode` does: `sh`, `shell`, `bash` and `zsh` give
      `sh-mode`, `elisp` gives `emacs-lisp-mode`, `toml` gives
      `conf-toml-mode`.
    - The mode gives highlight.js's name: `sh` is `bash`, `emacs-lisp` is
      `lisp`, `conf` and `conf-toml` are `ini`, `js` is `javascript`,
      `c++` is `cpp`; other modes keep their name (`python`, `json`).
    - A language without a highlight.js grammar stays plain, as in Emacs
      without its mode: `mermaid`, `text`, and `config` (Emacs has no
      `config-mode`). Names are compared as written, as in Emacs, so
      `Python` stays plain too (Emacs has no `Python-mode`). Where the
      renderer would still colour such a block by its own name, it gets no
      language; other plain blocks keep theirs (`mermaid`).
    - Only the language the renderer uses changes; the block's header line
      is shown as written.
    - The colours follow the app's light or dark mode, through
      `material_ui`'s theme (decision 25).

38. **Images from the notes folder are shown as Org shows them** (#46),
    `lib/node_view/note_images.dart`. `org_flutter` decides which links
    are images (a location ending in an image extension, no description)
    and asks the app for the widget (`loadImage`). The app:
    - **Finds the file as Org does.** Only file links: `file:./img/a.png`,
      `./img/a.png`, `file:img/a.png`, `../include/a.png` (read with
      `org_parser`'s `OrgFileLink`). The path is relative to the
      directory of the note's file; `.` and `..` are resolved.
    - **Reads it through the folder access**, by content URI (decisions 19
      and 31). The folder screen keeps every listed file of the chosen
      folder, not only the notes, so an image beside `roam/` (the org
      root's `include/`) is found when the org root is chosen.
    - **Shows as links** what it cannot or must not read: absolute and
      `~/` paths and paths above the chosen folder (Android gives no
      access there), web images (the app is offline, decisions 2 and 14),
      `attachment:` and `data:` links, and AVIF (Flutter has no decoder
      for it on Android). SVG is shown since #47 (decision 39).
    - **A missing or unreadable image** shows the link with a
      broken-image icon, whose tooltip says which; the page still shows.
    - **Width, as Org 9.7.39 gives it with my settings**
      (`org-image-actual-width` nil; `org-display-inline-image--width`,
      checked in Emacs): the `:width` of the paragraph's `#+ATTR_ORG:`
      lines; if they have no readable one, the first other `#+ATTR_...:`
      line that has one. Only keyword lines right above the paragraph
      count; a blank line between ends them, as in Org. `300px` and `300`
      are 300 logical pixels; `50%`, `0.5` and other decimals from 0 to 2
      are that part of the text width; `t`, a decimal such as `300.0`, or
      no readable width is the image's own width (one image pixel per
      logical pixel).
    - **Never wider than the text column**, keeping the aspect ratio. This
      differs from Emacs, which with these settings does not narrow an
      image (`org-image-max-width` only applies with
      `org-image-actual-width` t). `:align` is applied by `org_flutter`.
    - **Memory:** the image is decoded no wider than shown, at most the
      screen width in device pixels (a `:width` fraction of it), and never
      enlarged. The zoom page decodes up to four times the screen's long
      side, at most 4096 pixels. The image cache is keyed by the file's
      URI, modification time and that width, so a changed image is read
      again when the index changes (decision 26); a file whose folder
      gives no modification time is read again after each scan. An image
      that could not be read is tried again the next time.
    - **Tap** opens the image on its own page with pinch zoom; Back
      returns to the node.

39. **SVG images are drawn with `flutter_svg`** (#47), in
    `lib/node_view/note_images.dart`, found and read as other images
    (decision 38).
    - `flutter_svg` (the Flutter team's package) draws an SVG with Flutter,
      without a WebView. Its limits: CSS is not fully supported,
      `<foreignObject>`, scripts and animation are not drawn, and text uses
      the device's fonts.
    - **The app compiles the SVG itself**, with `vector_graphics_compiler`
      on another isolate, as `flutter_svg` does, and gives `SvgPicture` the
      compiled bytes. It does not use an `SvgLoader`: `vector_graphics`
      leaves a failed load as an uncaught error. Compiled SVGs are kept by
      URI and file version (32 at most), so a note shown again does not
      parse them again, and a changed file is compiled again.
    - **Size as in decision 38:** the `#+ATTR_ORG:` width, else the SVG's
      own (its `width` attribute or `viewBox`), never wider than the text
      column, in proportion.
    - **An SVG that cannot be read or parsed** shows the link with a
      broken-image icon.
    - **Dark mode:** an SVG is drawn on a white background. Many SVGs have
      a transparent background and black lines, which cannot be read on a
      dark page. Emacs shows them on the buffer's background, which is
      light on the laptop.
    - **Tap** opens it on its own page with zoom; an SVG stays sharp at any
      zoom.

40. **LaTeX is rendered by `org_flutter`, display formulas in display
    mode** (#50), `lib/node_view/latex.dart`. `org_flutter` renders LaTeX
    fragments and environments with `flutter_tex_js`, which runs KaTeX
    (bundled, so offline) in a hidden WebView and returns an image.
    - **Display formulas.** In Org, `\[ ... \]` and `$$ ... $$` are display
      formulas. `org_parser` reads them as inline fragments, which
      `org_flutter` renders in text mode (smaller, in the line). The app
      turns each into a LaTeX block after parsing, which `org_flutter`
      renders in display mode: in display style (larger sums, integrals
      and fractions), on its own line, at its start. It is not centred:
      Emacs shows a preview image at the formula's place, and Org 9.7.39
      has no option to centre previews (`org-format-latex-options` has no
      `:justify`). `\( ... \)` and
      `$ ... $` stay inline; `\begin{equation}` and other environments were
      already blocks.
    - **Colour:** a formula takes the text colour, so it is light on a dark
      page (checked in a test).
    - **A formula KaTeX cannot render** shows its source, with its
      delimiters.
    - **Not done: the system font size.** `org_flutter` gives KaTeX the
      text style's font size without the system's text scaling, so with a
      larger system font, formulas stay at the normal size. The app cannot
      change this from outside; it needs a change in `org_flutter`, to be
      offered upstream if it matters on the device.
    - The sample note `test/fixtures/roam/20240112120000-mu.org` has an
      inline, a `\[ \]`, a `$$` and a broken formula and an `equation`
      environment. Widget tests cannot run the WebView; they check which
      widgets render the formulas, and with what (a mock of
      `flutter_tex_js`'s channel answers as KaTeX would).

41. **Mermaid: the result image first; blocks without one are drawn with
    `mermaid_flutter`** (#48, #49), `lib/node_view/mermaid.dart`. The owner
    accepted the recommendation in #48: option 0, then A.
    - **The result image first.** Emacs shows a mermaid block and below it
      the `#+RESULTS:` image that `mmdc` drew when the block was last run.
      The node view shows the same since #46. A block whose result
      paragraph links to an image the app shows is left as it is.
    - **Every other `mermaid` block is drawn on the device**, right below
      the block, where its result would be: a block never run, without
      `:file`, or whose image is not in the folder. The drawing is labelled
      "Drawn on the device", so it is not taken for the laptop's result.
      The language is compared as written, as Emacs runs only `mermaid`
      blocks with `ob-mermaid`. Org's comma escapes are removed first, as
      Org does before running a block.
    - **The check behind A.** `mermaid_flutter` 0.3.0 (MIT; `mermaid_core`
      parses and lays out in Dart, a `CustomPainter` draws, no WebView) was
      run on the 73 mermaid blocks in my notes (`roam/` without `daily/`),
      by a local script that is not in the repo (decision 14): 67
      flowcharts (`flowchart` or `graph`, one with front matter), 4
      sequence diagrams and 2 state diagrams; 14 start with
      `%%{init: ...}%%`.
      **All 73 were drawn without an error, in the light and the dark
      theme, all 14 `%%{init}%%` blocks among them.** Laid out at most
      0.17 s each on the laptop (median 0.02 s). The layout is close to
      `mmdc`'s, not the same: for 53 of the 73, the drawing's aspect ratio
      is within 25 % of the PNG's; the others place nodes differently, for
      example side by side inside a subgraph where mermaid.js stacks them.
      So B (mermaid.js in a hidden WebView, +2.6 MB) was not needed.
    - **Cost: APK size.** The APK grew from 67.9 MB (v0.1.90) to 79.2 MB,
      all of it compiled Dart code (`libapp.so`): `mermaid_core` brings
      parsers and layouts for 28 diagram types, ELK and a KaTeX port. That
      is 3.6 MB for each of the three CPU types in the one APK; a phone
      keeps only its own, so the installed app grows by about 3.6 MB, more
      than B's 2.6 MB. A was kept for drawing without a WebView, offline,
      on the UI's own text measurement; if the size matters, B is the
      alternative, or APKs split by CPU type.
    - **An image that is in the folder but cannot be read** (for example
      while Syncthing writes it) shows the broken-image link, as other
      images do (decision 38), and no drawing; the image is read again
      when the note is shown again. Emacs, too, shows only the result.
    - **Dark mode** uses mermaid's `dark` theme. A theme the block sets in
      `%%{init: ...}%%` comes first, as in mermaid; a light one is then
      drawn on a white background, as SVGs are (decision 39).
    - **Never wider than the text column**, scaled down in proportion; tap
      opens it on its own page with zoom, where it stays sharp.
    - **A diagram that cannot be drawn** shows one line with the error,
      below the block; the rest of the note is shown.
    - **Cached** by source and theme (32 at most), so scrolling and showing
      a note again do not lay it out again. Layout runs on the UI thread:
      `mermaid_flutter` measures text with Flutter's `TextPainter`.
    - **How it is placed.** `org_flutter` has no hook for source blocks, so
      after parsing, the app adds a paragraph with one image link after
      each block to draw; the node view's `loadImage` shows the drawing for
      exactly those links (kept by the link object, not by its text), so a
      link a note writes itself is never taken for one.
    - **Not done:** a button to switch between the result image and a
      drawing of the current source, to see whether the PNG is out of date.
      It can be added if it is wanted.

42. **Notes are hidden from AI by tag** (#57), `lib/ai/ai_visibility.dart`.
    Some notes are private. Before an AI reads note texts (the chat of
    milestone v6), the app has a rule for what it may not see.
    - **The setting:** "Hidden from AI", a list of tags, by default
      `private`, on the "AI settings" page (from the folder screen and the
      graph's "More" menu). It is kept in the app's support folder
      (`ai-settings.json`, written to a temporary file and renamed), not in
      the notes. An empty list hides nothing.
    - **The saved tags are loaded before anything is shared.** Until they
      are, a share waits, and the settings page shows no field, so it
      cannot save the defaults over saved tags. A change is saved first and
      used only once saved; if saving fails, the tags in use stay.
    - **Which nodes:** a node with one of the tags. These are the tags
      org-roam stores for the node, so a heading node also has its file's
      `#+filetags` and the tags of the headings above it. Tags are compared
      as written, as Org compares them. Of several nodes with one ID, the
      one the graph keeps (decision 20) decides.
    - **A hidden node does not exist for an AI.** The graph export (#40,
      decision 35) leaves it out with its links, and its header says how
      many nodes are hidden, so the AI knows the graph is not complete.
      "Share with AI" on a hidden node says that it is hidden, with its
      tag, and shares nothing. A selection in search leaves hidden nodes
      out and says how many.
    - **The file as it is now counts too.** Syncthing may have brought a
      new `#+filetags` or heading tag before the app indexed the file
      again. So a node whose file now hides it (its `#+filetags`, or the
      tags of its heading or a heading above it, found by its `:ID:`) is
      not shared either.
    - **Inside a visible note's text:** line ends become `\n`, as the
      index reads them. Each heading with a hidden tag of its own is
      replaced by `* (hidden)`, at its level, without its subtree, also
      when it is no node. A link to a hidden node keeps its ID, but its
      description becomes `(hidden)` and a search option after `::` (which
      can hold the title) is dropped. Links are read as Org reads them,
      escaped brackets included (`org-link-bracket-re`).
    - **The lists with a shared node** leave hidden nodes out, and "Links
      to" lists only links that are in the text shared, so not those under
      a hidden heading.
    - **Headings are found line by line:** a line that starts with stars
      and a space is a heading, also inside a block, as Org
      (`org-outline-regexp`), the index and the node view read it
      (decision 36). Tags are read at the end of the heading line, as
      Org's `org-tag-group-re` reads them.
    - **Not covered:** a link written under a hidden heading that is no
      node belongs to its file's node, as in org-roam. The graph export
      and the backlinks listed with another shared node still count it,
      as a link between two visible nodes; its text is hidden. Hiding it
      there needs the heading's tags for each link in the index.

43. **Notes open with their sections collapsed, as a setting** (#63),
    `lib/settings/view_settings.dart`, `lib/node_view/folding.dart`. Until
    now every section was open, as in my Emacs (`org-startup-folded` is
    `nil`); on a phone a long note was a long scroll. Orgro opens notes
    folded, and that reads better on the device.
    - **The setting** "Sections when a note opens" has the three values
      Org's `#+STARTUP:` has for folding: **Collapsed** (`overview`, only
      the top-level headings; **the default**), **Headings** (`content`,
      all headings without their text) and **Expanded** (`showall`,
      everything, as before). It is on a Settings page, reached from the
      graph view's "More" menu.
    - **A file's own `#+STARTUP:` comes first**, as in Emacs. `org_flutter`
      puts the caller's settings before the file's and reads the file's
      only when asked, so the app reads the folding word itself
      (`OrgSettings.fromDocument`) and uses the setting only where the
      file has none. None of my notes has `#+STARTUP:` today. Other
      `#+STARTUP:` words are still not applied, as before.
    - **The text before the first heading** (the title and the links at the
      top of a file node) is always shown, as in Org.
    - **A heading node** shows its own section open, its text and its
      subheadings, which start folded as the setting says. Folded, a
      heading node would show a single heading line.
    - **Tapping a heading** opens and closes it, as before. A changed
      setting applies to the note shown at once; the folding then starts
      again.
    - **How settings are kept.** A JSON file, `view-settings.json`, in the
      app's support folder, next to the database: read once at the start,
      written through a temporary file and a rename when a setting
      changes, defaults where the file is missing or cannot be read.
      Screens read it through `ViewSettingsScope`, given by
      `ViewSettingsHost` above the navigator; tests use
      `MemoryViewSettingsStore`. A new setting is a field in
      `ViewSettings` with a default, its JSON key, and a tile on the
      Settings page. The AI settings (#57) are kept the same way in their
      own file; the two can share the Settings page later. **Secrets, such
      as API keys, never go into these files**: they belong in Android's
      secure storage.

44. **AI tools on the app's index, as my org-roam MCP server has them**
    (#58), `lib/ai/ai_tools.dart` and `lib/graph/graph_measures.dart`. The
    chat of milestone v6 gives a model the tools of my org-roam MCP server
    ([org-roam-mcp](https://github.com/ChristianGeng/org-roam-mcp)), with
    its names, parameters, defaults and results, so an AI works with the
    graph on the phone as Claude Code does on the laptop. They run on the
    app's index, offline.
    - **The 16 tools:** `find`, `read_node`, `backlinks`, `bfs`,
      `shortest_path`, `common_neighbors`, `central`, `orphans`,
      `pagerank`, `communities`, `betweenness`, `closeness`,
      `clustering_coefficient`, `graph_stats`, `suggest_links` and
      `connected_components`, each `org_roam_` in front. Not `emacs_eval`
      and `org_roam_sync`: there is no Emacs on the device, and the index
      updates itself. Each has a JSON Schema for its parameters.
    - **The same results.** The query tools follow the server's SQL: what
      `LIKE` matches (`%` and `_` are wildcards, case is ignored only from
      A to Z), one backlink row per link, breadth-first distances in the
      links' direction, and `common_neighbors` as the server computes it:
      nodes that link to the same nodes as `node_a`, where `node_b` is only
      left out (its description says so). The other tools follow networkx
      3.6.1: PageRank (decision 30), betweenness (Brandes, normalized),
      closeness (by the distances to a node, with Wasserman and Faust's
      scaling), directed clustering, weakly connected components,
      statistics, and python-louvain's Louvain, now with its resolution.
      Titles sort as SQL's `ORDER BY title` sorts the stored, quoted titles
      (`"Beta heading"` before `"Beta"`); the graph the networkx tools use
      is built in that order too, as the server's query builds it, which
      also changes the order Louvain visits nodes in the graph views.
    - **Where the app differs, on purpose:**
      - Titles are given as written; the server gives them as stored, with
        Emacs Lisp escapes such as `\11` for a tab. Files are paths
        relative to `roam/`; the server gives absolute paths.
      - `shortest_path` lists each path once. The server's query follows
        each link row, so a note that links twice to the next one gives
        the same path twice, and its 3 rows can be one path. The app gives
        the 3 shortest different paths (Yen's algorithm, at most 8 links).
      - Of equally ranked rows, the server's order is its table's, SQLite's
        or Python's set order, which the app cannot know. The app keeps
        the order of the index (by path) for equal titles, takes the
        higher ID first for equal counts, and the hub of a component is
        the first by ID of those with the most links.
      - `read_node` gives at most 60,000 characters, and lists in the text
        at most 300 lines, each saying how many more there are: a chat on
        the phone pays for every token. Line ends are `\n`, as Python's
        `read_text` gives them to the server.
        Communities and components name at most 300 nodes in all, and
        count the rest.
      - An ID may be given with quotes or `id:` in front; whole numbers may
        come as text or as `1.0`; a fraction such as `1.9` is refused,
        not cut. A mistake gives an error the model can read.
      - A negative `limit` gives every node for `central`, as SQLite's
        `LIMIT -1` does on the server, and drops the last ones for the
        networkx rankings, as Python's slice does there.
      - Tags and titles are those of the index, which the app renews when
        it comes back to the foreground; `read_node` also checks the file
        as it is now (decision 42), since it is the one tool that gives
        note texts.
    - **Hidden notes (decision 42)** are removed from the graph before any
      tool runs, with their links; `read_node` leaves out hidden headings
      and titles, and a file that hides its node now is not read.
    - **Results as compact text**, not JSON: one line per node with its ID
      and title, for example `0.0123 | <ID> | <title>`. The data with the
      server's keys is what the tests compare.
    - **Checked against the server itself:** `tool/ai_tools_expected.py`
      runs the server's own tool functions, in its own environment, on a
      database `tool/build_roam_db.dart` builds from the sample notes and on
      the random graph of #27, and writes
      `test/fixtures/ai_tools_expected.json`. `test/ai/ai_tools_test.dart`
      compares every tool with it, rows of equal rank as groups. Louvain is
      random and the server sets no seed, so the communities are checked
      against the modularity and community counts of 20 python-louvain
      runs at resolutions 0.5, 1 and 2.

45. **The AI chat talks to a provider the owner chooses, over one of two
    APIs** (#59), `lib/ai/ai_chat.dart`, `lib/ai/ai_providers.dart`.
    - **The app goes online for this, and only for this.** Decisions 2 and
      14 kept the app offline. The chat needs a model, and none runs on the
      phone, so the app now has Android's `INTERNET` permission. It is
      used only by the chat, and only when I send a message: then one
      request per tool round goes to the provider I chose, with my message,
      the conversation so far, the tools' descriptions and the tool
      results the model asked for (note texts among them, without the
      notes hidden by decision 42). Nothing is sent in the background, and
      the rest of the app stays offline (web images stay links).
    - **Two APIs, each with a tool loop:** Anthropic's Messages API
      (`POST <base>/v1/messages`, `x-api-key`, `anthropic-version:
      2023-06-01`, `tool_use` and `tool_result` blocks), and the
      OpenAI-compatible Chat Completions API (`POST
      <base>/chat/completions`, `Authorization: Bearer`, `tools`,
      `tool_calls`, `role: tool`). The app runs the tools the model asks
      for (decision 44) and sends the results back, until the model
      answers. Anthropic's answers are sent back exactly as they came,
      thinking blocks and their signatures included, which the API requires
      in a tool loop; DeepSeek's `reasoning_content` likewise.
    - **Presets** are one plain data list (`providerPresets`), so the list
      can change without touching the logic; every value stays editable.
      The settings list them in two groups, "Data stays in the EU" and
      "Outside the EU", each with a one-line note on where the data goes,
      shown when it is chosen. Checked against each provider's
      documentation on 2026-10-17:

      | Preset | API | Base URL | Model / strong model |
      |---|---|---|---|
      | Claude on AWS Bedrock (EU) | Anthropic | `https://bedrock-runtime.eu-central-1.amazonaws.com/anthropic` | `eu.anthropic.claude-sonnet-5-5` / `eu.anthropic.claude-opus-5-5` |
      | Mistral | OpenAI | `https://api.mistral.ai/v1` | `mistral-large-4` |
      | Scaleway | OpenAI | `https://api.scaleway.ai/v1` | (chosen from its list) |
      | Vercel AI Gateway, "EU only" on | OpenAI | `https://ai-gateway.vercel.sh/v1` | (any) |
      | Anthropic | Anthropic | `https://api.anthropic.com` | `claude-sonnet-5-5` / `claude-opus-5-5` |
      | DeepSeek | OpenAI | `https://api.deepseek.com` | `deepseek-v4-pro` |
      | Qwen (Alibaba Cloud) | OpenAI | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | `qwen3.8-max` |
      | OpenRouter | OpenAI | `https://openrouter.ai/api/v1` | (any) |
      | Hugging Face | OpenAI | `https://router.huggingface.co/v1` | (any) |
      | Custom | either | (any, for example IONOS, Nebius, OVHcloud, STACKIT, Infomaniak or Ollama) | (any) |

      - Bedrock: AWS's model cards list the Messages API on
        `bedrock-runtime` with EU inference profiles (`eu.` in front)
        that keep requests in EU regions; `bedrock-mantle` serves these
        models only outside the EU. A Bedrock API key goes in `x-api-key`,
        as AWS's examples send it.
      - Mistral Large 4 is in "public preview"; its page lists the API
        names `mistral-large-4` and `mistral-large-4-0`.
      - Vercel's "EU only" sends `providerOptions.gateway.inferenceRegion
        = {scope: zone, geoRegion: eu}` in the body, as Vercel documents
        it; a model without an EU route then fails instead of running
        elsewhere.
      - Value picks are named in the notes: Sonnet 5.5 "safe default",
        Mistral Large 4 "best value in the EU", DeepSeek V4 Pro "best
        value outside the EU". DeepSeek's note says that the data is
        processed and stored in China, that reports say inputs may be used
        for training, and that Chinese law can require access.
      - No small model (such as Haiku) is a default or a strong model: the
        chat may propose notes to save. Any model can be typed in.
    - **Settings**, on the AI settings page, reached from "AI" on the
      Settings page (#63) and from the folder screen; the graph's "More"
      menu no longer has its own entry. They stay in `ai-settings.json`
      with the hidden tags (decision 42), not in #63's
      `view-settings.json`, so all AI settings are in one place: the
      provider, and per provider its base URL, default model, optional strong model (the
      chat can switch to it, #60), the API for Custom, and Vercel's "EU
      only" (on by default). Also the most tool rounds per message
      (default 10) and the most tokens per answer (default 8192, more than
      the issue's 4096, because Claude's thinking counts towards it).
    - **API keys** are kept per provider in Android's secure storage
      (`flutter_secure_storage`: encrypted with a key the Android Keystore
      holds), never in the notes or a plain file; the page never shows a
      saved key, only that one is saved, and can remove it. Custom works
      without a key, for a local Ollama.
    - **Prompt caching.** Every request starts with the same bytes: the
      system prompt, which never changes (no time, no counter, no node),
      then the tools in their fixed order, then the conversation, which
      only grows; the node a chat starts from goes into the first message
      (#60). Anthropic: `cache_control: {type: ephemeral}` on the system
      prompt (which caches the tools before it) and on the last block of
      the conversation, so each round reads the earlier rounds from the
      cache (5 minutes; at least 512 tokens for Sonnet and Opus 5.5, so
      the tools alone qualify). OpenAI-compatible providers cache a
      repeated start by themselves where they support it; the app reads
      the cached tokens from `usage.prompt_tokens_details.cached_tokens`,
      or DeepSeek's `prompt_cache_hit_tokens`. Each chat counts its input,
      cached and output tokens. A test checks that each request starts
      with the one before.
    - **Limits:** a message may run the most tool rounds set; the last
      round's result says it was the last. If the model still asks for
      tools, they are not run and its text, if any, is its answer. The
      count belongs to the message: "Send again" after an error goes on
      counting. Every tool call gets a result, also when the tool fails
      (as an error the model reads), since both APIs refuse a conversation
      with a tool call left without one.
    - **Errors say what to do:** no key, model or base URL (nothing is
      sent); no network or no answer in time; 401 or 403 (the key); 429
      (rate limit or credit); 404 (base URL or model); 400 that mentions
      tools (the model may not support them); any other HTTP error with
      the provider's own message. An answer cut at the token limit is
      dropped, so "Send again" asks again. After an error, the chat can
      send the conversation again from where it stopped.
    - **Keys only over HTTPS; no redirects.** A key is never sent to an
      `http://` base URL (Custom can reach a local server over HTTP without
      a key, such as Ollama). Redirects are not followed, so the
      conversation cannot go to another host than the base URL's.
    - Answers are not streamed: an answer appears when it is complete.
      Qwen does not allow streaming together with tools anyway.

46. **The AI chat screen** (#60), `lib/ai/chat_screen.dart`.
    - **Where:** "Ask AI" in the graph view's "More" menu, with the
      selected node, and in the node view's new AI menu, with that node.
      The node view's "Share with AI" moved into the same menu, so the bar
      still fits a phone held upright.
    - **The node the chat starts from** goes into the first message ("I am
      looking at the note … (ID …)"), not into the system prompt, so every
      request still starts with the same bytes (decision 45). On screen,
      my message shows without it.
    - **Model switch:** the chat starts with the provider's default model;
      where the provider has a strong one (Anthropic and Bedrock: Opus
      5.5), a menu switches to it for the rest of this chat. The bar shows
      the provider and the model in use; each answer shows the model that
      wrote it.
    - **Tool calls are shown**, collapsed, as `find(search: Plan)`; opened,
      with the result the model got. Below the chat: its tokens, in, of
      them from the cache, and out (decision 45).
    - **Answers are rendered as Org** with `org_flutter`, so
      `[[id:…][…]]` links can be tapped and open the node, as in the node
      view. Other links are not opened.
    - **"Save as new node"** on an answer opens the capture screen (#11)
      with a title and text proposed as for shared text (#15, decision
      34): the first line without `#` or `**` is the title. A chat started
      from a node offers a link to it, on. Nothing is written before I
      save there; the AI never writes a file.
    - **Errors** show in the chat with "Send again", which sends the
      conversation from where it stopped (decision 45). Without a key or a
      model, the chat says what to enter and links to AI settings; Send
      stays off.
    - **The conversation** is kept only while the chat is open; "New chat"
      starts again, with the settings as they are then. Nothing of it is
      stored. Closing the chat stops it: a request under way finishes, but
      no tool runs and nothing more is sent.
    - **An open chat follows the app:** after a scan brings or removes
      notes, or a tag is hidden in the settings, the next tool call uses
      the graph and the hidden tags as they are then.
    - **A hidden note is not named.** A chat opened from a note hidden from
      AI (its index tags or its file as it is now, decision 42) says so and
      does not put the note into the first message.
    - **One turn at a time:** after an error, Send stays off until "Send
      again" has finished the turn, or a new chat starts, so a new question
      does not join the unanswered one.
    - A proposed title loses the stars of an Org heading (`* Title`), as it
      loses a Markdown `#`.

47. **Help pages are Org files with `id:` links, shown by the node view**
    (#62), `assets/help/`, `lib/help/help.dart`.
    - Ten pages, written for the app: the start page, the graph view, the
      layouts, the graph views, the other graph algorithms, the node view,
      capture and shared text, AI (hidden notes, sharing, the chat),
      Syncthing conflict copies, and the settings. Each is an Org file
      with its own `:ID:` (`roam-graph-help-…`, never a UUID, so it cannot
      be one of my notes) and `#+title:`, linked to the others with `id:`
      links. None of my notes is in the repo.
    - The app parses them as it parses notes and shows them with the node
      view (decision 26), so a link in the help works as in a note, and
      Back returns. The help is its own small graph, read from the app's
      assets when help opens; it is never in my graph, search, AI shares
      or the AI chat. A help page has no search and no AI menu, which
      would act on the help, and is not remembered as the node viewed
      last.
    - Each page has `#+STARTUP: showall`: help pages are short and read
      whole, and a file's own line wins over the setting of #63.
    - **Where:** "Help" on the folder screen's bar and in the graph's
      "More" menu opens the start page. The "?" next to a control: "About
      the layouts" under the layouts in the "More" menu, and "About the
      views" at the end of the "View" menu.
    - Not built (optional in the issue): showing the help as a graph, and
      links from the help to my notes by title.
    - Tests: every file in `assets/help/` is listed and is one node; every
      `id:` link points to a help page and every page is linked; the help
      is not part of my graph; the entries open their pages, and a link
      between pages works.
48. **A changelog, and release texts taken from it** (#70),
    `CHANGELOG.md`, `tool/release_notes.dart`,
    `.github/workflows/build.yml`, `.github/workflows/changelog.yml`.
    - Every merge to `main` is a release, but its text was only "Built
      from <sha>", so Obtainium showed updates without saying what
      changed.
    - **The file:** newest first, one entry per pull request, headed
      `## YYYY-MM-DD: <title> ([#PR](<url>))`, with 1 to 4 lines on what
      changed for the user and the issue it closes. No version numbers:
      the version is `0.1.<run number>`, known only when the release is
      built. The history before the changelog was written once from the
      merged pull requests; each of those entries names the release it
      first shipped in, found by matching the release's "Built from" commit
      (pull requests whose own build was replaced by a later one name that
      later release). It is not rewritten before 1.x.
    - **The release text:** the build job, on `main` only, reads the
      `CHANGELOG.md` of the newest published release built by an earlier
      run (so re-running an old run does not compare with a newer release)
      through the API (the checkout is shallow). Only a 404 counts as "no
      changelog there"; any other failure stops the build, because
      guessing would leave entries out of every later release text. Then
      it runs `tool/release_notes.dart`: the entries
      whose heading the previous copy does not have, then "Built from
      <sha>". When the previous release has no changelog, or nothing is
      new (a release built again), the top entry only. The text travels
      with the APK in the build artifact; the release job, unchanged in
      its permissions, passes it to `gh release create` or `edit`. Entries
      are matched by heading, not by a diff, so an edit to an older entry
      does not show as new.
    - **The check:** a separate workflow, `changelog.yml`, on pull
      requests (also when labels change). It asks the API which files the
      pull request changes; it runs no code from the pull request and
      uses no actions. A change under `lib/` or `android/` fails unless
      the patch of `CHANGELOG.md` adds a `## ` heading (an edit to an old
      entry alone would give the release no new text), with a message that
      says what to add. A deleted `CHANGELOG.md` fails too. The
      label `skip-changelog` lets a change through that users do not see.
    - Tests: `test/tool/release_notes_test.dart` (new entries in order,
      no previous changelog, nothing new, no entries, and the headings of
      the repository's own changelog).

49. **On a tablet in landscape, the split is mine to set** (#69),
    `lib/graph_view/two_panes.dart`. Decision 29 put graph and note side
    by side at 3 : 2; the note was narrow to read.
    - **A divider to drag**, between the panes: a thin line with a drag
      handle, in a touch area 24 pixels wide. It follows the finger from
      where it touched. The graph keeps at least 240 pixels and the note
      320; dragged past half the graph's minimum, the strip shows that the
      graph will fold. The graph is centred once, when the divider is let
      go, not on every move, and on the current note when it unfolds,
      also when that note was opened while it was folded.
    - **View settings apply at once**, before they are saved, so a second
      change made while the first is saving builds on it; a failed save
      undoes it (this changes the settings host of #63).
    - **Fold the graph:** a button on the graph folds it into a 48-pixel
      strip, and the strip's button unfolds it at the width it had.
      Dragging the divider past half the graph's minimum folds it too.
      "Show in graph" from the note unfolds it. While it is folded, links
      in the note open in the note pane as before; the graph keeps its
      centre and, unfolded, is centred on the current note.
    - **The default** is 40 % graph, 60 % note. A double tap on the
      divider restores it, unfolded.
    - **Remembered** in the view settings (`view-settings.json`, decision
      43): the graph's share and whether it is folded; they survive a
      restart. A drag is saved when the finger lifts, not on every move.
    - **Settings:** "Graph width on the tablet" shows the share, or that
      the graph is folded, with "Reset".
    - On a phone, and in portrait, nothing changes: one screen at a time.

50. **The graph starts force-directed, as a setting** (#71). The graph
    view always started with the circular layout; I use force-directed
    most of the time, because it shows the clusters.
    - **"Graph layout at start"** on the Settings page: Force-directed (the
      default), Circular (circo), or Last used: the layout chosen last in
      the "More" menu.
    - **Kept in the view settings** (`view-settings.json`, decision 43):
      the choice, and the layout chosen last in the menu, which every
      switch in the menu stores, so "Last used" works from the first
      switch on.
    - **When:** the graph view reads it when it opens (at app start, or
      when the folder is opened again). A graph already showing keeps its
      layout; the menu still switches it for the session. It waits until
      the view settings are loaded from the file, so it never starts with
      the defaults by mistake, but at most a second, so a file that
      cannot be read never stops the graph; a layout chosen in the menu
      before that wins (#81).
    - The force-directed layout runs off the UI isolate as before
      (`computeLayout`), with the progress circle while it runs.
    - An unknown stored value falls back to the default. The layouts help
      page (decision 47) mentions the setting.
    - The older graph-view tests were written for the circular start; they
      now set it explicitly.

51. **Edits of existing notes are saved safely** (#35), as decision 10
    says, `lib/edit/note_editor.dart` and `replaceFile` in
    `FolderAccess.kt`. One path for appending (#36), editing (#37) and AI
    edits (#39):
    - **The version an edit is made on:** the note is read as bytes; its
      SHA-256 is remembered with the text. A file that is not UTF-8 cannot
      be edited, since it could not be written back unchanged.
    - **The check:** `replaceFile` reads the file again on the Android side
      and compares the hash, once before writing the new text and once
      more just before the swap. If it differs (the laptop or Syncthing
      changed the note meanwhile), nothing is written; the app gets the
      note as it is now, to start again from it.
    - **The swap:** the new text goes to `.syncthing.<name>.edit.tmp`; the
      old file is renamed to `.syncthing.<name>.old.tmp`, the new one to
      `<name>`, and the old one deleted. Syncthing treats names that start
      with `.syncthing.` and end with `.tmp` as temporary and never syncs
      them. Every rename is checked for its exact result: a provider may
      give `<name> (1)` instead, and such a rename is undone, so no stray
      copy is synced. If the new file cannot take the name, it is deleted
      and the old file is renamed back, but only onto a free name. An old
      copy left behind by a failed attempt may be the only copy of the
      note, so it is never deleted: the next save of that note stops and
      names it, to be looked at on the laptop. Android's folder access
      cannot replace a file in one step: a rename onto an existing name
      gives `<name> (1)` instead. So for a moment between the two renames
      the name is free; Syncthing's watcher waits about ten seconds before
      it scans, and then finds the new file in place.
    - **Locked parts (rule 5):** an edit that changes, adds or removes a
      property drawer, and with it an `:ID:`, is refused before anything is
      written. So is one that changes the line right before a drawer: Org
      attaches a drawer to the heading (or planning line) just above it,
      so a drawer moved under another heading, or text put between a
      heading and its drawer, would give the `:ID:` to another node or to
      none.
    - **Old versions (rule 3):** before each save, the note's text as read
      is kept in the app's own folder, `edit-history/`, one folder per note
      named by the hash of the chosen folder's URI and the note's path, so
      notes of the same name in two folders do not mix. Two versions never
      share a time. If the save is refused or fails, that copy is dropped
      again; only after a save succeeded are the versions beyond the newest
      20 removed, so a refused save never costs an old version. Restoring
      an old version goes through the diff of #38.
    - **Afterwards** the folder is indexed again, so the graph, the node
      view and the backlinks show the change. The saved note is read in
      that scan even if the folder reports the same modification time as
      before, which some document providers do. If indexing fails, the
      edit is saved and shows with the next scan.
    - **The transport is an interface,** `NoteStore`: the Syncthing folder
      now; git could take its place, as decision 10 describes.
    - Tests: an unchanged file is saved, indexed and its old text kept,
      also with an unchanged modification time; a file changed meanwhile is
      refused and nothing is written or kept; a gone file, the same text, a
      changed drawer, a drawer moved under another heading and text put
      before a drawer are refused; a folder with read access only is not
      written; at most 20 versions are kept, and a refused save at that
      limit loses none; two versions at the same time keep their own.
      The Android swap itself is not run by the tests; checking it against
      the laptop is the owner's task on the device.

52. **A model is picked from the provider's list** (#75),
    `lib/ai/ai_models.dart`, `lib/ai/model_picker.dart`. Typing an exact
    model ID on a phone is error-prone, and some presets have no default.
    - **"Choose model"** next to the model and strong-model fields fetches
      the provider's list with the key typed in or saved: `GET
      {base}/models` for OpenAI-compatible APIs, `GET {base}/v1/models`
      (with `x-api-key`, `anthropic-version`) for Anthropic's. A
      searchable page shows it; picking a model fills the field, which
      stays editable for IDs the list lacks.
    - **What a list says is used where it says it:** tool calling from
      OpenRouter's `supported_parameters`, Mistral's
      `capabilities.function_calling`, Vercel's `tags` (`tool-use`) and
      Hugging Face's `providers[].supports_tools`; prices from
      `pricing.input`/`output` (Vercel) or `prompt`/`completion`
      (OpenRouter), US dollars per token, shown per million; Vercel's
      `regions`. Anthropic's models all call tools. Where a list knows
      tools, only models with tools are shown, with a switch for all: the
      chat needs tools.
    - **With Vercel's "EU only"**, a model whose regions lack `eu`, or
      that lists none while others do (Vercel: no regional route), is
      marked and cannot be picked. Where a list says nothing about
      regions, the page says a model may fail.
    - Fetched only when the button is pressed, kept for the session per
      provider, base URL and key (a hash of it), "Fetch again" to renew.
      Anthropic's list is read page by page (`has_more`, `after_id`). A
      model the list says nothing about tools for is shown with those
      that call tools. A malformed base URL, a TLS failure or any other
      error ends in a message, never a spinner that stays. No key, a refused
      key, 404, no network, an unreadable list: a message, and the field
      still works. Keys only over HTTPS, no redirects (decision 45).

53. **Answers whose content is a list of parts are read and replayed**
    (#79), `contentText` and `OpenAiApi` in `lib/ai/ai_chat.dart`.
    Mistral Large 4 answers after tool results with `message.content` as
    a list: `thinking` parts and `text` parts. The app read only a string,
    so the answer was empty, and the next request sent an assistant
    message with neither content nor tool calls, which Mistral rejects
    with HTTP 400.
    - **Shown:** the `text` parts, joined. `thinking` parts and anything
      else are not shown. Parts that are not maps, or whose `text` is not
      a string, are skipped.
    - **Sent back:** a received list goes back unchanged, thinking
      included, as Mistral's reasoning docs ask ("always replay the full
      assistant message"). A string answer goes back as a string.
    - **An answer with no content and no tool calls** is left out of the
      history, since Mistral rejects it; the chat shows "The model sent
      no text." in its place.
    - **HTTP 400:** the provider's message comes first. "May not support
      tools" is added only when the message says that tools are not
      supported, not whenever it contains "tool": Mistral's "must have
      either content or tool_calls" is about the history.

54. **"Add to this node" appends without touching what is there** (#36),
    `lib/edit/append.dart`, `lib/edit/node_text.dart` and
    `lib/edit/append_screen.dart`:
    - **Where it goes:** for a file node, at the end of the file; for a
      heading node, at the end of its subtree, before the next heading of
      the same or a higher level, as `org-end-of-subtree` ends it. Headings
      are found as Org's `org-outline-regexp-bol` finds them: stars at the
      start of a line, then a space, also inside a block. The heading is
      the one whose property drawer, directly after it or after its
      planning line, holds the node's `:ID:` (the key in any case, the
      value exactly), not the line the index stored, which may have moved.
      An `:ID:` line elsewhere does not count. For a file node, the file's
      drawer (after comment lines only) must still hold the ID. If no
      drawer holds it, nothing is saved and the typed text stays.
    - The text goes after the node's last line that is not blank, so the
      blank lines before the next heading stay where they are. Trailing
      blank lines of the typed text are dropped (spaces at the end of its
      last line stay); the file's line endings
      are kept, and a file without a final newline gets one.
    - **Saved as every edit** (decision 51). The note is read again when
      saving, and the text is added to that version, so what the laptop
      wrote meanwhile stays: appending replaces nothing that was shown. A
      change in the split second between that read and the write is still
      refused, and the typed text stays to save again.
    - **The folder:** the screen remembers the folder it opened in. If
      another folder is chosen meanwhile (when asked for write access), a
      note of the same path there is another note, so nothing is saved.
    - **Where:** an "Edit" menu in the node view, with "Add to this node";
      not on help pages. The node view shows the text at once, since the
      folder is indexed after the save.
    - Tests: a file node, a heading node with a subheading, a heading with
      only its drawer, several lines, CRLF, no final newline, a gone
      heading; and in the app, text added in the node view, and a folder
      with read access only, which offers to choose it again.

55. **The diff before saving, and earlier versions** (#38),
    `lib/edit/line_diff.dart`, `lib/edit/diff_screen.dart` and
    `lib/edit/history_screen.dart`:
    - **The diff** compares the note as it is with the note as it will
      be, line by line, as `diff -u` does: Myers' shortest edit script,
      the algorithm of GNU diff, removed lines before the lines that
      replace them, and three lines of context, with nearby changes in one
      block. It counts the lines removed and added, and marks each line
      `-`, `+` or blank, in colour, in a monospace font that fits a phone.
      It is computed once per screen, and only up to 2000 changed lines:
      the search keeps, per step, only what that step reads. Beyond that
      the screen gives the line counts instead of the lines. A change the
      lines cannot show, only line endings or the final newline, is named
      as such; any difference can be saved.
    - **Nothing is written in the diff:** "Save" returns to the screen that
      opened it, which saves as every edit is saved (decision 51); "Back to
      editing" writes nothing. Lines above the diff can say more, such as
      an AI's reason for the edit or links to IDs that are no note (#39).
    - **Who uses it:** restoring an earlier version now; editing a node's
      text (#37) and AI edits (#39) next. Appending (#36) needs none, since
      it only adds.
    - **Earlier versions,** in the node view's "Edit" menu: the versions
      the app kept before each edit made here (rule 3), newest first. One
      is restored through the diff against the note as it is now, and
      saved as every edit is, so restoring keeps the version it replaces
      too. The list belongs to the folder it was opened in: if another
      folder is chosen meanwhile (for write access), nothing is restored
      there, as for appending (decision 54).
    - Tests: added, removed and changed lines, line numbers on both sides,
      a moved block as one removal and one addition, hunks with context
      that merge when close, and 200 random edits from which both texts
      are rebuilt; in the app, a version restored through the diff, and
      the list without versions.

56. **"Edit text" changes a node's text, with its head locked** (#37),
    `lib/edit/edit_screen.dart`:
    - **What can be edited:** a file node's text below its head, or a
      heading node's subtree below its head. The head stays as it is
      (rule 5) and is shown above the text field, not editable: for a
      heading node its heading line (title and tags), planning line and
      property drawer; for a file node its property drawer and the keyword
      lines after it, such as `#+title:` and `#+filetags:`. Drawers of
      other headings in the text are guarded on saving (decision 51).
    - **Saving:** "Review" shows the diff (decision 55) of the whole file;
      only "Save" there writes, and only over the version the editor
      opened (rule 1). If the laptop changed the note meanwhile, nothing is
      written: the typed text is copied to the clipboard, and the editor
      can start again from the new version.
    - **The folder:** the editor belongs to the folder it opened in, taken
      before the note is read, and checked again after the diff; if
      another folder is chosen meanwhile (for write access), nothing is
      saved there, as for appending (decision 54).
    - **Keywords:** `#+title:` and `#+filetags:` set the file's title and
      tags wherever they are, so their lines in the editable text must
      stay as they are too; otherwise nothing is saved.
    - **"Start again"** opens the editor on the new version within the
      same action, so a save made there is reported like the first.
    - Leaving with unsaved changes asks first. While a save runs, the page
      cannot be left and the text cannot be changed: the save has the
      text it was given, and cannot be called back.
    - Links are typed as in Emacs, `[[id:…][…]]`; inserting a link from
      search is left for later.
    - Tests: in the app, the head shown but not editable and the diff
      before anything is written; "Back to editing" writes nothing; a note
      changed on the laptop meanwhile is not overwritten.

57. **AI edits: the AI proposes, I see the diff, the app saves** (#39),
    `lib/edit/edit_proposal.dart`, `lib/ai/edit_tools.dart`. The AI never
    writes. Two ways in:
    - **The in-app chat (#60)** offers the tool `propose_edit` (node ID,
      mode `append` or `replace`, Org text, reason), but only where edits
      can be saved. The tool writes nothing: it records the proposal and
      tells the model so. Notes hidden from AI (decision 42) cannot be
      proposed, since the tool only knows the visible graph. In the chat
      the proposal shows as a card with "Review": the diff (decision 55)
      against the note as it is now, with the AI's reason and any `id:`
      links that point at no node; only "Save" writes (decision 51). The
      tool is in the request from the first message on, so the request
      still starts with the same bytes and the provider's cache holds
      (prompt caching).
    - **The share menu (#15):** the capture screen for shared text also
      offers "Use for an existing node": "Add to a node" (decision 54) or
      "Replace a node's text" (decision 56), with the node chosen from a
      list that proposes the node viewed last. A replacement goes through
      the editor and its diff. An AI app often returns the whole note;
      when the shared text starts with the node's own drawer, the drawer
      and the keywords after it are dropped, since the head stays as it
      is.
    - **For change sets (#76):** a proposal is an `EditProposal`; applying
      it (`applyProposal`), checking its links (`unknownLinkIds`), the
      diff screen and the save are separate pieces, so a set of proposals
      can be reviewed one diff per file and saved one file at a time.
    - Workflow with the Claude app: share the note to it (#41), ask for a
      revised version, share the answer back, choose "Replace a node's
      text", read the diff, and save.
    - Tests: applying both modes to a file node and a heading node, a whole
      returned note losing its head, unknown links, the tool's checks; in
      the chat, a proposal saved only after the diff, and a hidden note
      refused; in the app, shared text added to the node viewed last, and
      a revised note replacing a node's text after the diff.

58. **AI change sets: edits to several notes, reviewed together** (#76),
    `lib/edit/change_set.dart`, `lib/edit/change_set_screen.dart`, and the
    chat tool `propose_edits`. Built from the pieces of decision 57:
    - **The tool** takes a list of edits, each as in `propose_edit` (node,
      `append` or `replace`, text, reason), and a summary. It writes
      nothing. One edit per file; at most the limit set in AI settings
      ("Most notes one AI change set may edit", 20 by default), which the
      tool's description tells the model. Notes hidden from AI cannot be
      part of a set.
    - **The set is built when it is first reviewed:** each note is read
      then, and the edit applied to it, so every diff is against the note
      as it is. `id:` links to IDs that are no note are flagged.
    - **Review:** one card per file, with its reason, the lines removed and
      added, and Diff, Accept, Reject and Edit (the proposed text, before
      accepting); "Accept all"; the number of files and links the accepted
      entries change.
    - **Saving:** the accepted files are saved one after the other, each
      as every edit is (decision 51), each over the version the set was
      built on. A file changed meanwhile is refused alone; the others
      still save. The end says how many were saved, refused and rejected.
      Each file is replaced whole, so a sync meanwhile sees whole files;
      conflict copies stay the laptop's (rule 4).
    - **Undo:** "Undo this change set" gives every saved file back the text
      it had before, but only if it is still as the set saved it;
      otherwise it names the files it could not undo. Undoing is itself
      saved as an edit, so the old versions stay.
    - Tests: three files, two accepted and one rejected; one file changed
      between proposal and save, refused alone; undo of all saved files
      except one changed since; an unknown link flagged; a hidden note,
      two edits of one file and too many files refused; an entry edited
      before accepting; in the chat, a set reviewed, saved and undone.

59. **Agent mode: the AI creates, edits and links notes itself** (#82),
    `lib/ai/agent_tools.dart` and `lib/edit/agent_changes.dart`. On the
    laptop, the org-roam MCP lets Claude change a whole set of notes
    without asking each time; reviewing every change (decisions 57 and
    58) is too many taps for that. So the chat gets write tools and no
    confirmation per change, and control comes at the end instead.
    - **"Let the AI change notes"** in AI settings: Off (read only),
      Review each change first (decisions 57, 58), or Agent, the default.
      Only where notes can be saved; otherwise read only.
    - **The write tools,** next to the read tools of decision 30:
      `create_node(title, text, tags)` writes a new file node as capture
      does (decision 31: file name, new `:ID:`, `#+title`, `#+filetags`);
      notes made in the same second get the next second's name. Its text
      may not hold `#+title:`, `#+filetags:` or property drawers: the
      title and tags are arguments, and the note gets its own `:ID:`.
      `append_to_node(id, text)` adds at the end of the node as decision
      54 does. `edit_node_text(id, old, new)` replaces text that occurs
      exactly once in the node's text below its head (decision 56).
      `add_link(from_id, to_id, description)` adds the link to the
      node's last "See also:" line, or adds that line; nothing if the
      node links there already. Both look only at the node's own text,
      up to its first subheading that is a node itself, whose links
      org-roam counts for that node.
    - **Every write keeps the rules of decision 10:** the note is read
      when the tool runs and saved only over that version (rule 1),
      through the temporary file (rule 2), with the old version kept
      (rule 3), and no change to an `:ID:`, a property drawer, or the
      `#+title:` and `#+filetags:` lines (rule 5, decision 56). A write
      that breaks a rule writes nothing and comes back to the model as a
      tool error, so it can read again and retry.
    - **The folder:** a write goes only into the folder the note was read
      from; if another folder was opened meanwhile, nothing is written.
      Undo, too, only touches files in the folder of the change.
    - **The system prompt** says, in agent mode, that the write tools save
      at once and that I can undo, instead of "I review it".
    - **What the AI may not see, it may not change** (decision 42): hidden
      notes cannot be edited or linked to, a new note cannot get a hidden
      tag, and a note with hidden parts (a hidden heading, or a link to a
      hidden note, which the AI sees as "(hidden)") cannot have its text
      replaced; it can still be appended to and linked. Links to IDs that
      are no visible note are refused.
    - **A limit per message:** "Most changes the agent may make for one
      message", 30 by default; beyond it the tool says so and the model
      can say what is left.
    - **Afterwards, in the chat:** "2 notes created, 1 changed, 3 links
      added", each note to open, its change as a diff (decision 55, only
      to look at), and **"Undo all changes of this message"**: each
      changed note gets back its text from before the message and each
      created note is deleted (kept in the edit history first), but only
      a file that is still as the agent left it; the others are named. If
      a file could not be written, "Try the rest again" retries only
      those. The diff shows the whole file, hidden parts included: it is
      shown to me, not to the AI.
      Deleting checks the hash on the Android side, as replacing does
      (`deleteFile` in `FolderAccess.kt`).
    - **A log,** `agent-changes.jsonl` in the app's support folder: time,
      folder, file, tool, and the SHA-256 before and after, one line per
      change. With the old texts in the edit history, a change can be
      traced and undone later, also after the chat is closed.
    - Tests: a chat that creates two nodes and links them to an existing
      one (three files, the links in the graph); a file changed between
      read and write, refused and then retried; "Undo all", also with a
      file changed since; the limit; hidden notes; the drawer and head;
      in the app, the summary and "Undo all", and no write tools when
      Off.

60. **The theme is a setting: System, Light or Dark** (#90). The app
    had a light and a dark theme and followed Android's setting, with no
    way to choose. Now "Theme" on the Settings page says which, kept in
    the view settings (decision 43) and applied at once.
    - `MaterialApp.themeMode` reads it, so `ViewSettingsHost` moved from
      `MaterialApp.builder` to above the app; every screen still reads
      the same settings.
    - **Checked in both themes:** colours come from the theme's colour
      scheme almost everywhere (diff, chat, node view). Two places have
      their own: the graph's community colours, which get lighter shades
      of the same hues in the dark theme, and SVG images, which stay on
      white in the dark theme on purpose (#47), since most are drawn for
      a white page. Source blocks (#45) and mermaid (#49) already follow
      the theme.
    - Tests: the setting saved and read back, an unknown value giving
      System; `MaterialApp` gets each mode; the Settings page switches at
      once; the graph view in the dark theme.

61. **The chat can be copied** (#94). An error in the chat could not be
    passed on: answers were not selectable, and tool results were hard to
    select on a phone. Now every answer has a Copy button and can be
    selected; an opened tool call has a Copy button for the call and its
    result together; the error card can be copied and selected. Copying
    says "Copied.".

62. **The agent may delete notes when I ask** (#93), `delete_node` in
    `lib/ai/agent_tools.dart`. Trying agent mode, I asked the chat to
    replace a note by a better one; it made the new one but could not
    delete the old one. My decision: when I tell the AI to delete one note
    or several, it may, also notes that others link to.
    - **Only on my request:** the tool's description and the agent's
      system prompt say so.
    - **A file node:** its file is deleted, with the heading nodes in it;
      only files directly in `roam/`, as capture makes them, so "Undo all"
      can put the file back. **A heading node:** the heading and its
      subtree are removed from the file. The save allows exactly the
      drawers of the removed part to go (`NoteEditor.save(removed:)`);
      every other drawer stays (rule 5).
    - **No dead links where the AI may write:** in the other notes the AI
      may see, links to a deleted node become their link text, one change
      per file. Notes hidden from AI keep their links, and the AI is not
      told about them.
    - **As every write:** only if the file is unchanged since it was read
      (the Android side checks the hash before deleting), only in the
      folder it was read in, its text kept in the edit history first;
      hidden notes cannot be deleted. Counted in the limit per message,
      shown in the summary ("1 deleted"), logged with no new hash.
    - **"Undo all"** writes a deleted file again with the same name and
      text, so the same `:ID:`, if no file of that name is there
      meanwhile; removed headings and changed links come back as every
      edit does.
65. **"Recent AI changes": undo after the chat is closed** (#99),
    `lib/edit/recent_changes_screen.dart`. "Undo all" lived only in the
    chat, so closing it lost the undo, although every change was logged.
    - **The log has what undo needs:** each line of `agent-changes.jsonl`
      (format 2) adds the message's ID and first 80 characters, and the
      change itself: the note key, node, title, the file before and after,
      and a removed heading. The full texts, not a reference into the edit
      history, because the history keeps only 20 versions of a note and
      would lose older ones; the log is in the app's private folder, as
      the history is. Lines of the first format are shown, without undo.
    - **The screen,** from the history button in the chat's app bar (the
      chat has the folder's writer; Settings does not): the messages of
      the last 30 days, newest first, with time, first words and the
      summary; each opens to its notes, and a note's change opens as a
      diff.
    - **"Undo these changes"** runs the chat's "Undo all" (decision 59) on
      the changes read back from the log: only files still as the agent
      left them, only in the folder of the change, created files deleted,
      deleted files written again. Notes that stay are named. When no
      file failed, an `undo` line marks the message undone, in the chat
      too.
    - **Size:** the log keeps its newest 1000 lines; older ones are
      dropped when the screen reads it, through a temporary file.

## Recommended, not decided

- **No MCP server on the device, for now** (#14). The owner decides; this
  is the recommendation, with its reasons:
  - **Writing needs no MCP.** An AI app shares text, and the app turns it
    into a node (#15, decision 34). That covers the Claude Android app,
    which cannot write files.
  - **Reading needs a client on the device, and there is none that fits.**
    - The Claude Android app connects only to remote MCP servers on the
      internet. The graph is private and offline on purpose (decisions 2
      and 14).
    - Claude Code on the laptop already has Emacs, the real
      `org-roam.db` and the existing MCP server.
    - An on-device model would be a project of its own.
  - **What the app needs from the server's half is built in already.** The
    graph algorithms the MCP server offers (communities, PageRank, paths)
    are views in the app (#7, decision 30). The app's database has
    org-roam's schema (#5), so the server's read-only queries would run
    on it unchanged if a client ever appears.
  - **When to look again:** when an MCP client on Android can use a local
    server (for example over a local socket), or when the Claude Android
    app can share the graph's database with a local tool. Then the
    read-only half of org-roam-mcp could serve the database the app
    builds itself (decision 23; Emacs's `org-roam.db` stays on the laptop,
    decision 3) as it is.
  - **If the owner agrees:** close #14 and the v3 milestone.

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

- **MCP on the device** (#14). Adding nodes needs no MCP (see 11 and 34).
  MCP would only matter if an AI on the device had to read or query the
  graph without the laptop, and it needs a client there. The Claude
  Android app only connects to remote MCP servers. The recommendation
  above is not to build it for now; the owner decides.

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
