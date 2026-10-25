# Changelog

What changed in the app, newest first. Every pull request adds one entry
at the top: the date it was merged, a short title and the pull request,
then a few lines on what changed for the user. The version is not written
here, because it is only known when the release is built: each release's
text on GitHub repeats the entries it contains, with its version. For the
entries before the changelog existed, the version is given at the end of
each entry.

## 2026-10-25: Mistral images work ([#177](https://github.com/ChristianGeng/roam-graph-mobile/pull/177))

- Fixed: "Create image" with Mistral said that the model did not run its image tool, although Mistral had made the image. The app now finds the image where Mistral puts it.

## 2026-10-24: Image model prices and help choosing models ([#175](https://github.com/ChristianGeng/roam-graph-mobile/pull/175))

- Added: image model lists show the provider's price per image, the lowest price with "from" where it varies, or token prices; missing prices are named. An optional price order puts the cheapest listed image prices first.
- Added: "Choosing a model" help, linked from AI and Settings, with suggestions for questions, agent edits, images and EU processing, using price classes.

Closes #169.

## 2026-10-24: Delete notes by hand ([#174](https://github.com/ChristianGeng/roam-graph-mobile/pull/174))

- Added: Delete note from the note menu, a graph node's long-press or right-click menu, and selected search results, with confirmation.
- Added: Choose whether incoming links become plain text or stay as links. Several selected notes are deleted in one action.
- Added: Undo a delete and its link changes together, from the message or Recent changes. Newer files stay unchanged and are named.

Closes #171.

## 2026-10-24: Quick-edit Undo for the note visit ([#173](https://github.com/ChristianGeng/roam-graph-mobile/pull/173))

- Changed: Undo is in the note view's bar. Each tap undoes one quick edit, newest first, for as long as you stay in the note. Leaving, opening an Edit-menu surface or an outside file change clears the steps.
- Fixed: quick-edit confirmations close after two seconds, without an action button.
- Fixed: link messages with Copy close after six seconds, whether or not another app can open the link.

Closes #170.

## 2026-10-24: Mistral images through an agent ([#165](https://github.com/ChristianGeng/roam-graph-mobile/pull/165))

- Fixed: "Create image" with Mistral said "Mistral sent no image, only text" with the prompt, because Mistral did not run its image tool. The app now makes an agent with the image tool at Mistral the first time ("Roam Graph images", one per image model), keeps its ID in the AI settings, and asks that agent for each image.
- Changed: when Mistral's answer only repeats the description, the message says "Mistral did not run its image tool".

Closes #163.

## 2026-10-23: Images with Mistral work ([#162](https://github.com/ChristianGeng/roam-graph-mobile/pull/162))

