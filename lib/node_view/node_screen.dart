import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../ai/ai_settings.dart';
import '../ai/chat_list_screen.dart';
import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../capture/share_out.dart';
import '../edit/add_link.dart';
import '../edit/ai_edit_screen.dart';
import '../edit/append_screen.dart';
import '../edit/edit_screen.dart';
import '../edit/structure_edits.dart';
import '../edit/delete_dialog.dart';
import '../edit/history_screen.dart';
import '../edit/image_screen.dart';
import '../edit/meta_screen.dart';
import '../edit/note_editor.dart';
import '../edit/org_toggles.dart';
import '../edit/save_messages.dart';
import '../edit/remove_link.dart';
import '../edit/unlink.dart';
import '../graph/ai_share.dart';
import '../graph/backlinks.dart';
import '../graph/roam_graph.dart';
import '../graph_view/node_memory.dart';
import '../platform/error_text.dart';
import '../settings/view_settings.dart';
import 'folding.dart';
import 'heading_actions.dart';
import 'heading_link.dart';
import 'join_lines.dart';
import 'quick_edits.dart';
import 'scripts.dart';
import 'latex.dart';
import 'mermaid.dart';
import 'src_languages.dart';
import '../search/search_screen.dart';
import 'note_images.dart';
import 'note_search.dart';
import 'share_note.dart';
import 'web_links.dart';
import '../platform/desktop.dart';

/// Reads a note's text, by its path relative to `roam/`; null if it cannot
/// be read.
typedef NoteReader = Future<String?> Function(String path);

/// What happened when a note was to be opened in another app.
enum OpenResult { opened, noApp, noFile }

/// Opens the note [path] (relative to `roam/`) in another app: one chosen
/// in Android's app chooser (#218), or Emacs on the desktop (#116), there
/// at [line].
typedef NoteOpener = Future<OpenResult> Function(String path, {int line});

/// Shows a node as formatted Org (#8): a file node's whole file, a heading
/// node's heading with its subtree. `id:` links open the linked node on a
/// new page, so Back returns to this one. Below the text are the
/// backlinks.
///
/// [graph] follows the index; when it changes, the file is read again.
class NodeScreen extends StatefulWidget {
  const NodeScreen({
    super.key,
    required this.graph,
    required this.id,
    required this.readNote,
    this.files,
    required this.nodeMemory,
    this.onShowInGraph,
    this.openElsewhere,
    this.onOpenNode,
    this.onOpenHeading,
    this.heading,
    this.onBack,
    this.writer,
    this.shareText = shareTextOut,
    this.shareFiles = shareFilesOut,
    this.openUrl = openUrlOnDevice,
    this.help = false,
    this.visitBoundary = 0,
  });

  final ValueListenable<RoamGraph> graph;
  final String id;
  /// A graph editing surface ends the side pane's quick-edit visit even
  /// when the node ID stays the same (#171).
  final int visitBoundary;

  final NoteReader readNote;

  /// The folder's other files, for images in notes (#46); without
  /// them, image links are shown as text.
  final NoteFiles? files;
  final NodeMemory nodeMemory;

  /// Opens the node's file in another app; the button is hidden when null.
  final NoteOpener? openElsewhere;

  /// Opens another node. When null, it opens on a new page; the side pane
  /// of the tablet layout (#16) shows it in place instead.
  final void Function(BuildContext context, String id)? onOpenNode;

  /// Opens another node at a heading (#211), as [onOpenNode] does. When
  /// null, a link to a heading opens the node at its top in the side
  /// pane.
  final void Function(BuildContext context, String id, NodeHeading heading)?
      onOpenHeading;

  /// The heading to go to when the node opens (#211): unfolded and scrolled
  /// to. A new object (not an equal one) makes the screen go there again.
  final NodeHeading? heading;

  /// Goes back to the node shown before, in the side pane; null when there
  /// is none. With [onOpenNode], the app bar has no other back button: the
  /// pane is part of the graph's page.
  final VoidCallback? onBack;

  /// Writes new notes; with it, "New node from here" captures a node that
  /// links to this one (#12).
  final NoteWriter? writer;

  /// Sends text to an AI app (#41); tests replace it.
  final TextSharer shareText;

  /// Sends pictures and files to another app (#209); tests replace it.
  final FileSharer shareFiles;

  /// Opens web, mail and phone links in another app (#108); tests replace
  /// it.
  final UrlOpener openUrl;

  /// A help page (#62): no search and no AI menu, which would act on the
  /// help instead of my notes.
  final bool help;

  /// Shows the node [id] in the graph view (#6); the button is hidden when
  /// null.
  final void Function(BuildContext context, String id)? onShowInGraph;

  /// Opens the node [id] on a new page, with the same graph and callbacks.
  static Future<void> open(
    BuildContext context, {
    required ValueListenable<RoamGraph> graph,
    required String id,
    required NoteReader readNote,
    NoteFiles? files,
    required NodeMemory nodeMemory,
    void Function(BuildContext context, String id)? onShowInGraph,
    NoteOpener? openElsewhere,
    NoteWriter? writer,
    TextSharer shareText = shareTextOut,
    FileSharer shareFiles = shareFilesOut,
    UrlOpener openUrl = openUrlOnDevice,
    bool help = false,
    NodeHeading? heading,
  }) {
    nodeMemory.remember(id);
    return Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => NodeScreen(
          graph: graph,
          id: id,
          heading: heading,
          readNote: readNote,
          files: files,
          nodeMemory: nodeMemory,
          onShowInGraph: onShowInGraph,
          openElsewhere: openElsewhere,
          writer: writer,
          shareText: shareText,
          shareFiles: shareFiles,
          openUrl: openUrl,
          help: help,
        ),
      ),
    );
  }

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

typedef _QuickUndoStep = ({
  NoteWriter writer,
  String file,
  String historyKey,
  String before,
  String after,
});

class _NodeScreenState extends State<NodeScreen> {
  late Future<String?> _text;

  /// The text shown last, and the node it belongs to: kept on screen while
  /// the note is read again, so the page does not jump to the top.
  String? _shown;
  String? _shownId;

  /// The context below the note's [OrgController], to read and keep the
  /// folding over a quick edit (#150).
  BuildContext? _orgContext;

  /// The folding of each section before a quick edit, to restore once the
  /// note is read again with [text], the text the edit saved.
  ({String text, List<OrgVisibilityState> states})? _keptFolding;

  /// Whether a quick edit is being saved; taps wait for it.
  var _quickBusy = false;

  /// Quick edits of this visit, newest last. Restores still use the
  /// editor's fresh base and hash check, and keep their own history.
  final _undoSteps = <_QuickUndoStep>[];
  var _visit = 0;

  /// The note as last drawn, for the actions on its headings (#217); null
  /// when it cannot be changed here.
  _Headings? _headings;

  /// The number of the current heading (#217): the one last clicked or
  /// pressed, which the desktop's shortcuts change.
  final _current = ValueNotifier<int?>(null);
  final _keysFocus = FocusNode(debugLabel: 'note');

  // Search inside the note (#152).
  var _searching = false;
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode();
  RegExp? _searchPattern;
  var _onlyMatching = false;

  /// The marks of the search on screen, in reading order, and the one
  /// chosen with "Next match" or "Previous match".
  final _hits = ValueNotifier<List<SearchResultKey>>(const []);

  /// Not state of this page: a rebuild of the note would make new marks
  /// with new keys, and the chosen one would be lost.
  final _selectedHit = ValueNotifier<SearchResultKey?>(null);

  /// The folding before the search, to restore when it closes, if the
  /// note is still [text].
  ({String text, List<OrgVisibilityState> states})? _foldingBeforeSearch;

