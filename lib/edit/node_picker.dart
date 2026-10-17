import 'package:material_ui/material_ui.dart';

import '../graph/roam_graph.dart';

/// Chooses the node shared text goes to (#39): the node viewed last first,
/// then every node whose title, alias or tag holds the typed text.
class NodePicker extends StatefulWidget {
  const NodePicker({super.key, required this.graph, this.proposed});

  final RoamGraph graph;
  final RoamNode? proposed;

  static Future<RoamNode?> pick(
    BuildContext context,
    RoamGraph graph, {
    RoamNode? proposed,
    String title = 'Choose a node',
  }) =>
      Navigator.of(context).push<RoamNode>(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: NodePicker(graph: graph, proposed: proposed),
        ),
      ));

  @override
  State<NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<NodePicker> {
  String _query = '';

  List<RoamNode> get _matches {
    final q = _query.trim().toLowerCase();
    final nodes = widget.graph.nodes.values
        .where((n) =>
            q.isEmpty ||
            n.displayTitle.toLowerCase().contains(q) ||
            n.aliases.any((a) => a.toLowerCase().contains(q)) ||
            n.tags.any((t) => t.toLowerCase().contains(q)))
        .toList()
      ..sort((a, b) => a.displayTitle
          .toLowerCase()
          .compareTo(b.displayTitle.toLowerCase()));
    return nodes;
  }

  @override
  Widget build(BuildContext context) {
    final proposed = widget.proposed;
    final matches = _matches;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            key: const ValueKey('picker-search'),
            autofocus: proposed == null,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Title, alias or tag',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              if (proposed != null && _query.isEmpty)
                ListTile(
                  key: const ValueKey('picker-proposed'),
                  leading: const Icon(Icons.history),
                  title: Text(proposed.displayTitle),
                  subtitle: const Text('Viewed last'),
                  onTap: () => Navigator.of(context).pop(proposed),
                ),
              for (final node in matches.take(200))
                ListTile(
                  title: Text(node.displayTitle),
                  subtitle: Text(node.file),
                  onTap: () => Navigator.of(context).pop(node),
                ),
              if (matches.length > 200)
                ListTile(
                  title: Text('${matches.length - 200} more; type to '
                      'narrow the list.'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
