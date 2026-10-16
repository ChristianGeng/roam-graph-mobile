/// The graph as text for an AI app on the device (#40): the Claude Android
/// app reads text shared to it, but cannot read device folders.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'roam_graph.dart';

/// The connectivity of [graph]: every node's ID, title and tags, and every
/// pair of nodes with an `id:` link, with a header that says how to answer.
/// Note texts are left out, to keep it small enough for one chat; a node's
/// text is shared on request (#41).
///
/// Nodes get short numbers (`n1`, `n2`, …) for the link list, which would
/// otherwise repeat each 36-character ID thousands of times. Nodes are in
/// title order; links in the order of their source, then target.
String graphForAi(RoamGraph graph) {
  final nodes = graph.nodes.values.toList()
    ..sort((a, b) {
      final byTitle =
          a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase());
      return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
    });
  final number = {
    for (var i = 0; i < nodes.length; i++) nodes[i].id: 'n${i + 1}',
  };
  final pairs = <(int, int)>{};
  final index = {for (var i = 0; i < nodes.length; i++) nodes[i].id: i};
  for (final link in graph.links) {
    final source = index[link.source], target = index[link.dest];
    // Links to IDs that are no node are left out: there is nothing to read.
    if (source != null && target != null) pairs.add((source, target));
  }
  final links = pairs.toList()
    ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));

  final text = StringBuffer()
    ..writeln('# My org-roam graph: ${nodes.length} nodes, '
        '${links.length} links')
    ..writeln()
    ..writeln('This is the structure of my notes (org-roam, Org mode), '
        'shared from the app Roam Graph. It has no note texts.')
    ..writeln('- Each node has a short number (n1, n2, …), its ID, its '
        'tags (- for none) and its title, in this order, separated by " | ". '
        'The title comes last and may itself contain " | ".')
    ..writeln('- "n3 -> n17" means: node n3 links to node n17.')
    ..writeln('- To read a node, ask me for it by title; I will share its '
        'text, its links and its backlinks.')
    ..writeln('- When you write a new note for me, link to existing nodes '
        'with their ID, in Org syntax: [[id:<ID>][<title>]]. Put the '
        "note's title on its first line.")
    ..writeln()
    ..writeln('## Nodes (number | ID | tags | title)');
  for (final node in nodes) {
    final tags = node.tags.isEmpty ? '-' : node.tags.join(' ');
    text.writeln('${number[node.id]} | ${node.id} | $tags | '
        '${_oneLine(node.displayTitle)}');
  }
  text
    ..writeln()
    ..writeln('## Links (source -> target)');
  for (final (source, target) in links) {
    text.writeln('n${source + 1} -> n${target + 1}');
  }
  return text.toString();
}

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