  /// The heading to open the note at (#211), until it has been dealt with.
  NodeHeading? _pendingHeading;

  RoamNode? get _node => widget.graph.value.nodes[widget.id];

  @override
  void initState() {
    super.initState();
    _pendingHeading = widget.heading;
    _text = _read();
    widget.graph.addListener(_graphChanged);
  }

  @override
  void dispose() {
    widget.graph.removeListener(_graphChanged);
    _searchText.dispose();
    _searchFocus.dispose();
    _hits.dispose();
    _selectedHit.dispose();
    _current.dispose();
    _keysFocus.dispose();
    super.dispose();
  }

  Future<String?> _read() async {
    final node = _node;
    return node == null ? null : widget.readNote(node.file);
  }

  /// The file may have changed with the index: read it again.
  void _graphChanged() {
    _readAgain();
  }

  /// [text] split at the first `::`: the path, and the search option.
  (String, String?) _splitOption(String text) {
    final i = text.indexOf('::');
    return i < 0 ? (text, null) : (text.substring(0, i), text.substring(i + 2));
  }

  void _openLink(OrgLink link) {
    final location = link.location;
    if (location.startsWith('id:')) {
      final (id, option) = _splitOption(location.substring(3));
      _openId(id.trim(), heading: NodeHeading.fromOption(option));
    } else if (location.startsWith('file:') &&
        _openFileLink(location.substring(5))) {
      // Opened a note of the index (#211).
    } else if (location.startsWith('*') || location.startsWith('#')) {
      // A heading of this note that Org's own search did not find.
      final heading = NodeHeading.fromOption(location);
      final orgContext = _orgContext;
      if (heading == null || orgContext == null || !orgContext.mounted) return;
      final target = findHeading(OrgController.of(orgContext).root, heading);
      if (target == null) {
        _tell(heading.missingMessage);
      } else {
        _showHeadingHere(target, heading);
      }
    } else if (externalLinkTarget(location) case final uri?) {
      // Web, mail and phone links open in their app (#108).
      openExternalLink(context, uri, widget.openUrl);
    } else {
      _tell('This app opens id:, web, mail and phone links, not '
          '"$location".');
    }
  }

  /// A `file:` link ([rest] is the text after `file:`) to a note of the
  /// index: opens it, at its heading if the link names one. False for any
  /// other file.
  bool _openFileLink(String rest) {
    final node = _node;
    if (node == null) return false;
    final (path, option) = _splitOption(rest);
    final resolved = resolveNotePath(node.file, path.trim());
    if (resolved == null) return false;
    for (final candidate in widget.graph.value.nodes.values) {
      if (candidate.isFile && candidate.file == resolved) {
        _openId(candidate.id, heading: NodeHeading.fromOption(option));
        return true;
      }
    }
    return false;
  }

  /// A link to a heading in the shown text itself: `[[id:...]]`,
  /// `[[*Heading]]` or `[[#custom-id]]`, which Org reports as a section
  /// ([section] is the section the link names; [searchOption] the part
  /// after `::`). A heading that is a node opens as its own node; another
  /// heading is unfolded and scrolled to in the shown note (#211).
  void _openSection(OrgTree section, {String? searchOption}) {
    final id = section.ids.firstOrNull;
    final heading = NodeHeading.fromOption(searchOption);
    if (heading != null) {
      if (id != null && id != widget.id) {
        _openId(id, heading: heading);
        return;
      }
      final target = findHeading(section, heading);
      if (target == null) {
        _tell(heading.missingMessage);
      } else {
        _showHeadingHere(target, heading);
      }
    } else if (id != null) {
      _openId(id);
    } else if (section is OrgSection) {
      _showHeadingHere(section, null);
    }
  }

