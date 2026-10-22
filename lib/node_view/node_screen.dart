import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../ai/ai_settings.dart';
import '../ai/chat_screen.dart';
import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../edit/add_link.dart';
import '../edit/ai_edit_screen.dart';
import '../edit/append_screen.dart';
import '../edit/edit_screen.dart';
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
import '../settings/view_settings.dart';
import 'folding.dart';
import 'quick_edits.dart';
import 'latex.dart';
import 'mermaid.dart';
import 'src_languages.dart';
import '../search/search_screen.dart';
import 'note_images.dart';
import 'web_links.dart';
import '../platform/desktop.dart';

/// Reads a note's text, by its path relative to `roam/`; null if it cannot
/// be read.
typedef NoteReader = Future<String?> Function(String path);

/// Orgro's application ID (its `build.gradle`).
const orgroPackage = 'com.madlonkay.orgro';

/// What happened when a note was to be opened in Orgro.
enum OpenResult { opened, noApp, noFile }

/// Opens a note in Orgro (#10), by its path relative to `roam/`.
/// Opens the note [path] (relative to `roam/`) in another app: Orgro on
/// Android, Emacs on the desktop (#116), there at [line].
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
    this.openInOrgro,
    this.onOpenNode,
    this.onBack,
    this.writer,
    this.shareText = shareTextOut,
    this.openUrl = openUrlOnDevice,
    this.help = false,
  });

  final ValueListenable<RoamGraph> graph;
  final String id;
  final NoteReader readNote;

  /// The folder's other files, for images in notes (#46); without
  /// them, image links are shown as text.
  final NoteFiles? files;
  final NodeMemory nodeMemory;

  /// Opens the node's file in Orgro; the button is hidden when null.
  final NoteOpener? openInOrgro;

  /// Opens another node. When null, it opens on a new page; the side pane
  /// of the tablet layout (#16) shows it in place instead.
  final void Function(BuildContext context, String id)? onOpenNode;

  /// Goes back to the node shown before, in the side pane; null when there
  /// is none. With [onOpenNode], the app bar has no other back button: the
  /// pane is part of the graph's page.
  final VoidCallback? onBack;

  /// Writes new notes; with it, "New node from here" captures a node that
  /// links to this one (#12).
  final NoteWriter? writer;

  /// Sends text to an AI app (#41); tests replace it.
  final TextSharer shareText;

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
    NoteOpener? openInOrgro,
    NoteWriter? writer,
    TextSharer shareText = shareTextOut,
    UrlOpener openUrl = openUrlOnDevice,
    bool help = false,
  }) {
    nodeMemory.remember(id);
    return Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => NodeScreen(
          graph: graph,
          id: id,
          readNote: readNote,
          files: files,
          nodeMemory: nodeMemory,
          onShowInGraph: onShowInGraph,
          openInOrgro: openInOrgro,
          writer: writer,
          shareText: shareText,
          openUrl: openUrl,
          help: help,
        ),
      ),
    );
  }

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

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

  RoamNode? get _node => widget.graph.value.nodes[widget.id];

  @override
  void initState() {
    super.initState();
    _text = _read();
    widget.graph.addListener(_graphChanged);
  }

  @override
  void dispose() {
    widget.graph.removeListener(_graphChanged);
    super.dispose();
  }

  Future<String?> _read() async {
    final node = _node;
    return node == null ? null : widget.readNote(node.file);
  }

  /// The file may have changed with the index: read it again.
  void _graphChanged() {
    if (!mounted) return;
    setState(() {
      _text = _read();
    });
  }

  void _openLink(OrgLink link) {
    final location = link.location;
    if (location.startsWith('id:')) {
      _openId(location.substring(3).split('::').first.trim());
    } else if (externalLinkTarget(location) case final uri?) {
      // Web, mail and phone links open in their app (#108).
      openExternalLink(context, uri, widget.openUrl);
    } else {
      _tell('This app opens id:, web, mail and phone links, not '
          '"$location".');
    }
  }

  /// A link to a heading in the shown text itself: `[[id:...]]`,
  /// `[[*Heading]]` or `[[#custom-id]]`, which Org reports as a section. A
  /// heading that is a node opens; another heading cannot be shown alone.
  void _openSection(OrgTree section, {String? searchOption}) {
    final id = section.ids.firstOrNull;
    if (id != null) {
      _openId(id);
    } else {
      _tell('This heading is no node, so the app cannot open it.');
    }
  }

  @override
  void didUpdateWidget(NodeScreen old) {
    super.didUpdateWidget(old);
    if (old.graph != widget.graph) {
      old.graph.removeListener(_graphChanged);
      widget.graph.addListener(_graphChanged);
    }
    // The side pane shows another node.
    if (old.id != widget.id || old.graph != widget.graph) _text = _read();
  }

  void _openId(String id) {
    if (!widget.graph.value.nodes.containsKey(id)) {
      _tell('There is no node with the ID $id.');
      return;
    }
    if (widget.onOpenNode case final open?) {
      widget.nodeMemory.remember(id);
      open(context, id);
      return;
    }
    NodeScreen.open(
      context,
      graph: widget.graph,
      id: id,
      readNote: widget.readNote,
      files: widget.files,
      nodeMemory: widget.nodeMemory,
      onShowInGraph: widget.onShowInGraph,
      openInOrgro: widget.openInOrgro,
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
    final message = await AppendScreen.open(context, writer, node);
    if (message != null && mounted) _tell(message);
  }

  /// Makes an image with the AI and adds it to this note (#112). Not for a
  /// note hidden from AI.
  Future<void> _createImage(NoteWriter writer, RoamNode node) async {
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
    final message = await EditScreen.open(context, writer, node,
        graph: widget.graph.value);
    if (message != null && mounted) _tell(message);
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
    final message = await MetaScreen.open(context, writer, node,
        graph: widget.graph.value);
    if (message != null && mounted) _tell(message);
  }

  /// Opens the node's file in Orgro, at the top: Orgro has no way to jump
  /// to a heading from outside (decision 6). On the desktop in Emacs, at
  /// the node's line (#116).
  Future<void> _openInOrgro(NoteOpener open, RoamNode node) async {
    final result = await open(node.file, line: node.line);
    if (!mounted) return;
    switch (result) {
      case OpenResult.opened:
        if (!node.isFile && !isDesktop) {
          _tell('Orgro opens ${node.file} at the top; '
              'it cannot jump to the heading.');
        }
      case OpenResult.noApp:
        _tell(isDesktop
            ? 'Emacs could not be started. Check the Emacs command in '
                'Settings.'
            : 'Orgro is not installed.');
      case OpenResult.noFile:
        _tell('Could not find ${node.file} in the folder.');
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
      if (mounted) _tell('Could not share the note: ${e.message ?? e.code}');
    }
  }

  /// Opens the AI chat about [node] (#60).
  Future<void> _askAi(RoamNode node) => ChatScreen.open(
        context,
        graph: widget.graph,
        readNote: widget.readNote,
        startNode: node,
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
          openInOrgro: widget.openInOrgro,
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

  /// What a slide on a heading reveals (#150): its next TODO state, and
  /// the list of states.
  List<Widget> _todoActions(NoteWriter writer, RoamNode node, String shown,
      OrgDocument document, OrgSection section) {
    final index = sectionIndex(document, section);
    if (index == null) return const [];
    final states = todoStatesOf(document);
    final next = nextKeyword(states, section.headline.keyword?.value);
    return [
      TodoSlideAction(
        key: ValueKey('todo-next-$index'),
        icon: Icons.repeat,
        label: next ?? 'No state',
        onPressed: () => _setTodo(writer, node, shown, index, next),
      ),
      TodoSlideAction(
        key: ValueKey('todo-states-$index'),
        icon: Icons.list,
        label: 'States',
        onPressed: () => _chooseTodo(writer, node, shown, document, section),
      ),
    ];
  }

  /// A long press on a heading (#150): the list of TODO states to choose.
  Future<void> _chooseTodo(NoteWriter writer, RoamNode node, String shown,
      OrgDocument document, OrgSection section) async {
    final index = sectionIndex(document, section);
    if (index == null) return;
    final chosen = await chooseTodoState(context,
        states: todoStatesOf(document),
        current: section.headline.keyword?.value);
    if (chosen == null || !mounted) return;
    await _setTodo(writer, node, shown, index, chosen.keyword);
  }

  Future<void> _setTodo(NoteWriter writer, RoamNode node, String shown,
      int index, String? keyword) async {
    String? description;
    await _quickChange(writer, node, shown,
        change: (text) => setTodo(text, index, keyword,
            now: DateTime.now(), describe: (d) => description = d),
        done: () => description ?? 'Changed the TODO state.');
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
  /// version kept, the graph updated. The message offers Undo.
  Future<void> _quickChange(
    NoteWriter writer,
    RoamNode node,
    String shown, {
    required String Function(String text) change,
    required String Function() done,
  }) =>
      _oneAtATime(() async {
        final editor = writer.editor;
        if (editor == null) return;
        // The folder the change is made in; another one chosen meanwhile
        // (for write access) has another note under the same path.
        final key = editor.store.historyKey(node.file);
        final base = await editor.read(node.file);
        if (!mounted) return;
        if (base == null) {
          _tell('Could not read ${node.file} as text to change.');
          return;
        }
        if (base.text != shown) {
          _readAgain();
          _tell('${node.file} changed since the app showed it, so nothing '
              'was changed. It is shown again now.');
          return;
        }
        final String after;
        try {
          after = change(base.text);
        } on NoteChangeError catch (e) {
          _tell('${e.message} Nothing was changed.');
          return;
        }
        if (after == base.text) return;
        if (editor.store.historyKey(node.file) != key) {
          _tell('Another folder is open now; nothing was changed.');
          return;
        }
        _keepFolding(after);
        final result = await _saveQuick(editor, node.file, base, after);
        if (!mounted) return;
        if (result is NoWriteAccessToEdit) await writer.allowWriting();
        if (!mounted) return;
        _readAgain();
        if (result is Saved || result is SavedNotIndexed) {
          _tell(saveMessage(result, node.file) ?? done(),
              undo: () => _undoQuick(writer, node.file, key, after, base.text));
        } else {
          _keptFolding = null;
          _tell(saveMessage(result, node.file) ?? done());
        }
      });

  /// Undo in a quick edit's message: puts [before] back if the file, in
  /// the folder with history [key], is still [after].
  Future<void> _undoQuick(NoteWriter writer, String file, String key,
          String after, String before) =>
      _oneAtATime(() async {
        final editor = writer.editor;
        if (editor == null) return;
        if (editor.store.historyKey(file) != key) {
          _tell('Another folder is open now; the change was not undone.');
          return;
        }
        final current = await editor.read(file);
        if (!mounted) return;
        if (current == null || current.text != after) {
          _tell('$file changed since, so the change was not undone.');
          return;
        }
        _keepFolding(before);
        final result = await _saveQuick(editor, file, current, before);
        if (!mounted) return;
        if (result is NoWriteAccessToEdit) await writer.allowWriting();
        if (!mounted) return;
        _readAgain();
        if (result is! Saved && result is! SavedNotIndexed) {
          _keptFolding = null;
        }
        _tell(saveMessage(result, file) ?? 'Undone.');
      });

  /// Remembers how far each section is open, to restore it when the note
  /// is read again with [text].
  void _keepFolding(String text) {
    final orgContext = _orgContext;
    if (orgContext == null || !orgContext.mounted) return;
    final controller = OrgController.of(orgContext);
    _keptFolding = (
      text: text,
      states: [
        for (final section in sectionsOf(controller.root))
          controller.nodeFor(section).visibility.value,
      ],
    );
  }

  void _readAgain() {
    if (!mounted) return;
    setState(() {
      _text = _read();
    });
  }

  void _tell(String message, {VoidCallback? undo}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: undo == null
            ? null
            : SnackBarAction(label: 'Undo', onPressed: undo),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final node = _node;
    final onShowInGraph = widget.onShowInGraph;
    return Scaffold(
      appBar: AppBar(
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
              openInOrgro: widget.openInOrgro,
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
                _AiAction.ask => _askAi(node),
                _AiAction.share => _shareWithAi(node),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: _AiAction.ask, child: Text('Ask AI')),
                PopupMenuItem(
                    value: _AiAction.share, child: Text('Share with AI')),
              ],
            ),
          // Edits of this note (v4), in one menu.
          if (widget.writer case final writer?
              when node != null && writer.editor != null && !widget.help)
            PopupMenuButton<_EditAction>(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_note_outlined),
              onSelected: (action) => switch (action) {
                _EditAction.append => _append(writer, node),
                _EditAction.edit => _edit(writer, node),
                _EditAction.meta => _meta(writer, node),
                _EditAction.ai => _aiEdit(writer, node),
                _EditAction.image => _createImage(writer, node),
                _EditAction.history => HistoryScreen.open(context, writer, node),
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
                    value: _EditAction.history,
                    child: Text('Earlier versions')),
              ],
            ),
          if (widget.writer case final writer? when node != null)
            IconButton(
              tooltip: 'New node from here',
              icon: const Icon(Icons.note_add_outlined),
              onPressed: () => _capture(writer, node),
            ),
          if (widget.openInOrgro case final open? when node != null)
            IconButton(
              tooltip: 'Open in $noteAppName',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => _openInOrgro(open, node),
            ),
          if (node != null && onShowInGraph != null)
            IconButton(
              tooltip: 'Show in graph',
              icon: const Icon(Icons.hub_outlined),
              onPressed: () => onShowInGraph(context, widget.id),
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
    // (#49).
    final document = withMermaidDrawings(
      withDisplayFormulas(withHighlightLanguages(parseNote(text))),
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
        startupState(document, ViewSettingsScope.of(context).sectionsOnOpen);
    final writer = _editWriter;
    // The folding before a quick edit, when this is the same note after it.
    List<OrgVisibilityState>? folding;
    if (_keptFolding case final kept? when kept.text == text) {
      _keptFolding = null;
      if (kept.states.length == sectionsOf(tree).length) folding = kept.states;
    }
    final body = KeepFolding(
      tree: tree,
      states: folding,
      child: Builder(builder: (context) {
        _orgContext = context;
        return tree is OrgSection
            ? OrgSectionWidget(tree)
            : OrgDocumentWidget(document, shrinkWrap: true);
      }),
    );
    return OrgController(
      // A new controller for new text or a new setting, so the folding
      // starts again.
      key: ValueKey((text, state)),
      root: tree,
      settings: OrgSettings(startupFolded: state),
      child: OrgRootWidget(
        onLinkTap: _openLink,
        onLocalSectionLinkTap: _openSection,
        // Ticking a checkbox and changing a TODO state, saved at once
        // (#150).
        onListItemTap: writer == null
            ? null
            : (item) => _toggleCheckbox(writer, node, text, document, item),
        onSectionSlide: writer == null
            ? null
            : (section) =>
                _todoActions(writer, node, text, document, section),
        onSectionLongPress: writer == null
            ? null
            : (section) =>
                _chooseTodo(writer, node, text, document, section),
        loadImage: (link) =>
            loadMermaidDrawing(link) ??
            switch (files) {
              final files? => loadNoteImage(files, node.file, tree, link,
                  onRemove: switch (_editWriter) {
                    final writer? => () => _removeImage(writer, node, link),
                    null => null,
                  }),
              null => null,
            },
        child: tree is OrgSection
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: OpenSection(section: tree, state: state, child: body),
              )
            : body,
      ),
    );
  }
}

/// The actions of the node view's AI menu.
enum _AiAction { ask, share }

/// The edits of an existing note (v4).
enum _EditAction { append, edit, meta, ai, image, history }
