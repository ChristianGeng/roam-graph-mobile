import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_settings.dart';
import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../graph/ai_share.dart';
import '../graph/node_search.dart';
import '../graph/roam_graph.dart';
import '../graph_view/node_memory.dart';
import '../node_view/node_screen.dart';
import '../node_view/note_images.dart';

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
    final visibility = AiSettingsScope.of(context).visibility;
    final messenger = ScaffoldMessenger.of(context);
    final chosen = [
      for (final id in _selected) ?graph.nodes[id],
    ];
    // Notes hidden from AI are left out (#57).
    final nodes = [
      for (final node in chosen)
        if (!visibility.hides(node)) node,
    ];
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
    final files = <(RoamNode, String?)>[
      for (final node in nodes) (node, await widget.readNote(node.file)),
    ];
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
      messenger.showSnackBar(SnackBar(
          content: Text('These ${nodes.length} notes are too large to share '
              'at once (${text.length ~/ 1000} KB). Select fewer.')));
      return;
    }
    try {
      await widget.shareText(text,
          subject: nodes.length == 1 ? nodes.single.displayTitle : null);
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text('Could not share the notes: ${e.message ?? e.code}')));
    }
  }

  @override
  void initState() {
    super.initState();
    _query.addListener(_changed);
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
          decoration: const InputDecoration(
            hintText: 'Title or alias',
            border: InputBorder.none,
          ),
          textInputAction: TextInputAction.search,
          // The results as they are now, also before the next frame.
          onSubmitted: (query) {
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
      ),
    );
  }
}
