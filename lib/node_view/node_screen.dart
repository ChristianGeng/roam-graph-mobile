import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../ai/ai_settings.dart';
import '../ai/chat_screen.dart';
import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../edit/append_screen.dart';
import '../edit/history_screen.dart';
import '../graph/ai_share.dart';
import '../graph/backlinks.dart';
import '../graph/roam_graph.dart';
import '../graph_view/node_memory.dart';
import '../settings/view_settings.dart';
import 'folding.dart';
import 'latex.dart';
import 'mermaid.dart';
import 'src_languages.dart';
import '../search/search_screen.dart';
import 'note_images.dart';

/// Reads a note's text, by its path relative to `roam/`; null if it cannot
/// be read.
typedef NoteReader = Future<String?> Function(String path);

/// Orgro's application ID (its `build.gradle`).
const orgroPackage = 'com.madlonkay.orgro';

/// What happened when a note was to be opened in Orgro.
enum OpenResult { opened, noOrgro, noFile }

/// Opens a note in Orgro (#10), by its path relative to `roam/`.
typedef NoteOpener = Future<OpenResult> Function(String path);

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
    } else {
      _tell('This app opens only id: links, not "$location".');
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
      help: widget.help,
    );
  }

  /// Captures a new node that links to [node] (#12), and opens it.
  Future<void> _capture(NoteWriter writer, RoamNode node) async {
    final id = await CaptureScreen.open(
      context,
      writer,
      linkTo: (id: node.id, title: node.displayTitle),
    );
    if (id != null && mounted) _openId(id);
  }

  /// Adds text at the end of [node] (#36). The index changes after the
  /// save, so the note is read again and shows the text.
  Future<void> _append(NoteWriter writer, RoamNode node) async {
    if (await AppendScreen.open(context, writer, node) && mounted) {
      _tell('Added to ${node.displayTitle}.');
    }
  }

  /// Opens the node's file in Orgro, at the top: Orgro has no way to jump
  /// to a heading from outside (decision 6).
  Future<void> _openInOrgro(NoteOpener open, RoamNode node) async {
    final result = await open(node.file);
    if (!mounted) return;
    switch (result) {
      case OpenResult.opened:
        if (!node.isFile) {
          _tell('Orgro opens ${node.file} at the top; '
              'it cannot jump to the heading.');
        }
      case OpenResult.noOrgro:
        _tell('Orgro is not installed.');
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
        ),
      );

  void _tell(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
                _EditAction.history => HistoryScreen.open(context, writer, node),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: _EditAction.append,
                    child: Text('Add to this node')),
                PopupMenuItem(
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
              tooltip: 'Open in Orgro',
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
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _content(context, node, snapshot.data);
              },
            ),
    );
  }

  Widget _content(BuildContext context, RoamNode node, String? text) {
    final backlinks = backlinksOf(widget.graph.value, node.id);
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
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            backlinks.isEmpty
                ? 'No backlinks'
                : 'Backlinks: ${backlinks.length}',
            style: textTheme.titleMedium,
          ),
        ),
        for (final (i, backlink) in backlinks.indexed)
          ListTile(
            key: ValueKey('backlink-$i'),
            title: Text(backlink.source.displayTitle),
            subtitle: Text(backlink.outline),
            onTap: () => _openId(backlink.source.id),
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
      withDisplayFormulas(withHighlightLanguages(OrgDocument.parse(text))),
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
    return OrgController(
      // A new controller for new text or a new setting, so the folding
      // starts again.
      key: ValueKey((text, state)),
      root: tree,
      settings: OrgSettings(startupFolded: state),
      child: OrgRootWidget(
        onLinkTap: _openLink,
        onLocalSectionLinkTap: _openSection,
        loadImage: (link) =>
            loadMermaidDrawing(link) ??
            switch (files) {
              final files? => loadNoteImage(files, node.file, tree, link),
              null => null,
            },
        child: tree is OrgSection
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: OpenSection(
                  section: tree,
                  state: state,
                  child: OrgSectionWidget(tree),
                ),
              )
            : OrgDocumentWidget(document, shrinkWrap: true),
      ),
    );
  }
}

/// The actions of the node view's AI menu.
enum _AiAction { ask, share }

/// The edits of an existing note (v4).
enum _EditAction { append, history }
