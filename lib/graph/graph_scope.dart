/// What the graph view draws (#6): the nodes and edges `org-roam-graph`
/// would put into its Graphviz file.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'dart:collection';

import 'char_width.dart';
import 'roam_graph.dart';

/// org-roam's `org-roam-graph-max-title-length`, in columns; wider titles
/// are cut, as with its default `org-roam-graph-shorten-titles`
/// (`truncate`).
const maxTitleLength = 100;

/// A node in the drawing. [node] is null for the target of an `id:` link
/// that is no node; org-roam draws those too, labelled `id:<target>`.
class DrawnNode {
  const DrawnNode({required this.id, required this.label, this.node});

  final String id;
  final String label;
  final RoamNode? node;

  bool get isMissing => node == null;
}

/// A directed edge: one or more `id:` links from [source] to [dest].
typedef DrawnEdge = ({String source, String dest});

/// Which part of the graph to draw. The three choices of `org-roam-graph`:
/// no prefix argument, `C-u` and `C-u N`.
sealed class GraphScope {
  const GraphScope();
}

/// The whole graph, with every node, also nodes without links.
class WholeGraph extends GraphScope {
  const WholeGraph();

  @override
  bool operator ==(Object other) => other is WholeGraph;

  @override
  int get hashCode => 0;
}