  /// Unfolds [target] in the note on screen and scrolls to it. [heading] is
  /// what the link said, for the message when [target] is not on screen.
  void _showHeadingHere(OrgSection target, NodeHeading? heading) {
    final orgContext = _orgContext;
    if (orgContext == null || !orgContext.mounted) return;
    if (!unfoldHeading(orgContext, target)) {
      _tell(heading?.missingMessage ??
          'This heading is no longer in this note.');
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && orgContext.mounted) revealHeading(orgContext, target);
    });
  }

  @override
  void didUpdateWidget(NodeScreen old) {
    super.didUpdateWidget(old);
    if (old.graph != widget.graph) {
      old.graph.removeListener(_graphChanged);
      widget.graph.addListener(_graphChanged);
    }
    // The side pane shows another node.
    if (old.id != widget.id || old.visitBoundary != widget.visitBoundary) {
      _endVisit(duringBuild: true);
    }
    if (old.id != widget.id || old.graph != widget.graph) _text = _read();
    // A link to a heading (#211): a new heading object is a new link; the
    // heading of an earlier link does not follow the screen to another node.
    if (widget.heading != null && !identical(old.heading, widget.heading)) {
      _pendingHeading = widget.heading;
    } else if (widget.heading == null || old.id != widget.id) {
      _pendingHeading = null;
    }
    // A search belongs to the note it was made in.
    if (old.id != widget.id && _searching) {
      _searching = false;
      _searchText.clear();
      _searchPattern = null;
      _onlyMatching = false;
      _foldingBeforeSearch = null;
      _selectedHit.value = null;
    }
  }

  /// The folding of each section of the note on screen, or null.
  List<OrgVisibilityState>? _currentFolding() {
    final orgContext = _orgContext;
    if (orgContext == null || !orgContext.mounted) return null;
    final controller = OrgController.of(orgContext);
    return [
      for (final section in sectionsOf(controller.root))
        controller.nodeFor(section).visibility.value,
    ];
  }

  /// Opens the search bar (#152), or puts the cursor back in it.
  void _startSearch() {
    if (_node == null) return;
    if (_searching) {
      _searchFocus.requestFocus();
      return;
    }
    final shown = _shown, folding = _currentFolding();
    setState(() {
      _searching = true;
      _foldingBeforeSearch = shown == null || folding == null
          ? null
          : (text: shown, states: folding);
    });
    // The note may hold the focus (#217); autofocus only takes an empty
    // one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searching) _searchFocus.requestFocus();
    });
  }

  void _searchChanged(String query) {
    _selectedHit.value = null;
    setState(() => _searchPattern = notePattern(query));
  }

  /// Chooses the next ([step] 1) or previous ([step] -1) match, around the
  /// ends, and scrolls to it.
  void _moveHit(int step) {
    final hits = hitsInOrder(_hits.value);
    if (hits.isEmpty) return;
    final selected = _selectedHit.value;
    final i = selected == null ? -1 : hits.indexOf(selected);
    final next = i < 0
        ? (step > 0 ? 0 : hits.length - 1)
        : (i + step + hits.length) % hits.length;
    selected?.currentState?.selected = false;
    final hit = hits[next];
    hit.currentState?.selected = true;
    _selectedHit.value = hit;
    final hitContext = hit.currentContext;
    if (hitContext != null && hitContext.mounted) {
      Scrollable.ensureVisible(hitContext,
          alignment: 0.5, duration: const Duration(milliseconds: 150));
    }
  }

  /// Closes the search: the marks go, and the sections are folded as
  /// before it, if the note did not change meanwhile.
  void _closeSearch() {
    if (!_searching) return;
    final before = _foldingBeforeSearch;
    final shown = _shown;
    setState(() {
      _searching = false;
      _searchText.clear();
      _searchPattern = null;
      _onlyMatching = false;
      _foldingBeforeSearch = null;
    });
    _selectedHit.value = null;
    _hits.value = const [];
    if (before == null || before.text != shown) return;
    // After the controller has dropped the search's folding.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final orgContext = _orgContext;
      if (!mounted || orgContext == null || !orgContext.mounted) return;
      final controller = OrgController.of(orgContext);
      final sections = sectionsOf(controller.root);
      if (sections.length != before.states.length) return;
      for (final (i, section) in sections.indexed) {
        controller.setVisibilityOf(section, (_) => before.states[i]);
      }
    });
  }

  /// The app bar while searching: the field, the matches, and "Only
  /// matching sections".
  PreferredSizeWidget _searchBar() => AppBar(
        leading: IconButton(
          tooltip: 'Close search',
          icon: const Icon(Icons.close),
          onPressed: _closeSearch,
        ),
        title: TextField(
          key: const ValueKey('note-search'),
          controller: _searchText,
          focusNode: _searchFocus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _searchChanged,
          onSubmitted: (_) {
            _moveHit(1);
            _searchFocus.requestFocus();
          },
          decoration: const InputDecoration(
            hintText: 'Search in this note',
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Previous match',
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: () => _moveHit(-1),
          ),
          IconButton(
            tooltip: 'Next match',
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: () => _moveHit(1),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_hits, _selectedHit]),
                    builder: (context, _) => Text(
                      _searchPattern == null
                          ? ''
                          : hitCount(_hits.value, _selectedHit.value),
                      key: const ValueKey('note-search-count'),
                    ),
                  ),
                ),
                const Text('Only matching sections'),
                Switch(
                  key: const ValueKey('only-matching'),
                  value: _onlyMatching,
                  onChanged: (value) {
                    _selectedHit.value = null;
                    setState(() => _onlyMatching = value);
                  },
                ),
              ],
            ),
          ),
        ),
      );

  void _openId(String id, {NodeHeading? heading}) {
    if (!widget.graph.value.nodes.containsKey(id)) {
      _tell('There is no node with the ID $id.', error: true);
      return;
    }
    _endVisit();
    if (widget.onOpenNode case final open?) {
      widget.nodeMemory.remember(id);
      if (heading != null && widget.onOpenHeading != null) {
        widget.onOpenHeading!(context, id, heading);
      } else {
        open(context, id);
      }
      return;
    }
    NodeScreen.open(
      context,
      graph: widget.graph,
      id: id,
      heading: heading,
      readNote: widget.readNote,
      files: widget.files,
      nodeMemory: widget.nodeMemory,
      onShowInGraph: widget.onShowInGraph,
      openElsewhere: widget.openElsewhere,
      writer: widget.writer,
      shareText: widget.shareText,
      openUrl: widget.openUrl,
      help: widget.help,
    );
  }

  /// Captures a new node that links to [node] (#12), and opens it.
  Future<void> _capture(NoteWriter writer, RoamNode node) async {
    final id = await CaptureScreen.open(
      context,
      writer,
      graph: widget.graph.value,
      linkTo: (id: node.id, title: node.displayTitle),
    );
    if (id != null && mounted) _openId(id);
  }

  /// Adds text at the end of [node] (#36). The index changes after the
  /// save, so the note is read again and shows the text.
  Future<void> _append(NoteWriter writer, RoamNode node) async {
    _endVisit();
    final message = await AppendScreen.open(context, writer, node);
    if (message != null && mounted) _tell(message);
  }

  /// Makes an image with the AI and adds it to this note (#112). Not for a
  /// note hidden from AI.
  Future<void> _createImage(NoteWriter writer, RoamNode node) async {
    _endVisit();
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return;
    if (settings.visibility.hides(node)) {
      _tell('This note is hidden from AI, so no image is made for it.');
      return;
    }
    final message = await ImageScreen.open(context, writer, node);
    if (message != null && mounted) _tell(message);
  }

  /// Changes this one note by an instruction to the AI, after a diff
  /// (#103). Not for a note hidden from AI.
  Future<void> _aiEdit(NoteWriter writer, RoamNode node) async {
    _endVisit();
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return;
    if (settings.visibility.hides(node)) {
      _tell('This note is hidden from AI, so the AI cannot edit it.');
      return;
    }
    final message =
        await AiEditScreen.open(context, writer, node, widget.graph.value);
    if (message != null && mounted) _tell(message);
  }

  /// Edits the text of [node] (#37); the diff (#38) comes before saving.
  Future<void> _edit(NoteWriter writer, RoamNode node) async {
    _endVisit();
    final message = await EditScreen.open(context, writer, node,
        graph: widget.graph.value);
    if (message != null && mounted) _tell(message);
  }

  Future<void> _history(NoteWriter writer, RoamNode node) async {
    _endVisit();
    await HistoryScreen.open(context, writer, node);
  }

  /// The writer, when this view may change notes: not for help pages.
  NoteWriter? get _editWriter => switch (widget.writer) {
        final writer? when writer.editor != null && !widget.help => writer,
        _ => null,
      };

  String _titleOf(String id) =>
      widget.graph.value.nodes[id]?.displayTitle ?? id;

  /// Removes [link], from this note or from the note of a backlink, after
  /// the diff (#133). The link becomes its description, so no text is
  /// lost.
  Future<void> _removeLink(NoteWriter writer, RoamLink link) async {
    final from = _titleOf(link.source), to = _titleOf(link.dest);
    final message = await changeNote(
      context,
      writer,
      file: link.file,
      title: 'Remove the link to $to from $from',
      change: (text) =>
          withoutIdLink(text, link.dest, line: link.line, pos: link.pos),
      done: 'Removed the link to $to from $from; its text stays.',
      saveLabel: 'Remove',
    );
    if (message != null && mounted) _tell(message);
  }

  /// Removes the image [link] from [node], with its caption and prompt
  /// lines, after the diff (#133). The image file stays.
  Future<void> _removeImage(
      NoteWriter writer, RoamNode node, OrgLink link) async {
    final path = linkedImagePath(node.file, link.location) ?? link.location;
    final message = await changeNote(
      context,
      writer,
      file: node.file,
      title: 'Remove the image from ${node.displayTitle}',
      change: (text) => withoutImageLink(text, link.location),
      done: 'Removed the image from ${node.displayTitle}. The file $path '
          'stays in the folder.',
      saveLabel: 'Remove',
    );
    if (message != null && mounted) _tell(message);
  }

  /// The node viewed last, to offer first in the list of notes.
  Future<RoamNode?> _lastViewed() async =>
      widget.graph.value.nodes[await widget.nodeMemory.lastNode()];

  /// "+" next to "Links" (#135): a link to the chosen note, or to a new
  /// one, on this note's "See also:" line, after the diff.
  Future<void> _addLink(NoteWriter writer, RoamNode node) async {
    final proposed = await _lastViewed();
    if (!mounted) return;
    final target = await chooseLinkTarget(context, writer, widget.graph.value,
        proposed: proposed,
        excluded: {node.id},
        title: 'Link ${node.displayTitle} to',
        tell: _tell);
    if (target == null || !mounted) return;
    await addSeeAlso(context, writer, from: node, to: target, tell: _tell);
  }

  /// "+" next to "Backlinks" (#135): a link to this note on the chosen
  /// note's "See also:" line, after the diff; for hub notes.
  Future<void> _addBacklink(NoteWriter writer, RoamNode node) async {
    final proposed = await _lastViewed();
    if (!mounted) return;
    final target = await chooseLinkTarget(context, writer, widget.graph.value,
        proposed: proposed,
        excluded: {node.id},
        title: 'Link to ${node.displayTitle} from',
        tell: _tell);
    if (target == null || !mounted) return;
    // A new note is in the graph once it is indexed.
    final from = widget.graph.value.nodes[target.id];
    if (from == null) {
      _tell('The new note roam/${target.newFile} is not indexed yet; add the '
          'link after the next scan.');
      return;
    }
    await addSeeAlso(context, writer,
        from: from,
        to: (id: node.id, title: node.displayTitle, newFile: null),
        tell: _tell);
  }

  /// Changes the node's title, tags and aliases (#97).
  Future<void> _meta(NoteWriter writer, RoamNode node) async {
    _endVisit();
    final message = await MetaScreen.open(context, writer, node,
        graph: widget.graph.value);
    if (message != null && mounted) _tell(message);
  }

  /// Opens the node's file in an app chosen in Android's app chooser, at
  /// the top: an Android intent cannot name a heading (decision 6). On the
  /// desktop in Emacs, at the node's line (#116).
  Future<void> _openElsewhere(NoteOpener open, RoamNode node) async {
    final result = await open(node.file, line: node.line);
    if (!mounted) return;
    switch (result) {
      case OpenResult.opened:
        if (!node.isFile && !isDesktop) {
          _tell('Other apps open the file at the top.');
        }
      case OpenResult.noApp:
        _tell(isDesktop
            ? 'Emacs could not be started. Check the Emacs command in '
                'Settings.'
            : 'No app on this phone opens Org files.');
      case OpenResult.noFile:
        _tell('Could not find ${node.file} in the folder.',
            error: true);
    }
  }

  /// Shares [node] with an AI app (#41): its text as shown here, with its
  /// links and backlinks.
  Future<void> _shareWithAi(RoamNode node) async {
    // The saved settings, once loaded, so no saved hidden tag is missed.
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return;
    final visibility = settings.visibility;
    if (visibility.hides(node)) {
      final tags = node.tags.where(visibility.hiddenTags.contains);
      _tell('This note is hidden from AI by its tag '
          '${tags.map((t) => ':$t:').join(' ')}, so it is not shared. '
          'The hidden tags are in AI settings.');
      return;
    }
    final file = await _text;
    if (!mounted) return;
    // The file may have a hidden tag the index does not know yet.
    if (file != null && visibility.hidesInText(node, file)) {
      _tell('This note is now hidden from AI by its tags, so it is not '
          'shared.');
      return;
    }
    final text =
        nodesForAi(widget.graph.value, [(node, file)], visibility: visibility);
    if (text.length > maxShareLength) {
      _tell('This note is too large to share at once '
          '(${text.length ~/ 1000} KB).');
      return;
    }
    try {
      await widget.shareText(text, subject: node.displayTitle);
    } on PlatformException catch (e) {
      if (mounted) {
        _tell('Could not share the note: ${e.message ?? e.code}',
            error: true);
      }
    }
  }

  /// Asks how to share [node] and sends it to another app (#209): as
  /// text, as text with its images, or as an Org file. A note hidden from AI
  /// is shared too: this is the user's own action.
  Future<void> _shareNote(RoamNode node) async {
    final kind = await askShareKind(context);
    if (kind == null || !mounted) return;
    final file = await _text;
    if (!mounted) return;
    if (file == null) {
      _tell('Could not read ${node.file}.', error: true);
      return;
    }
    final org = nodeText(node, file);
    if (org == null) {
      _tell('The heading is no longer in ${node.file}; the file changed '
          'since the app read it.');
      return;
    }
    final title = node.displayTitle;
    try {
      switch (kind) {
        case ShareNoteKind.text:
          await widget.shareText(noteAsText(title, org, isFile: node.isFile),
              subject: title);
          if (isDesktop && mounted) _tell('Copied', short: true);
        case ShareNoteKind.textWithImages:
          final text = noteAsText(title, org, isFile: node.isFile);
          final files = widget.files;
          final found = files == null
              ? (images: <OutFile>[], unread: 0)
              : await noteImageFiles(files, node.file, org);
          if (!mounted) return;
          if (found.unread > 0) {
            _tell('${found.unread} image${found.unread == 1 ? '' : 's'} '
                'could not be read and ${found.unread == 1 ? 'is' : 'are'} '
                'not shared.');
          }
          if (found.images.isEmpty) {
            await widget.shareText(text, subject: title);
          } else {
            await widget.shareFiles(found.images, text: text, subject: title);
          }
        case ShareNoteKind.orgFile:
          await widget.shareFiles([orgFileOf(title, org)], subject: title);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        _tell('Could not share the note: ${e.message ?? e.code}', error: true);
      }
    } on FileSystemException catch (e) {
      if (mounted) _tell('Could not share the note: ${e.message}', error: true);
    }
  }

  /// Opens the chat list about [node] (#215): with a new chat above it
  /// that starts with this note ([newChat], #60), or the list only. The
  /// chats about this note come first.
  Future<void> _askAi(RoamNode node, {required bool newChat}) =>
      ChatListScreen.open(
        context,
        graph: widget.graph,
        readNote: widget.readNote,
        startNode: node,
        openNewChat: newChat,
        aboutStartNode: true,
        writer: widget.writer,
        searchText: widget.files?.searchText,
        // On a page above the chat, also from the side pane (#16).
        openNode: (chatContext, id) => NodeScreen.open(
          chatContext,
          graph: widget.graph,
          id: id,
          readNote: widget.readNote,
          files: widget.files,
          nodeMemory: widget.nodeMemory,
          onShowInGraph: widget.onShowInGraph,
          openElsewhere: widget.openElsewhere,
          writer: widget.writer,
          shareText: widget.shareText,
          openUrl: widget.openUrl,
        ),
        openUrl: widget.openUrl,
      );

  /// A tap on a list item's checkbox (#150): switches it and saves.
  /// [shown] is the text [document] was parsed from.
  Future<void> _toggleCheckbox(NoteWriter writer, RoamNode node, String shown,
      OrgDocument document, OrgListItem item) async {
    final index = listItemIndex(document, item);
    if (index == null) return;
    String? description;
    await _quickChange(writer, node, shown,
        change: (text) => toggleCheckbox(text, index,
            describe: (d) => description = d),
        done: () => description ?? 'Changed the checkbox.');
  }

  /// A long press on a heading (#150), or a TODO action of its menu
  /// (#217): the list of TODO states to choose.
  Future<void> _chooseTodo(int index) async {
    final h = _headings;
    if (h == null || index >= h.sections.length) return;
    final chosen = await chooseTodoState(context,
        states: todoStatesOf(h.document),
        current: h.sections[index].headline.keyword?.value);
    if (chosen == null || !mounted || !identical(h, _headings)) return;
    await _setTodo(h.writer, h.node, h.text, index, chosen.keyword);
  }

  Future<void> _setTodo(NoteWriter writer, RoamNode node, String shown,
      int index, String? keyword) async {
    String? description;
    await _quickChange(writer, node, shown,
        undoInBar: true,
        change: (text) => setTodo(text, index, keyword,
            now: DateTime.now(), describe: (d) => description = d),
        done: () => description ?? 'Changed the TODO state.');
  }

  /// The number of [headline] among the note's headings.
  int? _indexOf(OrgHeadline headline) {
    for (final (i, section) in (_headings?.sections ?? const []).indexed) {
      if (identical(section.headline, headline)) return i;
    }
    return null;
  }

  OrgHeadline? _currentHeadline() {
    final index = _current.value;
    final sections = _headings?.sections ?? const <OrgSection>[];
    return index != null && index < sections.length
        ? sections[index].headline
        : null;
  }

  /// Why [action] cannot be done on the heading number [index], or null.
  String? _refusal(_Headings h, HeadingAction action, int index) {
    final structure = switch (action) {
      HeadingAction.todo => StructureAction.todo,
      HeadingAction.delete => null,
      _ => action.structure,
    };
    if (structure == null) return null;
    return switch (headingStructure(structure, h.text, h.sections, index,
        topLevel: h.topLevel, todoStates: todoStatesOf(h.document))) {
      StructureRefused(:final reason) => reason,
      StructureChanged() => null,
    };
  }

  /// The menu of a heading (#217), from a long press or a right click at
  /// [at] on the screen.
  Future<void> _headingMenu(int index, {Offset? at}) async {
    final h = _headings;
    if (h == null || index >= h.sections.length) return;
    _current.value = index;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    var position = at;
    if (position == null) {
      final orgContext = _orgContext;
      final box = orgContext != null && orgContext.mounted
          ? headlineBox(orgContext, h.sections[index].headline)
          : null;
      position = box?.localToGlobal(box.size.bottomLeft(Offset.zero)) ??
          overlay.size.center(Offset.zero);
    }
    final local = overlay.globalToLocal(position);
    final chosen = await showMenu<HeadingAction>(
      context: context,
      position: RelativeRect.fromRect(
          local & Size.zero, Offset.zero & overlay.size),
      items: [
        for (final action in HeadingAction.values)
          if (_refusal(h, action, index) case final reason)
            PopupMenuItem(
              key: ValueKey('heading-${action.name}'),
              value: action,
              enabled: reason == null,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: reason == null,
                title: Text(action.label),
                subtitle: reason == null ? null : Text(reason),
                trailing: isDesktop ? Text(action.shortcut) : null,
              ),
            ),
      ],
    );
    if (chosen == null || !mounted || !identical(h, _headings)) return;
    await _onHeading(chosen, index);
  }

  Future<void> _onHeading(HeadingAction action, int index) async {
    switch (action) {
      case HeadingAction.todo:
        await _chooseTodo(index);
      case HeadingAction.delete:
        await _deleteHeading(index);
      case _:
        await _structureHeading(action, index);
    }
  }

  /// Promote, Demote, Move up or Move down on the heading number [index]
  /// and its subtree (#217), saved as a quick edit.
  Future<void> _structureHeading(HeadingAction action, int index) async {
    final h = _headings, structure = action.structure;
    if (h == null || structure == null) return;
    if (_refusal(h, action, index) case final reason?) {
      _tell(reason);
      return;
    }
    int? moved;
    await _quickChange(h.writer, h.node, h.text,
        undoInBar: true,
        change: (text) {
          final document = parseNote(text);
          switch (headingStructure(structure, text, sectionsOf(document),
              index,
              topLevel: h.topLevel, todoStates: todoStatesOf(document))) {
            case StructureChanged(:final text, :final start):
              moved = headingIndexAt(text, start);
              return text;
            case StructureRefused(:final reason):
              throw NoteChangeError(reason);
          }
        },
        done: () => switch (action) {
              HeadingAction.promote => 'Promoted the heading.',
              HeadingAction.demote => 'Demoted the heading.',
              HeadingAction.moveUp => 'Moved the heading up.',
              _ => 'Moved the heading down.',
            });
    if (mounted && moved != null) _current.value = moved;
  }

  /// The next TODO state of the heading number [index] (Shift+Right, a
  /// swipe to the right), or the one before ([forward] false, Shift+Left).
  Future<void> _cycleTodo(int index, {bool forward = true}) async {
    final h = _headings;
    if (h == null || index >= h.sections.length) return;
    if (_refusal(h, HeadingAction.todo, index) case final reason?) {
      _tell(reason);
      return;
    }
    final states = todoStatesOf(h.document);
    final current = h.sections[index].headline.keyword?.value;
    await _setTodo(h.writer, h.node, h.text, index,
        forward
            ? nextKeyword(states, current)
            : previousKeyword(states, current));
  }

  /// Deletes the heading number [index] with its subtree (#217): at once,
  /// as a quick edit, when no node is in it; after the question of
  /// "Delete note" (#93) when the heading or a heading below it has an
  /// `:ID:`.
  Future<void> _deleteHeading(int index) async {
    final h = _headings;
    if (h == null || _quickBusy || index >= h.sections.length) return;
    if (h.sections[index].level < h.topLevel) {
      // The heading of this heading node: the note itself.
      await _deleteNote(h.writer, h.node);
      return;
    }
    final cut = withoutHeading(h.text, h.sections, index);
    if (cut == null) {
      _tell('The headings of this note could not be matched to its lines; '
          'use Edit text.');
      return;
    }
    final graph = widget.graph.value;
    final nodes = [
      for (final id in idsIn(cut.removed))
        if (graph.nodes[id] case final node?
            when node.file == h.node.file && !node.isFile)
          node,
    ];
    if (nodes.isEmpty) {
      await _quickChange(h.writer, h.node, h.text,
          undoInBar: true,
          change: (text) =>
              withoutHeading(text, sectionsOf(parseNote(text)), index)
                  ?.after ??
              (throw const NoteChangeError('That heading is no longer in '
                  'the note.')),
          done: () => 'Deleted the heading.');
      if (mounted) _current.value = null;
      return;
    }
    final at = headingOffset(h.text, h.sections, index)!;
    final ownLines = headingOffsets(cut.removed);
    final own = idsIn(ownLines.length > 1
            ? cut.removed.substring(0, ownLines[1])
            : cut.removed)
        .any((id) => nodes.any((node) => node.id == id));
    final lines = '\n'.allMatches(h.text);
    int lineOf(int offset) => lines.where((m) => m.start < offset).length;
    final end = at + cut.removed.length;
    _endVisit();
    final messenger = ScaffoldMessenger.of(context);
    final deletion = await confirmDeleteNotes(context,
        graph: graph,
        nodes: nodes,
        writer: h.writer,
        alsoLines: own
            ? const {}
            : {
                h.node.file: (
                  lineOf(at),
                  end == h.text.length ? lines.length + 1 : lineOf(end),
                ),
              },
        heading: own ? null : h.sections[index].headline.rawTitle ?? '');
    if (deletion == null || !mounted) return;
    _current.value = null;
    _readAgain();
    if (messenger.mounted) showDeleted(messenger, deletion, h.writer);
  }

  /// The desktop's keys on the current heading (#217), as in Org; none
  /// while a text field has the focus.
  KeyEventResult _headingKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    bool pressed(SingleActivator activator) => activator.accepts(event, keys);
    if (pressed(const SingleActivator(LogicalKeyboardKey.keyZ, control: true)) ||
        pressed(const SingleActivator(LogicalKeyboardKey.keyZ, meta: true))) {
      if (_editWriter == null || _undoSteps.isEmpty) {
        return KeyEventResult.ignored;
      }
      _undoQuick();
      return KeyEventResult.handled;
    }
    final index = _current.value;
    if (_headings == null || index == null) return KeyEventResult.ignored;
    const left = LogicalKeyboardKey.arrowLeft,
        right = LogicalKeyboardKey.arrowRight;
    final Future<void> Function()? run = switch (null) {
      _ when pressed(const SingleActivator(left, alt: true, shift: true)) =>
        () => _structureHeading(HeadingAction.promote, index),
      _ when pressed(const SingleActivator(right, alt: true, shift: true)) =>
        () => _structureHeading(HeadingAction.demote, index),
      _ when pressed(
          const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true)) =>
        () => _structureHeading(HeadingAction.moveUp, index),
      _ when pressed(
          const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true)) =>
        () => _structureHeading(HeadingAction.moveDown, index),
      _ when pressed(const SingleActivator(left, shift: true)) =>
        () => _cycleTodo(index, forward: false),
      _ when pressed(const SingleActivator(right, shift: true)) =>
        () => _cycleTodo(index),
      _ when pressed(const SingleActivator(LogicalKeyboardKey.delete)) =>
        () => _deleteHeading(index),
      _ => null,
    };
    if (run == null) return KeyEventResult.ignored;
    run();
    return KeyEventResult.handled;
  }

  /// Runs [save] unless another quick edit is being saved; then says so,
  /// so no tap is lost without a word.
  Future<void> _oneAtATime(Future<void> Function() save) async {
    if (_quickBusy) {
      _tell('The last change is still being saved; tap again in a moment.');
      return;
    }
    _quickBusy = true;
    try {
      await save();
      // Until the note is read again and drawn, the items on screen hold
      // the text before the save, and a tap on them would be refused.
      await _text;
      if (mounted) await WidgetsBinding.instance.endOfFrame;
    } finally {
      _quickBusy = false;
    }
  }

  /// Saves [editor]'s change of [file] from [base] to [text], the TODO
  /// keywords of [base] allowed to change above drawers; a failure to
  /// keep the old version is a failed save.
  Future<SaveResult> _saveQuick(
      NoteEditor editor, String file, NoteVersion base, String text) async {
    try {
      return await editor.save(file, base, text,
          todoKeywords: allKeywords(todoStatesOf(parseNote(base.text))).toSet());
    } catch (e) {
      return SaveFailed('$e');
    }
  }

  /// Saves [change] of [node]'s file at once, without the diff (#150), as
  /// every edit is saved otherwise (decision 10): only over [shown], the
  /// text the tapped item was shown from, with the drawers locked, the old
  /// version kept, the graph updated. Undo belongs to this note visit.
  Future<void> _quickChange(
    NoteWriter writer,
    RoamNode node,
    String shown, {
    required String Function(String text) change,
    required String Function() done,
    bool undoInBar = false,
  }) =>
      _oneAtATime(() async {
        final visit = _visit, id = widget.id;
        final editor = writer.editor;
        if (editor == null) return;
        // The folder the change is made in; another one chosen meanwhile
        // (for write access) has another note under the same path.
        final key = editor.store.historyKey(node.file);
        final base = await editor.read(node.file);
        if (!mounted || _visit != visit || widget.id != id) return;
        if (base == null) {
          _endVisit();
          _readAgain();
          _tell('Could not read ${node.file} as text to change.',
              error: true);
          return;
        }
        if (base.text != shown) {
          _endVisit();
          _readAgain();
          _tell('${node.file} changed since the app showed it, so nothing '
              'was changed. It is shown again now.',
              error: true);
          return;
        }
        final String after;
        try {
          after = change(base.text);
        } on NoteChangeError catch (e) {
          _tell('${e.message} Nothing was changed.', error: true);
          return;
        }
        if (after == base.text) return;
        if (editor.store.historyKey(node.file) != key) {
          _endVisit();
          _tell('Another folder is open now; nothing was changed.',
              error: true);
          return;
        }
        _keepFolding(after);
        final result = await _saveQuick(editor, node.file, base, after);
        if (!mounted || _visit != visit || widget.id != id) return;
        if (result is NoWriteAccessToEdit) await writer.allowWriting();
        if (!mounted || _visit != visit || widget.id != id) return;
        _readAgain();
        if (result is Saved || result is SavedNotIndexed) {
          setState(() {
            // An outside change may already be shown before its read
            // continuation runs. Only keep steps that form one chain.
            if (_undoSteps.isNotEmpty &&
                (_undoSteps.last.after != base.text ||
                    _undoSteps.last.historyKey != key)) {
              _undoSteps.clear();
            }
            _undoSteps.add((
              writer: writer,
              file: node.file,
              historyKey: key,
              before: base.text,
              after: after,
            ));
          });
          _tell(saveMessage(result, node.file) ?? done(),
              short: true, undo: undoInBar);
        } else {
          _keptFolding = null;
          if (result is ChangedMeanwhile || result is NoteGone) _endVisit();
          final problem = saveMessage(result, node.file);
          _tell(problem ?? done(),
              error: problem != null && result is! SavedNotIndexed);
        }
      });

  /// Puts back the newest quick edit of this visit, only over its result.
  Future<void> _undoQuick() =>
      _oneAtATime(() async {
        if (_undoSteps.isEmpty) return;
        final visit = _visit, id = widget.id;
        final step = _undoSteps.last;
        final editor = step.writer.editor;
        if (editor == null) return;
        if (editor.store.historyKey(step.file) != step.historyKey) {
          _undoChanged(step.file);
          return;
        }
        final current = await editor.read(step.file);
        if (!mounted || _visit != visit || widget.id != id) return;
        if (current == null ||
            current.text != step.after ||
            editor.store.historyKey(step.file) != step.historyKey) {
          _undoChanged(step.file);
          return;
        }
        _keepFolding(step.before);
        final result =
            await _saveQuick(editor, step.file, current, step.before);
        if (!mounted || _visit != visit || widget.id != id) return;
        if (result is NoWriteAccessToEdit) await step.writer.allowWriting();
        if (!mounted || _visit != visit || widget.id != id) return;
        if (result is ChangedMeanwhile || result is NoteGone) {
          _undoChanged(step.file);
          return;
        }
        if (result is Saved || result is SavedNotIndexed) {
          setState(() => _undoSteps.removeLast());
        } else {
          _keptFolding = null;
        }
        _readAgain();
        final problem = saveMessage(result, step.file);
        _tell(problem ?? 'Undone.',
            short: result is Saved || result is SavedNotIndexed,
            error: problem != null && result is! SavedNotIndexed);
      });

  void _undoChanged(String file) {
    _keptFolding = null;
    _endVisit();
    _readAgain();
    _tell('$file or its folder changed since, so nothing was undone. '
        'It is shown again now.',
        error: true);
  }

  Future<void> _deleteNote(NoteWriter writer, RoamNode node) async {
    if (_quickBusy) return;
    _endVisit();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final pane = widget.onOpenNode != null;
    final deletion = await confirmDeleteNotes(context,
        graph: widget.graph.value, nodes: [node], writer: writer);
    if (deletion == null) return;
    if (!pane && mounted) navigator.pop();
    if (messenger.mounted) showDeleted(messenger, deletion, writer);
  }

  /// Leaving this note or opening an editing surface ends its undo chain,
  /// including any quick operation whose save has not returned yet.
  void _endVisit({bool duringBuild = false}) {
    if (!mounted) return;
    if (duringBuild) {
      // didUpdateWidget already schedules a build. With TalkBack,
      // hiding a snack bar synchronously rebuilds its ancestor messenger.
      _visit++;
      _undoSteps.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      });
      return;
    }
    setState(() {
      _visit++;
      _undoSteps.clear();
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  /// Remembers how far each section is open, to restore it when the note
  /// is read again with [text].
  void _keepFolding(String text) {
    final states = _currentFolding();
    if (states == null) return;
    _keptFolding = (text: text, states: states);
  }

  void _readAgain() {
    if (!mounted) return;
    final busy = _quickBusy, visit = _visit, id = widget.id;
    final newest = _undoSteps.lastOrNull;
    final read = _read().then((text) {
      // Own saves notify before they return. Also ignore reads for an
      // older visit or an older undo chain, even if they finish later.
      if (mounted &&
          !busy &&
          _visit == visit &&
          widget.id == id &&
          newest != null &&
          _undoSteps.isNotEmpty &&
          _undoSteps.last == newest &&
          text != newest.after) {
        _endVisit();
      }
      return text;
    });
    setState(() {
      _text = read;
    });
  }

  /// An [error] has a "Copy" action (#180), and stays until dismissed.
  /// With [undo], it has an "Undo" action for the newest quick edit
  /// (#217).
  void _tell(String message,
      {bool short = false, bool error = false, bool undo = false}) {
    final messenger = ScaffoldMessenger.of(context);
    if (error) {
      showErrorSnackBar(messenger, message);
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: short && !undo
            ? const Duration(seconds: 2)
            : const Duration(seconds: 4),
        persist: false,
        action: undo
            ? SnackBarAction(
                key: const ValueKey('snack-undo'),
                label: 'Undo',
                onPressed: _undoQuick)
            : null,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final node = _node;
    final onShowInGraph = widget.onShowInGraph;
    // Ctrl+F (Cmd+F on macOS) opens the search on the desktop (#116);
    // Escape and Back close it.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _startSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _startSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
      },
      child: Focus(
        focusNode: _keysFocus,
        autofocus: true,
        onKeyEvent: _headingKey,
        child: PopScope(
          canPop: !_searching,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeSearch();
          },
          child: _scaffold(context, node, onShowInGraph),
        ),
      ),
    );
  }

  Widget _scaffold(BuildContext context, RoamNode? node,
      void Function(BuildContext, String)? onShowInGraph) =>
      LayoutBuilder(
        builder: (context, constraints) => _scaffoldIn(
            context, node, onShowInGraph, constraints.maxWidth),
      );

  Widget _scaffoldIn(BuildContext context, RoamNode? node,
      void Function(BuildContext, String)? onShowInGraph, double width) {
    // "New node from here" and "Open in ..." go into a "More" menu when the
    // bar is too narrow for all its buttons, as on a phone (#152 added
    // "Search in this note").
    final more = <(String, IconData, VoidCallback)>[
      if (widget.writer case final writer? when node != null)
        ('New node from here', Icons.note_add_outlined,
            () => _capture(writer, node)),
      if (widget.openElsewhere case final open? when node != null)
        (openElsewhereLabel, Icons.open_in_new,
            () => _openElsewhere(open, node)),
      // Without the edit menu (⋮), which has "Share note…" otherwise.
      if (node != null && !widget.help && widget.writer?.editor == null)
        ('Share note…', Icons.share, () => _shareNote(node)),
    ];
    final buttons = [
      node != null, // Search in this note
      !widget.help, // Search
      node != null && !widget.help, // AI
      widget.writer?.editor != null && node != null && !widget.help, // Edit
      _editWriter != null && _undoSteps.isNotEmpty, // Undo
      node != null && onShowInGraph != null, // Show in graph
    ].where((shown) => shown).length + more.length;
    // The back button, every button, and some room for the title.
    final crowded = more.length > 1 && width < 56 + 48 * buttons + 120;
    return Scaffold(
      appBar: _searching ? _searchBar() : AppBar(
        automaticallyImplyLeading: widget.onOpenNode == null,
        leading: widget.onBack == null
            ? null
            : IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
        title: Text(node?.displayTitle ?? 'Node'),
        actions: [
          if (node != null)
            IconButton(
              tooltip: 'Search in this note',
              icon: const Icon(Icons.find_in_page_outlined),
              onPressed: _startSearch,
            ),
          if (!widget.help)
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => SearchScreen.open(
              context,
              graph: widget.graph,
              readNote: widget.readNote,
              files: widget.files,
              nodeMemory: widget.nodeMemory,
              onShowInGraph: onShowInGraph,
              openElsewhere: widget.openElsewhere,
              onOpenNode: widget.onOpenNode,
              writer: widget.writer,
              shareText: widget.shareText,
            ),
          ),
          // The AI actions in one menu, so the bar fits a phone.
          if (node != null && !widget.help)
            PopupMenuButton<_AiAction>(
              tooltip: 'AI',
              icon: const Icon(Icons.auto_awesome_outlined),
              onSelected: (action) => switch (action) {
                _AiAction.newChat => _askAi(node, newChat: true),
                _AiAction.chats => _askAi(node, newChat: false),
                _AiAction.share => _shareWithAi(node),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: _AiAction.newChat,
                    child: Text('New chat about this note')),
                PopupMenuItem(value: _AiAction.chats, child: Text('Chats')),
                PopupMenuItem(
                    value: _AiAction.share, child: Text('Share with AI')),
              ],
            ),
          if (_editWriter != null && !widget.help && _undoSteps.isNotEmpty)
            IconButton(
              tooltip: 'Undo the last change',
              icon: const Icon(Icons.undo),
              onPressed: _undoQuick,
            ),
          // Edits of this note (v4), in one menu.
          if (widget.writer case final writer?
              when node != null && writer.editor != null && !widget.help)
            PopupMenuButton<_EditAction>(
              tooltip: 'Edit',
              icon: const Icon(Icons.more_vert),
              onSelected: (action) => switch (action) {
                _EditAction.append => _append(writer, node),
                _EditAction.edit => _edit(writer, node),
                _EditAction.meta => _meta(writer, node),
                _EditAction.ai => _aiEdit(writer, node),
                _EditAction.image => _createImage(writer, node),
                _EditAction.history => _history(writer, node),
                _EditAction.share => _shareNote(node),
                _EditAction.delete => _deleteNote(writer, node),
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: _EditAction.append,
                    child: Text('Add to this node')),
                const PopupMenuItem(
                    value: _EditAction.edit, child: Text('Edit text')),
                const PopupMenuItem(
                    value: _EditAction.meta,
                    child: Text('Title, tags and aliases')),
                const PopupMenuItem(
                    value: _EditAction.ai, child: Text('Edit with AI')),
                if (writer.createFile != null)
                  const PopupMenuItem(
                      value: _EditAction.image, child: Text('Create image')),
                const PopupMenuItem(
                    value: _EditAction.share, child: Text('Share note…')),
                const PopupMenuItem(
                    value: _EditAction.history,
                    child: Text('Earlier versions')),
                PopupMenuItem(
                    value: _EditAction.delete,
                    child: Text('Delete note…', style: TextStyle(
                        color: Theme.of(context).colorScheme.error))),
              ],
            ),
          if (crowded)
            PopupMenuButton<VoidCallback>(
              tooltip: 'More for this note',
              icon: const Icon(Icons.more_horiz),
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                for (final (label, _, action) in more)
                  PopupMenuItem(value: action, child: Text(label)),
              ],
            )
          else
            for (final (label, icon, action) in more)
              IconButton(tooltip: label, icon: Icon(icon), onPressed: action),
          if (node != null && onShowInGraph != null)
            IconButton(
              tooltip: 'Show in graph',
              icon: const Icon(Icons.hub_outlined),
              onPressed: () {
                _endVisit();
                onShowInGraph(context, widget.id);
              },
            ),
        ],
      ),
      body: node == null
          ? const Center(child: Text('This node no longer exists.'))
          : FutureBuilder<String?>(
              future: _text,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done) {
                  _shown = snapshot.data;
                  _shownId = node.id;
                } else if (_shownId != node.id) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _content(context, node, _shown);
              },
            ),
    );
  }

  Widget _content(BuildContext context, RoamNode node, String? text) {
    final graph = widget.graph.value;
    final backlinks = backlinksOf(graph, node.id);
    final links = [
      for (final link in graph.links)
        if (link.source == node.id && link.type == 'id') link,
    ];
    final writer = _editWriter;
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      key: ValueKey('node-${node.id}'),
      children: [
        if (text == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not read ${node.file}.'),
          )
        else
          _org(node, text),
        // The id: links of this note, to remove one (#133) or add one
        // (#135).
        if (writer != null) ...[
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                      links.isEmpty ? 'No links' : 'Links: ${links.length}',
                      style: textTheme.titleMedium),
                ),
                IconButton(
                  key: const ValueKey('add-link'),
                  tooltip: 'Add a link to another note',
                  icon: const Icon(Icons.add),
                  onPressed: () => _addLink(writer, node),
                ),
              ],
            ),
          ),
          for (final (i, link) in links.indexed)
            ListTile(
              key: ValueKey('link-$i'),
              title: Text(_titleOf(link.dest)),
              subtitle: Text(Backlink(node, link).outline),
              onTap: graph.nodes.containsKey(link.dest)
                  ? () => _openId(link.dest)
                  : null,
              trailing: IconButton(
                key: ValueKey('remove-link-$i'),
                tooltip: 'Remove this link',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _removeLink(writer, link),
              ),
            ),
        ],
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  backlinks.isEmpty
                      ? 'No backlinks'
                      : 'Backlinks: ${backlinks.length}',
                  style: textTheme.titleMedium,
                ),
              ),
              if (writer != null)
                IconButton(
                  key: const ValueKey('add-backlink'),
                  tooltip: 'Link another note to this one',
                  icon: const Icon(Icons.add),
                  onPressed: () => _addBacklink(writer, node),
                ),
            ],
          ),
        ),
        for (final (i, backlink) in backlinks.indexed)
          ListTile(
            key: ValueKey('backlink-$i'),
            title: Text(backlink.source.displayTitle),
            subtitle: Text(backlink.outline),
            onTap: () => _openId(backlink.source.id),
            trailing: writer == null
                ? null
                : IconButton(
                    key: ValueKey('remove-backlink-$i'),
                    tooltip: 'Remove this link from '
                        '${backlink.source.displayTitle}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removeLink(writer, backlink.link),
                  ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// The Org text of [node]: the file, or the heading's subtree.
  Widget _org(RoamNode node, String text) {
    final files = widget.files;
    // Source blocks coloured as Emacs colours them (#45); display formulas
    // in display mode (#50); mermaid blocks without a result image drawn
    // (#49); sub- and superscripts as the mode says (#213); the lines of
    // a paragraph joined, if the setting says so (#219).
    final view = ViewSettingsScope.of(context);
    final scripted = withScripts(
      withDisplayFormulas(withHighlightLanguages(parseNote(text))),
      // The note's own #+OPTIONS: ^: wins over the setting (#213).
      scriptModeOf(text) ?? view.scripts,
    );
    final document = withMermaidDrawings(
      view.joinLines ? withJoinedLines(scripted) : scripted,
      showsImage: (location) {
        final path = linkedImagePath(node.file, location);
        return files != null &&
            path != null &&
            files.reaches(path) &&
            files.find(path) != null;
      },
    );
    final OrgTree? tree =
        node.isFile ? document : document.sectionWithId(node.id);
    if (tree == null) {
      // The file changed since it was indexed; the next scan fixes it.
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('The heading is no longer in ${node.file}.'),
      );
    }
    // Sections open as the setting says, or as the file's #+STARTUP: says
    // (#63).
    final state =
        startupState(document, view.sectionsOnOpen);
    final writer = _editWriter;
    // The folding before a quick edit, when this is the same note after it.
    List<OrgVisibilityState>? folding;
    if (_keptFolding case final kept? when kept.text == text) {
      _keptFolding = null;
      if (kept.states.length == sectionsOf(tree).length) folding = kept.states;
    }
    final headings = writer == null
        ? null
        : _Headings(
            writer: writer,
            node: node,
            text: text,
            document: document,
            sections: sectionsOf(document),
            topLevel: tree is OrgSection ? tree.level + 1 : 1,
          );
    // A quick edit sets the current heading itself, after the note is
    // drawn again.
    if (_headings?.node.id != node.id ||
        (_current.value ?? 0) >= (headings?.sections.length ?? 0)) {
      _current.value = null;
    }
    _headings = headings;
    final body = KeepFolding(
      tree: tree,
      states: folding,
      child: NoteSearchHits(
        hits: _hits,
        child: Builder(builder: (context) {
          _orgContext = context;
          return tree is OrgSection
              ? OrgSectionWidget(tree)
              : OrgDocumentWidget(document, shrinkWrap: true);
        }),
      ),
    );
    final heading = _pendingHeading;
    final shown = heading == null
        ? body
        : ShowHeading(
            key: ObjectKey(heading),
            tree: tree,
            heading: heading,
            onMissing: () {
              if (mounted) _tell(heading.missingMessage);
            },
            onDone: () {
              if (identical(_pendingHeading, heading)) _pendingHeading = null;
            },
            child: body,
          );
    final gestures = headings == null
        ? shown
        : HeadingGestures(
            orgContext: () => _orgContext,
            current: _currentHeadline,
            currentChanged: _current,
            showCurrent: isDesktop,
            swipes: view.swipeHeadings,
            onPointerDown: (headline) {
              if (headline == null) return;
              if (_indexOf(headline) case final index?) {
                _current.value = index;
                _keysFocus.requestFocus();
              }
            },
            onSecondaryTap: (headline, at) {
              if (_indexOf(headline) case final index?) {
                _headingMenu(index, at: at);
              }
            },
            swipeLabel: (headline, {required bool right}) {
              if (!right) return 'Delete';
              final states = todoStatesOf(document);
              if (allKeywords(states).isEmpty) return 'No TODO states';
              return nextKeyword(states, headline.keyword?.value) ??
                  'No state';
            },
            onSwipe: (headline, {required bool right}) {
              final index = _indexOf(headline);
              if (index == null) return;
              _current.value = index;
              right ? _cycleTodo(index) : _deleteHeading(index);
            },
            child: shown,
          );
    return OrgController(
      // A new controller for new text or a new setting, so the folding
      // starts again.
      key: ValueKey((text, state)),
      root: tree,
      settings: OrgSettings(startupFolded: state),
      // Search inside the note (#152).
      searchQuery: _searchPattern,
      sparseQuery: switch (_searchPattern) {
        final pattern? when _onlyMatching => MatchingSections(pattern, tree),
        _ => null,
      },
      child: OrgRootWidget(
        onLinkTap: _openLink,
        onLocalSectionLinkTap: _openSection,
        // Ticking a checkbox and changing a TODO state, saved at once
        // (#150).
        onListItemTap: writer == null
            ? null
            : (item) => _toggleCheckbox(writer, node, text, document, item),
        // The menu of a heading (#217).
        onSectionLongPress: writer == null
            ? null
            : (section) {
                if (sectionIndex(document, section) case final index?) {
                  _headingMenu(index);
                }
              },
        loadImage: (link) =>
            loadMermaidDrawing(link) ??
            switch (files) {
              final files? => loadNoteImage(files, node.file, tree, link,
                  share: widget.shareFiles,
                  onRemove: switch (_editWriter) {
                    final writer? => () => _removeImage(writer, node, link),
                    null => null,
                  }),
              null => null,
            },
        child: tree is OrgSection
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: OpenSection(
                    section: tree, state: state, child: gestures),
              )
            : gestures,
      ),
    );
  }
}

/// The actions of the node view's AI menu.
enum _AiAction { newChat, chats, share }

/// The edits of an existing note (v4).
enum _EditAction { append, edit, meta, ai, image, share, history, delete }

/// The note as last drawn, with what its heading actions need (#217).
class _Headings {
  _Headings({
    required this.writer,
    required this.node,
    required this.text,
    required this.document,
    required this.sections,
    required this.topLevel,
  });
  final NoteWriter writer;
  final RoamNode node;

  /// The text the note was drawn from; every change is made over it.
  final String text;
  final OrgDocument document;
  final List<OrgSection> sections;

  /// The highest level a heading may get: 1 in a file node, one below the
  /// node's own heading in a heading node.
  final int topLevel;
}
