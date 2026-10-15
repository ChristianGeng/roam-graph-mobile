import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../graph/backlinks.dart';
import '../graph/roam_graph.dart';
import '../graph_view/node_memory.dart';
import '../search/search_screen.dart';

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
    required this.nodeMemory,
    this.onShowInGraph,
    this.openInOrgro,
  });

  final ValueListenable<RoamGraph> graph;
  final String id;
  final NoteReader readNote;
  final NodeMemory nodeMemory;

  /// Opens the node's file in Orgro; the button is hidden when null.
  final NoteOpener? openInOrgro;

  /// Shows the node [id] in the graph view (#6); the button is hidden when
  /// null.
  final void Function(BuildContext context, String id)? onShowInGraph;

  /// Opens the node [id] on a new page, with the same graph and callbacks.
  static Future<void> open(
    BuildContext context, {
    required ValueListenable<RoamGraph> graph,
    required String id,
    required NoteReader readNote,
    required NodeMemory nodeMemory,
    void Function(BuildContext context, String id)? onShowInGraph,
    NoteOpener? openInOrgro,
  }) {
    nodeMemory.remember(id);
    return Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => NodeScreen(
          graph: graph,
          id: id,
          readNote: readNote,
          nodeMemory: nodeMemory,
          onShowInGraph: onShowInGraph,
          openInOrgro: openInOrgro,
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

  void _openId(String id) {
    if (!widget.graph.value.nodes.containsKey(id)) {
      _tell('There is no node with the ID $id.');
      return;
    }
    NodeScreen.open(
      context,
      graph: widget.graph,
      id: id,
      readNote: widget.readNote,
      nodeMemory: widget.nodeMemory,
      onShowInGraph: widget.onShowInGraph,
      openInOrgro: widget.openInOrgro,
    );
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
        title: Text(node?.displayTitle ?? 'Node'),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => SearchScreen.open(
              context,
              graph: widget.graph,
              readNote: widget.readNote,
              nodeMemory: widget.nodeMemory,
              onShowInGraph: onShowInGraph,
              openInOrgro: widget.openInOrgro,
            ),
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
    final document = OrgDocument.parse(text);
    final OrgTree? tree =
        node.isFile ? document : document.sectionWithId(node.id);
    if (tree == null) {
      // The file changed since it was indexed; the next scan fixes it.
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('The heading is no longer in ${node.file}.'),
      );
    }
    final settings = OrgSettings(startupFolded: OrgVisibilityState.subtree);
    return OrgController(
      // A new controller for new text, so the folding starts again.
      key: ValueKey(text),
      root: tree,
      settings: settings,
      child: OrgRootWidget(
        onLinkTap: _openLink,
        onLocalSectionLinkTap: _openSection,
        child: tree is OrgSection
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: OrgSectionWidget(tree),
              )
            : OrgDocumentWidget(document, shrinkWrap: true),
      ),
    );
  }
}
