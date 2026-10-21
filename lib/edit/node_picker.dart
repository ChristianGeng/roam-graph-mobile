import 'package:material_ui/material_ui.dart';

import '../capture/new_node.dart';
import '../graph/roam_graph.dart';

/// What was chosen to link to (#135): an existing note, or the title of a
/// new one to make.
sealed class LinkChoice {
  const LinkChoice();
}

class ChosenNode extends LinkChoice {
  const ChosenNode(this.node);

  final RoamNode node;
}

class NewNoteTitle extends LinkChoice {
  const NewNoteTitle(this.title);

  final String title;
}

/// Chooses a node: the node viewed last first, then every node whose
/// title, alias or tag holds the typed text. For shared text (#39), and
/// for links (#135), where the nodes in [excluded] are left out and, with
/// [offerNew], the typed text can become a new note, as
/// `org-roam-node-insert` offers it.
class NodePicker extends StatefulWidget {
  const NodePicker({
    super.key,
    required this.graph,
    this.proposed,
    this.excluded = const {},
    this.offerNew = false,
  });

  final RoamGraph graph;
  final RoamNode? proposed;

  /// The IDs of nodes not to offer.
  final Set<String> excluded;

  /// Whether the list offers `New note "<text>"` first when the typed text
  /// is not exactly a node's title.
  final bool offerNew;

  static Future<RoamNode?> pick(
    BuildContext context,
    RoamGraph graph, {
    RoamNode? proposed,
    String title = 'Choose a node',
  }) async =>
      switch (await _open(context, graph, title,
          proposed: proposed, excluded: const {}, offerNew: false)) {
        ChosenNode(:final node) => node,
        _ => null,
      };

  /// Chooses what to link to: a node other than [excluded], or a new note.
  static Future<LinkChoice?> pickForLink(
    BuildContext context,
    RoamGraph graph, {
    RoamNode? proposed,
    Set<String> excluded = const {},
    String title = 'Link to',
  }) =>
      _open(context, graph, title,
          proposed: proposed, excluded: excluded, offerNew: true);

  static Future<LinkChoice?> _open(
    BuildContext context,
    RoamGraph graph,
    String title, {
    required RoamNode? proposed,
    required Set<String> excluded,
    required bool offerNew,
  }) =>
      Navigator.of(context).push<LinkChoice>(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: NodePicker(
            graph: graph,
            proposed: proposed,
            excluded: excluded,
            offerNew: offerNew,
          ),
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
            !widget.excluded.contains(n.id) &&
            (q.isEmpty ||
                n.displayTitle.toLowerCase().contains(q) ||
                n.aliases.any((a) => a.toLowerCase().contains(q)) ||
                n.tags.any((t) => t.toLowerCase().contains(q))))
        .toList()
      ..sort((a, b) => a.displayTitle
          .toLowerCase()
          .compareTo(b.displayTitle.toLowerCase()));
    return nodes;
  }

  void _choose(LinkChoice choice) => Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) {
    final proposed = switch (widget.proposed) {
      final node? when !widget.excluded.contains(node.id) => node,
      _ => null,
    };
    final matches = _matches;
    final typed = oneLine(_query);
    final newNote = widget.offerNew &&
        typed.isNotEmpty &&
        !widget.graph.nodes.values.any((n) => n.title == typed);
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
              if (newNote)
                ListTile(
                  key: const ValueKey('picker-new'),
                  leading: const Icon(Icons.note_add_outlined),
                  title: Text('New note "$typed"'),
                  onTap: () => _choose(NewNoteTitle(typed)),
                ),
              if (proposed != null && _query.isEmpty)
                ListTile(
                  key: const ValueKey('picker-proposed'),
                  leading: const Icon(Icons.history),
                  title: Text(proposed.displayTitle),
                  subtitle: const Text('Viewed last'),
                  onTap: () => _choose(ChosenNode(proposed)),
                ),
              for (final node in matches.take(200))
                ListTile(
                  title: Text(node.displayTitle),
                  subtitle: Text(node.file),
                  onTap: () => _choose(ChosenNode(node)),
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
