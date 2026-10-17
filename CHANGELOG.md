# Changelog

What changed in the app, newest first. Every pull request adds one entry
at the top: the date it was merged, a short title and the pull request,
then a few lines on what changed for the user. The version is not written
here, because it is only known when the release is built: each release's
text on GitHub repeats the entries it contains, with its version. For the
entries before the changelog existed, the version is given at the end of
each entry.

## 2026-10-17: Edits are saved safely ([#77](https://github.com/ChristianGeng/roam-graph-mobile/pull/77))

- Added: the way edits of existing notes are saved. An edit is written
  only if the note is still the version it was made on, through a
  temporary file, and the old version is kept in the app (the newest 20
  per note). No edit action yet; they come next.
- Closes [#35](https://github.com/ChristianGeng/roam-graph-mobile/issues/35).

## 2026-10-17: The graph starts force-directed, as a setting ([#78](https://github.com/ChristianGeng/roam-graph-mobile/pull/78))

- Changed: the graph now opens with the force-directed layout, which shows
  the clusters.
- Added: Settings, "Graph layout at start": force-directed, circular, or the
  layout chosen last in the More menu.
- Closes [#71](https://github.com/ChristianGeng/roam-graph-mobile/issues/71).

## 2026-10-17: Tablet layout: a divider to drag, and a graph to fold away ([#72](https://github.com/ChristianGeng/roam-graph-mobile/pull/72))

- Added: on a tablet held sideways, drag the divider between graph and note
  to give the note more room; double-tap it for the default again.
- Added: fold the graph into a narrow strip with its arrow button, and
  unfold it again.
- Changed: the note now gets 60 % of the width by default. The layout is
  remembered, and Settings shows it with a Reset button.
- Closes [#69](https://github.com/ChristianGeng/roam-graph-mobile/issues/69).

## 2026-10-17: Rules for editing existing notes ([#73](https://github.com/ChristianGeng/roam-graph-mobile/pull/73))

- Changed: the rules for editing existing notes are agreed and written down
  (decision 10). An edit will be saved only over the version it was made
  on, through a temporary file, with the old version kept; the `:ID:` and
  the property drawer stay as they are. No change in the app yet.
- Closes [#34](https://github.com/ChristianGeng/roam-graph-mobile/issues/34).

## 2026-10-17: A changelog, and release notes taken from it ([#74](https://github.com/ChristianGeng/roam-graph-mobile/pull/74))

- Added: this changelog. Each release's text on GitHub (and so in
  Obtainium) now lists what changed, taken from here.
- Closes [#70](https://github.com/ChristianGeng/roam-graph-mobile/issues/70).

## 2026-10-16: Help pages ([#68](https://github.com/ChristianGeng/roam-graph-mobile/pull/68))

- Added: ten help pages, written as Org files that link to each other and
  shown by the node view. "Help" on the folder screen and in the graph's
  "More" menu; "About the layouts" and "About the views" next to those
  controls.
- Closes [#62](https://github.com/ChristianGeng/roam-graph-mobile/issues/62). Released as v0.1.114.

## 2026-10-16: AI chat ([#67](https://github.com/ChristianGeng/roam-graph-mobile/pull/67))

- Added: "Ask AI" in the graph's "More" menu and in the node view. The AI
  reads the graph with the tools of the org-roam MCP server; the tool calls
  and the tokens used are shown.
- Added: a switch between the provider's default and strong model, links in
  answers that open the note, and "Save as new node" through the capture
  screen.
- Closes [#60](https://github.com/ChristianGeng/roam-graph-mobile/issues/60). Released as v0.1.112.

## 2026-10-16: AI providers and API keys ([#66](https://github.com/ChristianGeng/roam-graph-mobile/pull/66))

- Added: in AI settings, a provider with its base URL, models and API key.
  Presets, grouped by whether the data stays in the EU: Claude on AWS
  Bedrock (EU), Mistral, Scaleway, Vercel (EU only); and Anthropic,
  DeepSeek, Qwen, OpenRouter, Hugging Face, and Custom.
- Added: keys are kept in Android's secure storage and never shown again.
  Requests are built so the provider can cache them.
- Closes [#59](https://github.com/ChristianGeng/roam-graph-mobile/issues/59). Released as v0.1.109.

## 2026-10-16: AI tools on the app's index ([#65](https://github.com/ChristianGeng/roam-graph-mobile/pull/65))

- Added: the 16 read tools of the org-roam MCP server (find, read node,
  backlinks, paths, PageRank, communities and the others), run on the
  app's own index, for the AI chat. Nothing visible changes yet.
- Closes [#58](https://github.com/ChristianGeng/roam-graph-mobile/issues/58). Released as v0.1.106.

## 2026-10-16: Notes open collapsed, and a Settings screen ([#64](https://github.com/ChristianGeng/roam-graph-mobile/pull/64))

- Changed: a note opens with only its top-level headings showing. Tap a
  heading to open it.
- Added: "Settings" in the graph's "More" menu, with "Sections when a note
  opens": Collapsed, Headings or Expanded. A note's own `#+STARTUP:` wins.
- Closes [#63](https://github.com/ChristianGeng/roam-graph-mobile/issues/63). Released as v0.1.104.

## 2026-10-16: Hide notes from AI by tag ([#61](https://github.com/ChristianGeng/roam-graph-mobile/pull/61))

- Added: AI settings, with "Hidden from AI", by default the tag `private`.
  Notes with that tag are left out of every share to an AI, and links to
  them lose their title.
- Closes [#57](https://github.com/ChristianGeng/roam-graph-mobile/issues/57). Released as v0.1.100.

## 2026-10-16: Mermaid diagrams drawn on the device ([#55](https://github.com/ChristianGeng/roam-graph-mobile/pull/55))

- Added: a mermaid block without a result image is drawn below its source,
  labelled "Drawn on the device". Blocks with a result image still show the
  image, as Emacs does.
- Closes [#48](https://github.com/ChristianGeng/roam-graph-mobile/issues/48) and [#49](https://github.com/ChristianGeng/roam-graph-mobile/issues/49). Released as v0.1.96.

## 2026-10-16: LaTeX display formulas ([#54](https://github.com/ChristianGeng/roam-graph-mobile/pull/54))

- Changed: `\[ \]` and `$$ $$` formulas show on their own line, larger.
- Closes [#50](https://github.com/ChristianGeng/roam-graph-mobile/issues/50). Released as v0.1.90.

## 2026-10-16: SVG images ([#53](https://github.com/ChristianGeng/roam-graph-mobile/pull/53))

- Added: SVG images in notes, on a white background in dark mode.
- Closes [#47](https://github.com/ChristianGeng/roam-graph-mobile/issues/47). Released as v0.1.87.

## 2026-10-16: Images ([#52](https://github.com/ChristianGeng/roam-graph-mobile/pull/52))

- Added: images from the notes folder, at their `#+ATTR_ORG: :width`, with
  tap to zoom. A missing image shows a placeholder; web images stay links.
- Closes [#46](https://github.com/ChristianGeng/roam-graph-mobile/issues/46). Released as v0.1.84.

## 2026-10-16: Coloured source blocks ([#51](https://github.com/ChristianGeng/roam-graph-mobile/pull/51))

- Added: source blocks are coloured by language, matched exactly as Emacs
  matches them.
- Closes [#45](https://github.com/ChristianGeng/roam-graph-mobile/issues/45). Released as v0.1.81.

## 2026-10-16: Share nodes with an AI ([#44](https://github.com/ChristianGeng/roam-graph-mobile/pull/44))

- Added: "Share with AI" on a node, and on a selection in search: the
  text, links and backlinks, through Android's share menu.
- Closes [#41](https://github.com/ChristianGeng/roam-graph-mobile/issues/41). Released as v0.1.78.

## 2026-10-16: Share the graph with an AI ([#43](https://github.com/ChristianGeng/roam-graph-mobile/pull/43))

- Added: "Share graph with AI" in the graph's "More" menu: every node's
  ID, title and tags and every link, as text for an AI app.
- Closes [#40](https://github.com/ChristianGeng/roam-graph-mobile/issues/40). Released as v0.1.78.

## 2026-10-16: The graph matches org-roam on real notes ([#33](https://github.com/ChristianGeng/roam-graph-mobile/pull/33))

- Fixed: link types as in Doom Emacs, code and verbatim across line
  breaks, and footnotes. The index is rebuilt once after the update.
- Closes [#5](https://github.com/ChristianGeng/roam-graph-mobile/issues/5). Released as v0.1.72.

## 2026-10-15: No MCP server on the device, for now ([#32](https://github.com/ChristianGeng/roam-graph-mobile/pull/32))

- Documentation only: the recommendation in `docs/decisions.md`. Refers to
  [#14](https://github.com/ChristianGeng/roam-graph-mobile/issues/14). Released as v0.1.69.

## 2026-10-15: Receive shared text as a new node ([#31](https://github.com/ChristianGeng/roam-graph-mobile/pull/31))

- Added: text shared from another app, for example an AI app, opens the
  capture screen as a new node.
- Closes [#15](https://github.com/ChristianGeng/roam-graph-mobile/issues/15). Released as v0.1.67.

## 2026-10-15: Safe writing next to Syncthing ([#30](https://github.com/ChristianGeng/roam-graph-mobile/pull/30))

- Added: new files are written through a temporary file and a rename.
  Syncthing conflict copies are listed.
- Closes [#13](https://github.com/ChristianGeng/roam-graph-mobile/issues/13). Released as v0.1.64.

## 2026-10-15: Link a new node to the current node ([#29](https://github.com/ChristianGeng/roam-graph-mobile/pull/29))

- Added: a new node can link to the node it was made from.
- Closes [#12](https://github.com/ChristianGeng/roam-graph-mobile/issues/12). Released as v0.1.59.

## 2026-10-15: Capture a new node ([#28](https://github.com/ChristianGeng/roam-graph-mobile/pull/28))

- Added: create a new node, named and written as org-roam does. The app
  asks for write access to the folder.
- Closes [#11](https://github.com/ChristianGeng/roam-graph-mobile/issues/11). Released as v0.1.59.

## 2026-10-15: Graph views from graph algorithms ([#27](https://github.com/ChristianGeng/roam-graph-mobile/pull/27))

- Added: the views Communities, Importance (PageRank and number of links)
  and Shortest path, computed as the org-roam MCP server computes them.
- Closes [#7](https://github.com/ChristianGeng/roam-graph-mobile/issues/7). Released as v0.1.59.

## 2026-10-15: Layouts for tablet and phone ([#26](https://github.com/ChristianGeng/roam-graph-mobile/pull/26))

- Added: on a tablet in landscape, the graph and the open note side by
  side; on a phone, one screen at a time.
- Closes [#16](https://github.com/ChristianGeng/roam-graph-mobile/issues/16). Released as v0.1.44.

## 2026-10-15: Open in Orgro ([#25](https://github.com/ChristianGeng/roam-graph-mobile/pull/25))

- Added: open a node's file in Orgro, read-only.
- Closes [#10](https://github.com/ChristianGeng/roam-graph-mobile/issues/10). Released as v0.1.41.

## 2026-10-15: Search ([#24](https://github.com/ChristianGeng/roam-graph-mobile/pull/24))

- Added: search nodes by title, alias and tag.
- Closes [#9](https://github.com/ChristianGeng/roam-graph-mobile/issues/9). Released as v0.1.36.

## 2026-10-15: Node view ([#23](https://github.com/ChristianGeng/roam-graph-mobile/pull/23))

- Added: a node's text rendered as Org, with its links and backlinks.
- Closes [#8](https://github.com/ChristianGeng/roam-graph-mobile/issues/8). Released as v0.1.33.

## 2026-10-15: Graph view ([#22](https://github.com/ChristianGeng/roam-graph-mobile/pull/22))

- Added: the graph, with the circular (circo) and force-directed layouts
  and the scopes of `org-roam-graph`.
- Closes [#6](https://github.com/ChristianGeng/roam-graph-mobile/issues/6). Released as v0.1.29.

## 2026-10-15: CI reports failing checks ([#21](https://github.com/ChristianGeng/roam-graph-mobile/pull/21))

- Fixed: failing analysis and tests now fail the build. No change in the
  app. Released as v0.1.29.

## 2026-10-15: The graph in org-roam's database format ([#20](https://github.com/ChristianGeng/roam-graph-mobile/pull/20))

- Added: the app keeps its index in an SQLite database with org-roam's
  tables, and updates only changed files. A "Rebuild index" button.
- Part of [#5](https://github.com/ChristianGeng/roam-graph-mobile/issues/5). Released as v0.1.23.

## 2026-10-13: Read nodes and links from the org files ([#19](https://github.com/ChristianGeng/roam-graph-mobile/pull/19))

- Added: the app reads org-roam nodes and links from the files, as
  org-roam does.
- Closes [#4](https://github.com/ChristianGeng/roam-graph-mobile/issues/4). Released as v0.1.19.

## 2026-10-11: Choose the org folder ([#18](https://github.com/ChristianGeng/roam-graph-mobile/pull/18))

- Added: choose the folder Syncthing fills, and keep access to it.
- Closes [#3](https://github.com/ChristianGeng/roam-graph-mobile/issues/3). Released as v0.1.9.

## 2026-10-11: First version ([#17](https://github.com/ChristianGeng/roam-graph-mobile/pull/17))

- Added: the app skeleton and the signed APK release, installed with
  Obtainium.
- Closes [#1](https://github.com/ChristianGeng/roam-graph-mobile/issues/1) and [#2](https://github.com/ChristianGeng/roam-graph-mobile/issues/2). Released as v0.1.4.