- Fixed: "Create image" (and the chat's images) with Mistral said "Mistral sent no image". The app now asks Mistral's image tool the way Mistral documents it (its Conversations API), without keeping the conversation on Mistral's servers. Follow-up to #126.
- Changed: when a model still answers with text only, the message shows that text.

## 2026-10-22: Hierarchical layout ([#161](https://github.com/ChristianGeng/roam-graph-mobile/pull/161))

- Added: a "Hierarchical (dot)" layout in the graph's View menu, as Graphviz's `dot` draws: the notes in layers from top to bottom, each link pointing down from the note that links, with few links crossing. Good for a hub and its sub-topics.
- "Graph layout at start" in Settings offers it too. On a graph too large to lay out in a few seconds, the force-directed layout is drawn instead, and a message says so.

Closes #155.

## 2026-10-22: Search inside a note ([#160](https://github.com/ChristianGeng/roam-graph-mobile/pull/160))

- Added: "Search in this note" in the node view's bar (Ctrl+F on the desktop) marks every match, upper and lower case alike, opens the sections they are in, and counts them; the arrows go from one to the next. "Only matching sections" folds the others away. Closing the search folds the sections as before.
- Changed: on a narrow screen, "New node from here" and "Open in Orgro" are in a "More" menu, so the bar fits.

Closes #152.

## 2026-10-22: Layout grouped by communities ([#159](https://github.com/ChristianGeng/roam-graph-mobile/pull/159))

- Added: a "Grouped by communities" layout in the graph's View menu: each community (the topics the "Communities" view colours) gets its own area, laid out force-directed inside, the largest first. Small communities and notes without links share one area at the end.
- "Graph layout at start" in Settings offers it too.

Closes #154.

## 2026-10-22: Buttons for headings and list items in "Edit text" ([#158](https://github.com/ChristianGeng/roam-graph-mobile/pull/158))

- Added: a row of buttons below the text in "Edit text": new heading, up or down a level, move up or down, new list item, checkbox on or off, and the next TODO state. They act on the line of the cursor or on the selected lines, as Org's commands do.
- A button that would change a property drawer or the heading above one does nothing and says why. Everything is saved, as before, with the diff.

Closes #151.

## 2026-10-22: Radial layout ([#157](https://github.com/ChristianGeng/roam-graph-mobile/pull/157))

- Added: a "Radial" layout in the graph's View menu: the selected note in the middle, the other notes on rings by how many links away they are, the notes reached from one note kept together. Notes not connected to it are drawn beside the rings.
- "Centre" in the More menu (and "Show in graph") draws the rings again around the selected note. "Graph layout at start" in Settings offers it too.

Closes #153.

## 2026-10-22: Tick checkboxes and change TODO states in the note view ([#156](https://github.com/ChristianGeng/roam-graph-mobile/pull/156))

- Added: tap a checkbox in a note to tick or untick it; the boxes and progress cookies above it follow. Slide a heading to the left for its next TODO state, or long-press it for the list of states (the note's `#+TODO:` keywords, or TODO and DONE).
- Saved at once without the diff, with Undo in the message. With `#+STARTUP: logdone`, a done heading gets a `CLOSED:` time.

Closes #150.

## 2026-10-22: Graph layouts in the View menu ([#144](https://github.com/ChristianGeng/roam-graph-mobile/pull/144))

- Changed: the graph's View menu has two groups, "Layout" (Circular, Force-directed) and "View" (Plain, Communities, PageRank, number of links, Shortest path), each with a check mark at the current one, then "About the layouts" and "About the views".
- Changed: the More menu keeps only Centre, Ask AI, Settings and Help. A layout chosen in the View menu is still remembered for "Last used".

Closes #143.

## 2026-10-22: SuperCollider source blocks in colour ([#148](https://github.com/ChristianGeng/roam-graph-mobile/pull/148))

- Added: `#+begin_src sclang` blocks are coloured, as `sclang-mode` colours them in Emacs: classes, symbols, `~` variables, keywords, numbers, strings, characters and comments (also nested `/* */`).

Closes #147.

## 2026-10-22: "Save as new node" in the chat: the AI makes the note ([#146](https://github.com/ChristianGeng/roam-graph-mobile/pull/146))

- Changed: "Save as new node" under a chat answer lets the AI make the note: a short, fitting title in the language of the answer, Org text without chat phrases, and links to the notes it used and to the note the chat was opened from.
- In agent mode the button sends that request as my message, and the AI makes the note itself, with "Undo all". In review and off mode the AI writes the title and text, and "New node" opens with them to check and save; if its answer cannot be read, the first line is the title, as before.

Closes #145.

## 2026-10-21: Web access for the AI chat ([#139](https://github.com/ChristianGeng/roam-graph-mobile/pull/139))

- Added: "Web access for the AI" in AI settings, off by default. With it on, the chat can read web pages (fetched from the phone, https only, never from the own network) and, with Anthropic, search the web; search words go to the provider.
- Added: "Most web searches for one message", 5 by default; each page read counts too.
- The AI names its sources as links, also in the notes it writes from web facts.

Closes #137.

## 2026-10-21: One tag field: chips and the existing tags ([#141](https://github.com/ChristianGeng/roam-graph-mobile/pull/141))

- Changed: in "Title, tags and aliases", "New node" and "Hidden from AI: tags", the chosen tags are chips with an x, and below them the graph's tags, the most used first with their number of notes, can be tapped. Typing filters them; space, comma, colon or Enter adds the typed tag.
- A tag that does not exist yet shows "New tag: …", so a typo is seen; characters Org does not allow in tags are refused.

Closes #140.

## 2026-10-21: Add links from the note view and the editor ([#136](https://github.com/ChristianGeng/roam-graph-mobile/pull/136))

- Added: "+" next to "Links" adds a link to another note on this note's "See also:" line; "+" next to "Backlinks" adds a link to this note on the other note's line. The diff comes first, as for every edit.
- Added: "Insert link" in "Edit text" puts a link at the cursor; selected text becomes its description.
- In the list of notes, text that is not a note's title can become a new note, as in Emacs's org-roam-node-insert, and the link goes to it.

Closes #135.

## 2026-10-20: Links removed show at once; trash icons for links and images ([#134](https://github.com/ChristianGeng/roam-graph-mobile/pull/134))

- Added: trash icons in the note view, on this note's links (a new "Links" list), on its backlinks and on its images. A removed link becomes its text; an image goes with its caption and prompt lines, and its file stays. The diff comes first, as for every edit.
- Changed: while the app is open, it checks the folder for changed files every 30 seconds, so notes changed in Emacs and brought by Syncthing show without leaving the app.

Closes #133.

## 2026-10-20: A broken connection no longer stops the AI ([#132](https://github.com/ChristianGeng/roam-graph-mobile/pull/132))

- When a request to the AI breaks off, or the provider is busy for a moment, the chat tries again by itself, after 2 and after 6 seconds, before it shows an error. An agent task with several steps no longer stops in the middle.
- The screen stays on while the AI works, so it does not lock during a request.

Closes #131.

## 2026-10-20: Images in the chat: the AI reads the notes, then draws ([#130](https://github.com/ChristianGeng/roam-graph-mobile/pull/130))

- In agent mode, ask the chat for an image, such as "an infographic of my training over the last 5 years for this note". The AI reads the notes first, writes the image prompt with the facts in it, and adds the image to the note with a caption it writes, and the prompt as a comment.
- The AI is shown the image, if its model can see images, and checks it. The chat now knows today's date.
- One image per message by default ("Most images the agent may make for one message" in AI settings). "Undo all changes of this message" takes the image out of the note.

Closes #129.

## 2026-10-19: Images with Mistral, and a provider for images of its own ([#128](https://github.com/ChristianGeng/roam-graph-mobile/pull/128))

- Added: "Create image" works with Mistral, through its built-in image tool (Mistral Medium by default). The image is downloaded only from Mistral's own servers. Mistral settings saved before get these defaults.
- Added: "Images with:" in AI settings. Images can come from another provider than the chat, with that provider's own key, image model and "EU only". By default it is the chat's provider, as before.
- With "EU only" on, Vercel AI Gateway now makes images with Gemini 2.5 Flash Image by default, as it is the only image model there with an EU route.
- "Create image" says which provider and model make the image, and whether that is in the EU, outside it, or not known.
- When an image model has no EU route and "EU only" is on, "Make this one outside the EU" makes this one image without the EU option. "EU only" stays on.

Closes #126. Closes #127.

## 2026-10-19: "Share graph with AI" removed ([#125](https://github.com/ChristianGeng/roam-graph-mobile/pull/125))

- Removed: "Share graph with AI" in the graph's "More" menu. It sent only titles, tags and links, with no note texts; the AI chat reads the graph and the notes itself.
- "Share with AI" for one note and for notes selected in search stays.

Closes #124.

## 2026-10-19: "Edit with AI" also changes the linked notes, after a plan ([#123](https://github.com/ChristianGeng/roam-graph-mobile/pull/123))

- "Edit with AI" has "Also the linked notes": the note, the notes that link to it and the notes it links to are sent, as far as AI may see them, so it can do tasks such as "remove all links to this note".
- The AI first says what it will do and which notes it will change. Nothing is changed until you tap "Go ahead"; "Back" keeps your instruction.
- Then all changes are reviewed together, one diff per note, and saved with "Save". If one of the notes changed since the AI read it, none is saved. The set can be undone as one, also later in "Recent AI changes".
- At most "Most notes one AI change set may edit" notes are sent; the plan says how many were left out.

Closes #122.

## 2026-10-19: Cheaper images with Qwen, and clearer image errors ([#121](https://github.com/ChristianGeng/roam-graph-mobile/pull/121))

- Added: "Create image" works with the Qwen provider too, with Qwen Image
  2.0 (about 0.035 USD per image).
- Added: the image model is told the note's title, so "an image for this
  note" works; a box turns it off.
- Fixed: with "EU only" on at Vercel, a model without an EU route now
  says so and names the ways out, instead of the gateway's error.
- Closes [#120](https://github.com/ChristianGeng/roam-graph-mobile/issues/120).

## 2026-10-18: The app for Windows and macOS, and a Linux installer ([#119](https://github.com/ChristianGeng/roam-graph-mobile/pull/119))

- Added: every release also carries the app for Windows
  (`-windows-x64.zip`) and macOS (`-macos.zip`), not signed yet; see
  docs/releases.md.
- Added: on Linux, `install.sh` in the package puts the app in the app
  menu, and `install.sh --update` installs the newest release.
- Part of [#116](https://github.com/ChristianGeng/roam-graph-mobile/issues/116).

## 2026-10-18: The app on Linux ([#118](https://github.com/ChristianGeng/roam-graph-mobile/pull/118))

- Added: a Linux build of the app with every release
  (`roam-graph-<version>-linux-x64.tar.gz`); see docs/releases.md. It
  reads the notes folder directly, and "Open in Emacs" opens a note at
  its heading with `emacsclient`, a command set in Settings.
- On Linux, links open in the browser, and "Share with AI" copies the
  text to the clipboard.
- Part of [#116](https://github.com/ChristianGeng/roam-graph-mobile/issues/116).

## 2026-10-18: Create images with AI ([#115](https://github.com/ChristianGeng/roam-graph-mobile/pull/115))

- Added: "Create image" in a note's edit menu. Describe the picture; the
  image model draws it; "Add to the note" saves it in the image folder
  and adds it to the note, where it shows inline with its description.
- Added: an image model per provider in AI settings, for Vercel AI
  Gateway, OpenRouter and Custom, and the folder for new images in
  Settings (`img` by default).
- Part of [#112](https://github.com/ChristianGeng/roam-graph-mobile/issues/112).

## 2026-10-18: Told when a chosen model is gone ([#114](https://github.com/ChristianGeng/roam-graph-mobile/pull/114))

- Added: AI settings mark a chosen model that is no longer in the
  provider's model list, and the chat says so when it starts, with a
  button to AI settings, instead of failing with the provider's error.
- Nothing is said offline or when the list cannot be fetched.
- Closes [#113](https://github.com/ChristianGeng/roam-graph-mobile/issues/113).

## 2026-10-18: The model list shows only models the chat can use ([#111](https://github.com/ChristianGeng/roam-graph-mobile/pull/111))

- Changed: "Choose model" in AI settings now lists only chat models that
  call tools, which the chat needs to read and change notes. Embedding,
  image, speech and similar models are hidden.
- Where a provider does not say which models call tools, its chat models
  are shown, marked "tools not known".
- "Also other models" still shows every model.
- Closes [#110](https://github.com/ChristianGeng/roam-graph-mobile/issues/110).

## 2026-10-17: Web links open in the browser ([#109](https://github.com/ChristianGeng/roam-graph-mobile/pull/109))

- Added: web links in notes and in the AI chat open in your browser,
  also plain addresses in the text; `mailto:` and `tel:` links open the
  mail or phone app, and `doi:` links open at doi.org.
- A short message names the address that opens, with "Copy".
- Images in notes are still shown in the note. `file:` links and other
  kinds of links are not opened.
- Closes [#108](https://github.com/ChristianGeng/roam-graph-mobile/issues/108).

## 2026-10-17: Reset a provider's models to the defaults ([#107](https://github.com/ChristianGeng/roam-graph-mobile/pull/107))

- Added: "Reset to the defaults" in AI settings, below the model fields,
  when the base URL, a model or "EU only" differs from the provider's
  defaults. It puts them back; Save keeps them.
## 2026-10-17: A default model for Vercel ([#105](https://github.com/ChristianGeng/roam-graph-mobile/pull/105))

- Changed: Vercel AI Gateway now starts with the model
  deepseek/deepseek-v4-pro, and with "EU only" off, which that model
  needs; it is processed outside the EU. Vercel is now listed with the
  providers outside the EU. For EU only, turn the switch on and use
  anthropic/claude-sonnet-5.5.
- A model or "EU only" choice you saved yourself stays.

## 2026-10-17: Edit one note with AI ([#104](https://github.com/ChristianGeng/roam-graph-mobile/pull/104))

- Added: "Edit with AI" in a note's edit menu. Type what to change, such
  as "fix the typos"; the AI rewrites only this note, and the change is
  saved only after you see it as a diff and tap Save.
- Parts of the note hidden from AI are not sent and stay as they are.
- Closes [#103](https://github.com/ChristianGeng/roam-graph-mobile/issues/103).
## 2026-10-17: No AI change lost from the log while it is trimmed ([#106](https://github.com/ChristianGeng/roam-graph-mobile/pull/106))

- Fixed: opening "Recent AI changes" while the AI was still changing notes
  could drop a change from the log when the log was trimmed, so "Undo
  these changes" undid only part of a message. Writing and trimming the
  log now run one after the other.

## 2026-10-17: Undo the AI's changes after the chat is closed ([#102](https://github.com/ChristianGeng/roam-graph-mobile/pull/102))

- Added: "Recent AI changes", the history button in the AI chat. It lists
  what the AI changed in the last 30 days, by message, with each note's
  change as a diff, and "Undo these changes" for each message.
- Changes made before this update are listed but cannot be undone there.
- Closes [#99](https://github.com/ChristianGeng/roam-graph-mobile/issues/99).
## 2026-10-17: Search the words inside notes ([#101](https://github.com/ChristianGeng/roam-graph-mobile/pull/101))

- Added: an "In the text" chip in Search finds notes by the words in
  their text, with a short snippet around the words. Accents and case do
  not matter.
- Added: the AI chat can search the text too, but never finds notes or
  headings hidden from AI.
- The index is rebuilt once after the update.
- Closes [#98](https://github.com/ChristianGeng/roam-graph-mobile/issues/98).
## 2026-10-17: Change a note's title, tags and aliases ([#100](https://github.com/ChristianGeng/roam-graph-mobile/pull/100))

- Added: "Title, tags and aliases" in the node view's Edit menu. The ID
  and the file name stay, so every link still works.
- Added: in agent mode, the AI can rename notes and set their tags and
  aliases, undoable as its other changes.
- Closes [#97](https://github.com/ChristianGeng/roam-graph-mobile/issues/97).

## 2026-10-17: The AI can delete notes when you ask ([#96](https://github.com/ChristianGeng/roam-graph-mobile/pull/96))

- Added: in agent mode, the AI deletes a note, or a heading with its
  subtree, when you ask it to. Links to it in your other notes become
  plain text, so none points nowhere. "Undo all" brings everything back.
- Closes [#93](https://github.com/ChristianGeng/roam-graph-mobile/issues/93).

## 2026-10-17: Copy answers and tool results in the chat ([#95](https://github.com/ChristianGeng/roam-graph-mobile/pull/95))

- Added: a Copy button on every answer of the AI chat, on opened tool
  calls (the call with its result) and on errors; answers can also be
  selected.
- Closes [#94](https://github.com/ChristianGeng/roam-graph-mobile/issues/94).

## 2026-10-17: Choose a light or dark theme ([#92](https://github.com/ChristianGeng/roam-graph-mobile/pull/92))

- Added: Settings, "Theme": System (as Android is set), Light or Dark.
- Changed: in the dark theme, the graph's community colours are lighter,
  so they show well on the dark background.
- Closes [#90](https://github.com/ChristianGeng/roam-graph-mobile/issues/90).

## 2026-10-17: The start layout is never missed ([#91](https://github.com/ChristianGeng/roam-graph-mobile/pull/91))

- Fixed: the graph could start with the default layout once, when it
  opened before the settings were read; and a layout chosen in the More
  menu in that moment could be replaced by the saved one.
- Closes [#81](https://github.com/ChristianGeng/roam-graph-mobile/issues/81).

## 2026-10-17: Agent mode: the AI changes notes itself ([#89](https://github.com/ChristianGeng/roam-graph-mobile/pull/89))

- Added: in the chat, the AI can create notes, add to them, change their
  text and link them, without a tap per change. Afterwards the chat shows
  what changed, each change as a diff, and "Undo all changes of this
  message".
- Added: AI settings, "Let the AI change notes": Off, Review each change
  first, or Agent (the default), and the most changes per message.
- Closes [#82](https://github.com/ChristianGeng/roam-graph-mobile/issues/82).

## 2026-10-17: The AI proposes edits, you review them ([#88](https://github.com/ChristianGeng/roam-graph-mobile/pull/88))

- Added: in the chat, the AI can propose an edit of a note, or a change set
  of edits to several notes. Each shows as a diff; nothing is saved until
  you accept it, and a saved change set can be undone together.
- Added: text shared from an AI app can be added to, or replace the text
  of, an existing node, again through the diff.
- Closes [#39](https://github.com/ChristianGeng/roam-graph-mobile/issues/39) and [#76](https://github.com/ChristianGeng/roam-graph-mobile/issues/76).

## 2026-10-17: Edit a node's text ([#87](https://github.com/ChristianGeng/roam-graph-mobile/pull/87))

- Added: "Edit text" in the node view's Edit menu. The ID, the property
  drawer and the title or heading line stay as they are; "Review" shows
  what changes, and only "Save" there writes, over the version you opened.
- Closes [#37](https://github.com/ChristianGeng/roam-graph-mobile/issues/37).

## 2026-10-17: See what an edit changes, and restore earlier versions ([#86](https://github.com/ChristianGeng/roam-graph-mobile/pull/86))

- Added: "Earlier versions" in the node view's Edit menu: the versions the
  app kept before each edit, newest first. Restoring one first shows, line
  by line, what it changes in the note as it is now.
- Closes [#38](https://github.com/ChristianGeng/roam-graph-mobile/issues/38).

## 2026-10-17: Add text to a node ([#85](https://github.com/ChristianGeng/roam-graph-mobile/pull/85))

- Added: "Add to this node" in the node view's Edit menu. The text goes to
  the end of the note, or of the heading's section, and is saved safely
  over the note as it is now, so what the laptop wrote meanwhile stays.
- Closes [#36](https://github.com/ChristianGeng/roam-graph-mobile/issues/36).

## 2026-10-17: Mistral answers after tool calls ([#84](https://github.com/ChristianGeng/roam-graph-mobile/pull/84))

- Fixed: with the Mistral preset, the answer after tool calls was not
  shown, and a follow-up failed with HTTP 400.
- Changed: an answer without text says "The model sent no text.", and
  HTTP 400 errors show the provider's message first.
- Closes [#79](https://github.com/ChristianGeng/roam-graph-mobile/issues/79).

## 2026-10-17: Choose the AI model from the provider's list ([#83](https://github.com/ChristianGeng/roam-graph-mobile/pull/83))

- Added: "Choose model" next to the model fields in the AI settings. It
  fetches the provider's model list and shows it searchable, with tool
  support, prices and EU routes where the list gives them.
- Closes [#75](https://github.com/ChristianGeng/roam-graph-mobile/issues/75).

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
