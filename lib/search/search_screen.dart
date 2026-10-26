import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_settings.dart';
import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../graph/ai_share.dart';
import '../edit/delete_dialog.dart';
import '../edit/set_language.dart';
import '../graph/node_search.dart';
import '../graph/roam_db.dart' show TextHit;
import '../graph/roam_graph.dart';
import '../graph_view/node_memory.dart';
import '../node_view/node_screen.dart';
import '../node_view/note_images.dart';
import '../platform/error_text.dart';

/// Finds a node by title, alias and tag (#9), as you type. A result opens
/// the node view (#8); its second action shows the node in the graph (#6).
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.graph,
    required this.readNote,
    this.files,
    required this.nodeMemory,
    this.onShowInGraph,
    this.openInOrgro,
    this.onOpenNode,
    this.writer,
    this.shareText = shareTextOut,
  });

  final ValueListenable<RoamGraph> graph;
  final NoteReader readNote;

  /// The folder's other files, for images in notes (#46); without
  /// them, image links are shown as text.
  final NoteFiles? files;
  final NodeMemory nodeMemory;

  /// Shows a node in the graph; the action is hidden when null.
  final void Function(BuildContext context, String id)? onShowInGraph;

  /// Opens a node's file in Orgro, for the node view.
  final NoteOpener? openInOrgro;

  /// Opens a result. When null, the node view opens on a new page; the
  /// tablet layout (#16) closes the search and shows it in its side pane.
  final void Function(BuildContext context, String id)? onOpenNode;

  /// Writes new notes, for the node view.
  final NoteWriter? writer;

  /// Sends text to an AI app (#41); tests replace it.
  final TextSharer shareText;

  /// Opens the search on a new page.
  static Future<void> open(
    BuildContext context, {
    required ValueListenable<RoamGraph> graph,
    required NoteReader readNote,
    NoteFiles? files,
    required NodeMemory nodeMemory,
    void Function(BuildContext context, String id)? onShowInGraph,
    NoteOpener? openInOrgro,
    void Function(BuildContext context, String id)? onOpenNode,
    NoteWriter? writer,
    TextSharer shareText = shareTextOut,
  }) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => SearchScreen(
            graph: graph,
            readNote: readNote,
            files: files,
            nodeMemory: nodeMemory,
            onShowInGraph: onShowInGraph,
            openInOrgro: openInOrgro,
            onOpenNode: onOpenNode,
            writer: writer,
            shareText: shareText,
          ),
        ),
      );

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  final _tags = <String>{};

  /// Nodes chosen with a long press, to share with an AI (#41).
  final _selected = <String>{};

  void _toggle(String id) => setState(
      () => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  /// Shares the selected nodes with an AI app, with their texts.
  Future<void> _shareSelected() async {
    final graph = widget.graph.value;
    final messenger = ScaffoldMessenger.of(context);
    // The saved settings, once loaded, so no saved hidden tag is missed.
    final visibility = (await AiSettingsScope.current(context)).visibility;
    if (!mounted) return;
    final chosen = [
      for (final id in _selected) ?graph.nodes[id],
    ];
    // Notes hidden from AI are left out (#57), also those whose file
    // hides them now, before the index knows.
    final files = <(RoamNode, String?)>[];
    for (final node in chosen) {
      if (visibility.hides(node)) continue;
      final file = await widget.readNote(node.file);
      if (file != null && visibility.hidesInText(node, file)) continue;
      files.add((node, file));
    }
    if (!mounted) return;
    final nodes = [for (final (node, _) in files) node];
    final hidden = chosen.length - nodes.length;
    if (nodes.isEmpty) {
      messenger.showSnackBar(SnackBar(
          content: Text(hidden == 1
              ? 'This note is hidden from AI by its tags, so it is not '
                  'shared.'
              : 'These notes are hidden from AI by their tags, so they are '
                  'not shared.')));
      return;
    }
    final text = nodesForAi(graph, files, visibility: visibility);
    if (!mounted) return;
    if (hidden > 0) {
      messenger.showSnackBar(SnackBar(
          content: Text(hidden == 1
              ? '1 selected note is hidden from AI by its tags and was '
                  'left out.'
              : '$hidden selected notes are hidden from AI by their tags '
                  'and were left out.')));
    }
    if (text.length > maxShareLength) {
      showErrorSnackBar(
          messenger,
          'These ${nodes.length} notes are too large to share '
          'at once (${text.length ~/ 1000} KB). Select fewer.');
      return;
    }
    try {
      await widget.shareText(text,
          subject: nodes.length == 1 ? nodes.single.displayTitle : null);
    } on PlatformException catch (e) {
      showErrorSnackBar(
          messenger, 'Could not share the notes: ${e.message ?? e.code}');
    }
  }

  Future<void> _deleteSelected() async {
    final writer = widget.writer;
    if (writer == null || writer.editor == null) return;
    final graph = widget.graph.value;
    final nodes = [for (final id in _selected) ?graph.nodes[id]];
    final messenger = ScaffoldMessenger.of(context);
    final deletion = await confirmDeleteNotes(context,
        graph: graph, nodes: nodes, writer: writer);
    if (deletion == null || !mounted) return;
    setState(() => _selected.clear());
    _textQuery = '';
    _searchText();
    showDeleted(messenger, deletion, writer);
  }

  Future<void> _setLanguageSelected() async {
    final writer = widget.writer;
    final editor = writer?.editor;
    if (writer == null || editor == null) return;
    final graph = widget.graph.value;
    final nodes = [for (final id in _selected) ?graph.nodes[id]];
    if (nodes.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final code = await askLanguage(context, nodes);
    if (code == null || !mounted) return;
    final report = await setNotesLanguage(
      editor: editor,
      log: writer.changeLog,
      graph: graph,
      nodes: nodes,
      code: code,
    );
    if (!mounted) return;
    setState(() => _selected.clear());
    showLanguageSet(messenger, report, writer);
  }

  /// Searching in the notes' text (#98) instead of titles and aliases.
  bool _inText = false;

  /// The text search's results for [_textQuery]; null while it runs.
  List<TextHit>? _textHits;
  String _textQuery = '';
  int _textSearches = 0;

  /// Runs the text search for the query as it is, if it changed.
  Future<void> _searchText() async {
    final files = widget.files;
    final query = _query.text.trim();
    if (!_inText || files == null || query == _textQuery) return;
    _textQuery = query;
    final search = ++_textSearches;
    setState(() => _textHits = null);
    final hits = query.isEmpty
        ? const <TextHit>[]
        : await files.searchText(query).catchError((Object _) => <TextHit>[]);
    // Only the latest search shows.
    if (mounted && search == _textSearches) setState(() => _textHits = hits);
  }

  @override
  void initState() {
    super.initState();
    _query.addListener(_changed);
    _query.addListener(_searchText);
    widget.graph.addListener(_changed);
  }

  @override
  void dispose() {
    widget.graph.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _open(String id) {
    if (widget.onOpenNode case final open?) {
      widget.nodeMemory.remember(id);
      Navigator.pop(context);
      open(context, id);
      return;
    }
    _openPage(id);
  }

  void _openPage(String id) => NodeScreen.open(
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
      );

  @override
  Widget build(BuildContext context) {
    final graph = widget.graph.value;
    // A selected tag that no node has any more is dropped.
    final allTags = tagsByUse(graph);
    _tags.retainAll(allTags);
    final hits = searchNodes(graph, _query.text, tags: _tags);
    final onShowInGraph = widget.onShowInGraph;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          decoration: InputDecoration(
            hintText: _inText ? 'Words in the notes' : 'Title or alias',
            border: InputBorder.none,
          ),
          textInputAction: TextInputAction.search,
          // The results as they are now, also before the next frame.
          onSubmitted: (query) {
            if (_inText) return;
            final first = searchNodes(widget.graph.value, query, tags: _tags)
                .firstOrNull;
            if (first != null) _open(first.node.id);
          },
        ),
        actions: [
          if (_selected.isNotEmpty)
            IconButton(
              tooltip: 'Share with AI',
              icon: Badge(
                label: Text('${_selected.length}'),
                child: const Icon(Icons.share_outlined),
              ),
              onPressed: _shareSelected,
            ),
          if (_selected.isNotEmpty && widget.writer?.editor != null)
            IconButton(
              tooltip: 'Set language…',
              icon: const Icon(Icons.translate),
              onPressed: _setLanguageSelected,
            ),
          if (_selected.isNotEmpty && widget.writer?.editor != null)
            IconButton(
              tooltip: 'Delete…',
              icon: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              onPressed: _deleteSelected,
            ),
          if (_query.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: _query.clear,
            ),
        ],
      ),
      body: Column(
        children: [
          if (widget.files != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  key: const ValueKey('search-in-text'),
                  avatar: const Icon(Icons.notes_outlined, size: 18),
                  label: const Text('In the text'),
                  selected: _inText,
                  onSelected: (on) {
                    setState(() {
                      _inText = on;
                      _textQuery = '';
                      _textHits = null;
                    });
                    _searchText();
                  },
                ),
              ),
            ),
          if (_inText)
            Expanded(child: _textResults(graph))
          else ...[
          if (allTags.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView(
                key: const ValueKey('tags'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final tag in allTags)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: FilterChip(
                        label: Text(tag),
                        selected: _tags.contains(tag),
                        onSelected: (on) => setState(
                            () => on ? _tags.add(tag) : _tags.remove(tag)),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                // A node found by its title and an alias counts twice.
                hits.length == 1 ? '1 result' : '${hits.length} results',
                key: const ValueKey('hit-count'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('hits'),
              itemCount: hits.length,
              itemBuilder: (context, i) {
                final hit = hits[i];
                final node = hit.node;
                final details = [
                  if (hit.alias != null) 'Alias of ${node.displayTitle}',
                  if (node.tags.isNotEmpty) node.tags.join(' '),
                ].join(' · ');
                final selected = _selected.contains(node.id);
                return ListTile(
                  key: ValueKey('hit-$i'),
                  selected: selected,
                  leading: _selected.isEmpty
                      ? null
                      : Icon(selected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank),
                  onLongPress: () => _toggle(node.id),
                  title: Text(hit.text),
                  subtitle: details.isEmpty ? null : Text(details),
                  // While nodes are selected, a tap adds or removes one.
                  onTap: () =>
                      _selected.isEmpty ? _open(node.id) : _toggle(node.id),
                  trailing: onShowInGraph == null
                      ? null
                      : IconButton(
                          tooltip: 'Show in graph',
                          icon: const Icon(Icons.hub_outlined),
                          onPressed: () {
                            widget.nodeMemory.remember(node.id);
                            onShowInGraph(context, node.id);
                          },
                        ),
                );
              },
            ),
          ),
          ],
        ],
      ),
    );
  }

  /// The notes whose text has the words: the file's node, or its first
  /// node, with a snippet of the text around the match.
  Widget _textResults(RoamGraph graph) {
    final hits = _textHits;
    if (_query.text.trim().isEmpty) {
      return const Center(child: Text('Type words to find in the notes.'));
    }
    if (hits == null) return const Center(child: CircularProgressIndicator());
    final rows = <(RoamNode, String)>[];
    for (final hit in hits) {
      final inFile = [
        for (final node in graph.nodes.values)
          if (node.file == hit.path) node,
      ];
      if (inFile.isEmpty) continue;
      final node =
          inFile.where((n) => n.isFile).firstOrNull ?? inFile.first;
      rows.add((node, hit.snippet.replaceAll(RegExp(r'\s+'), ' ').trim()));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              rows.length == 1 ? '1 note' : '${rows.length} notes',
              key: const ValueKey('text-hit-count'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            key: const ValueKey('text-hits'),
            children: [
              for (final (i, (node, snippet)) in rows.indexed)
                ListTile(
                  key: ValueKey('text-hit-$i'),
                  title: Text(node.displayTitle),
                  subtitle:
                      Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
                  selected: _selected.contains(node.id),
                  onLongPress: () => _toggle(node.id),
                  onTap: () => _selected.isEmpty
                      ? _open(node.id) : _toggle(node.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