/// The nodes connected to [id], directly or through other nodes, as with
/// `C-u M-x org-roam-graph`.
class ConnectedPart extends GraphScope {
  const ConnectedPart(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is ConnectedPart && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The nodes up to [steps] links away from [id], as with
/// `C-u N M-x org-roam-graph`. Links count in both directions.
class Neighbourhood extends GraphScope {
  const Neighbourhood(this.id, this.steps) : assert(steps >= 1);

  final String id;
  final int steps;

  @override
  bool operator ==(Object other) =>
      other is Neighbourhood && other.id == id && other.steps == steps;

  @override
  int get hashCode => Object.hash(id, steps);
}

/// The nodes and edges to draw.
class DrawnGraph {
  DrawnGraph._(this.nodes, this.edges);

  /// Builds the drawing of [scope], as `org-roam-graph--dot` does.
  ///
  /// The edges are the distinct `(source, dest)` pairs of the `id:` links;
  /// org-roam's `SELECT DISTINCT source, dest, type FROM links` keeps one
  /// edge per pair and type, and the other types are hidden by my
  /// `org-roam-graph-link-hidden-types` (decision 7). Nodes appear in the
  /// order org-roam writes them: the ends of each edge, then, for the whole
  /// graph, the nodes without edges.
  ///
  /// For a [ConnectedPart] or [Neighbourhood], org-roam draws only the ends
  /// of the edges it selected, so a node without links would give an empty
  /// drawing. Here the centre node is always drawn.
  factory DrawnGraph.of(RoamGraph graph, GraphScope scope) {
    final pairs = <DrawnEdge>{};
    for (final link in graph.links) {
      pairs.add((source: link.source, dest: link.dest));
    }
    final List<DrawnEdge> edges;
    switch (scope) {
      case WholeGraph():
        edges = pairs.toList();
      case ConnectedPart(:final id):
        final inner = _reachable(pairs, id, null);
        edges = _touching(pairs, inner);
      case Neighbourhood(:final id, :final steps):
        final inner = _reachable(pairs, id, steps - 1);
        edges = _touching(pairs, inner);
    }
    final nodes = <String, DrawnNode>{};
    void add(String id) => nodes.putIfAbsent(id, () => _drawn(graph, id));
    switch (scope) {
      case ConnectedPart(:final id) || Neighbourhood(:final id):
        add(id);
      case WholeGraph():
    }
    for (final edge in edges) {
      add(edge.source);
      add(edge.dest);
    }
    if (scope is WholeGraph) graph.nodes.keys.forEach(add);
    return DrawnGraph._(nodes.values.toList(), edges);
  }

  final List<DrawnNode> nodes;
  final List<DrawnEdge> edges;

  /// The nodes linked to each node, in both directions, without the node
  /// itself.
  late final Map<String, Set<String>> neighbours = () {
    final result = {for (final node in nodes) node.id: <String>{}};
    for (final (:source, :dest) in edges) {
      if (source == dest) continue;
      result[source]!.add(dest);
      result[dest]!.add(source);
    }
    return result;
  }();
}

DrawnNode _drawn(RoamGraph graph, String id) {
  final node = graph.nodes[id];
  if (node == null) return DrawnNode(id: id, label: 'id:$id');
  return DrawnNode(id: id, label: truncateTitle(node.displayTitle), node: node);
}

/// [title] cut to [maxTitleLength] columns, the last three being `...`, as
/// Emacs's `truncate-string-to-width` does for org-roam.
///
/// Columns are counted as Emacs counts them ([charWidth]): a CJK character
/// takes two. org-roam cuts the title after escaping `\` and `"` for
/// Graphviz, so these take two columns each. Unlike Emacs, the cut never
/// falls between such a character and its escape.
String truncateTitle(String title) {
  int width(int rune) =>
      rune == 0x5C || rune == 0x22 ? 2 : charWidth(rune);
  final runes = title.runes.toList();
  if (runes.fold(0, (sum, rune) => sum + width(rune)) <= maxTitleLength) {
    return title;
  }
  // Characters while they fit into the columns before the `...`, and none
  // after these are full, not even one without width.
  const limit = maxTitleLength - 3;
  final kept = StringBuffer();
  var used = 0;
  for (final rune in runes) {
    if (used >= limit || used + width(rune) > limit) break;
    used += width(rune);
    kept.writeCharCode(rune);
  }
  return '$kept...';
}

/// The columns Emacs's `char-width` gives the character [rune]: 2 for CJK
/// characters and most emoji, 0 for combining marks, otherwise mostly 1.
int charWidth(int rune) {
  // Binary search in the ranges (first, last, width) of charWidthRanges.
  var low = 0, high = charWidthRanges.length ~/ 3 - 1;
  while (low <= high) {
    final middle = (low + high) ~/ 2;
    if (rune < charWidthRanges[middle * 3]) {
      high = middle - 1;
    } else if (rune > charWidthRanges[middle * 3 + 1]) {
      low = middle + 1;
    } else {
      return charWidthRanges[middle * 3 + 2];
    }
  }
  return 1;
}

/// The nodes org-roam's recursive query in
/// `org-roam-graph--connected-component` visits from [start], following
/// links in both directions.
///
/// With [maxDistance] null (`C-u`), every node reachable from a neighbour
/// of [start]; [start] itself only if a link leads back to it. Otherwise
/// (`C-u N`, with [maxDistance] N - 1), [start] and the nodes up to
/// [maxDistance] links away: the query stops a path when its trace holds N
/// nodes.
Set<String> _reachable(
  Iterable<DrawnEdge> edges,
  String start,
  int? maxDistance,
) {
  final neighbours = <String, Set<String>>{};
  for (final (:source, :dest) in edges) {
    neighbours.putIfAbsent(source, () => {}).add(dest);
    neighbours.putIfAbsent(dest, () => {}).add(source);
  }
  if (maxDistance == null) {
    final seen = <String>{};
    final queue = Queue.of(neighbours[start] ?? const <String>{});
    while (queue.isNotEmpty) {
      final id = queue.removeFirst();
      if (seen.add(id)) queue.addAll(neighbours[id] ?? const <String>{});
    }
    return seen;
  }
  // A breadth-first search gives every node its shortest distance, which
  // is the shortest trace the query finds for it.
  final distance = {start: 0};
  final queue = Queue.of([start]);
  while (queue.isNotEmpty) {
    final id = queue.removeFirst();
    final d = distance[id]!;
    if (d == maxDistance) continue;
    for (final next in neighbours[id] ?? const <String>{}) {
      if (!distance.containsKey(next)) {
        distance[next] = d + 1;
        queue.add(next);
      }
    }
  }
  return distance.keys.toSet();
}

/// The edges with an end in [inner]: org-roam's final
/// `WHERE source IN ... OR dest IN ...`.
List<DrawnEdge> _touching(Iterable<DrawnEdge> edges, Set<String> inner) => [
      for (final edge in edges)
        if (inner.contains(edge.source) || inner.contains(edge.dest)) edge,
    ];
