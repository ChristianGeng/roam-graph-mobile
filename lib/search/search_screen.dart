import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../graph/node_search.dart';
import '../graph/roam_graph.dart';
import '../graph_view/node_memory.dart';
import '../node_view/node_screen.dart';

/// Finds a node by title, alias and tag (#9), as you type. A result opens
/// the node view (#8); its second action shows the node in the graph (#6).
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.graph,
    required this.readNote,
    required this.nodeMemory,
    this.onShowInGraph,
  });

  final ValueListenable<RoamGraph> graph;
  final NoteReader readNote;
  final NodeMemory nodeMemory;

  /// Shows a node in the graph; the action is hidden when null.
  final void Function(BuildContext context, String id)? onShowInGraph;

  /// Opens the search on a new page.
  static Future<void> open(
    BuildContext context, {
    required ValueListenable<RoamGraph> graph,
    required NoteReader readNote,
    required NodeMemory nodeMemory,
    void Function(BuildContext context, String id)? onShowInGraph,
  }) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => SearchScreen(
            graph: graph,
            readNote: readNote,
            nodeMemory: nodeMemory,
            onShowInGraph: onShowInGraph,
          ),
        ),
      );

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  final _tags = <String>{};

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

  void _open(String id) => NodeScreen.open(
        context,
        graph: widget.graph,
        id: id,
        readNote: widget.readNote,
        nodeMemory: widget.nodeMemory,
        onShowInGraph: widget.onShowInGraph,
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
                hits.length == 1 ? '1 node' : '${hits.length} nodes',
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
                return ListTile(
                  key: ValueKey('hit-$i'),
                  title: Text(hit.text),
                  subtitle: details.isEmpty ? null : Text(details),
                  onTap: () => _open(node.id),
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
