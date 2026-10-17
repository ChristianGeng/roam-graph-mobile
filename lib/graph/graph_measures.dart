/// More of the measures my org-roam MCP server computes with networkx
/// 3.6.1, for the AI tools (#58): betweenness, closeness, clustering,
/// components, distances, and the shortest simple paths. Each function
/// says which networkx function it follows; the graph is the server's
/// [AlgorithmGraph] (decision 30).
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'dart:collection';

import 'graph_algorithms.dart';

/// networkx's `betweenness_centrality(G)` on the directed graph: Brandes'
/// algorithm, without endpoints, normalized by `1 / ((n - 1) (n - 2))`.
Map<String, double> betweenness(AlgorithmGraph graph) {
  final nodes = graph.nodes;
  final result = {for (final id in nodes) id: 0.0};
  for (final s in nodes) {
    // _single_source_shortest_path_basic
    final stack = <String>[];
    final predecessors = {for (final id in nodes) id: <String>[]};
    final sigma = {for (final id in nodes) id: 0.0};
    final distance = <String, int>{s: 0};
    sigma[s] = 1;
    final queue = Queue<String>()..add(s);
    while (queue.isNotEmpty) {
      final v = queue.removeFirst();
      stack.add(v);
      final dv = distance[v]!;
      final sv = sigma[v]!;
      for (final w in graph.successors[v]!) {
        if (!distance.containsKey(w)) {
          queue.add(w);
          distance[w] = dv + 1;
        }
        if (distance[w] == dv + 1) {
          sigma[w] = sigma[w]! + sv;
          predecessors[w]!.add(v);
        }
      }
    }
    // _accumulate_basic
    final delta = {for (final id in stack) id: 0.0};
    while (stack.isNotEmpty) {
      final w = stack.removeLast();
      final coefficient = (1 + delta[w]!) / sigma[w]!;
      for (final v in predecessors[w]!) {
        delta[v] = delta[v]! + sigma[v]! * coefficient;
      }
      if (w != s) result[w] = result[w]! + delta[w]!;
    }
  }
  // _rescale, normalized, endpoints false: N = n - 1.
  final n = nodes.length - 1;
  if (n >= 2) {
    final scale = 1 / (n * (n - 1));
    for (final id in nodes) {
      result[id] = result[id]! * scale;
    }
  }
  return result;
}

/// The distance from [source] to each node it reaches by [next], itself at
/// 0, in breadth-first order (networkx's
/// `single_source_shortest_path_length`).
Map<String, int> distancesFrom(
  String source,
  Iterable<String> Function(String id) next,
) {
  final distance = <String, int>{source: 0};
  final queue = Queue<String>()..add(source);
  while (queue.isNotEmpty) {
    final v = queue.removeFirst();
    for (final w in next(v)) {
      if (distance.containsKey(w)) continue;
      distance[w] = distance[v]! + 1;
      queue.add(w);
    }
  }
  return distance;
}

/// networkx's `closeness_centrality(G)` on the directed graph: by the
/// distances *to* each node (networkx reverses a directed graph), with
/// Wasserman and Faust's scaling for nodes that not all others reach.
Map<String, double> closeness(AlgorithmGraph graph) {
  final n = graph.nodes.length;
  return {
    for (final id in graph.nodes)
      id: () {
        final reached = distancesFrom(id, (v) => graph.predecessors[v]!);
        final total = reached.values.fold(0, (a, b) => a + b);
        if (total <= 0 || n <= 1) return 0.0;
        final r = reached.length - 1;
        return r / total * (r / (n - 1));
      }(),
  };
}

/// networkx's `clustering(G)` on the directed graph without weights:
/// directed triangles over `(d (d - 1) - 2 d↔) 2`, where `d` counts the
/// node's predecessors and successors and `d↔` those it has both ways.
/// A node's link to itself does not count.
double clustering(AlgorithmGraph graph, String id) {
  Set<String> without(Iterable<String> ids, String self) => {
    for (final x in ids)
      if (x != self) x,
  };
  final ipreds = without(graph.predecessors[id]!, id);
  final isuccs = without(graph.successors[id]!, id);
  var triangles = 0;
  for (final j in [...ipreds, ...isuccs]) {
    final jpreds = without(graph.predecessors[j]!, j);
    final jsuccs = without(graph.successors[j]!, j);
    triangles +=
        ipreds.intersection(jpreds).length +
        ipreds.intersection(jsuccs).length +
        isuccs.intersection(jpreds).length +
        isuccs.intersection(jsuccs).length;
  }
  if (triangles == 0) return 0;
  final total = ipreds.length + isuccs.length;
  final both = ipreds.intersection(isuccs).length;
  return triangles / ((total * (total - 1) - 2 * both) * 2);
}

/// networkx's `average_clustering(G)`: the mean of [clustering] over all
/// nodes, zeros included.
double averageClustering(AlgorithmGraph graph) {
  if (graph.nodes.isEmpty) return 0;
  final sum = graph.nodes.fold(0.0, (s, id) => s + clustering(graph, id));
  return sum / graph.nodes.length;
}

/// The neighbours of [id] in both directions, as in networkx's
/// `to_undirected()`.
Iterable<String> undirectedNeighbours(AlgorithmGraph graph, String id) => {
  ...graph.successors[id]!,
  ...graph.predecessors[id]!,
};

/// networkx's `weakly_connected_components(G)`: links in either direction
/// connect; components in the order of their first node in
/// [AlgorithmGraph.nodes].
List<Set<String>> weaklyConnectedComponents(AlgorithmGraph graph) {
  final seen = <String>{};
  final components = <Set<String>>[];
  for (final id in graph.nodes) {
    if (seen.contains(id)) continue;
    final component = distancesFrom(
      id,
      (v) => undirectedNeighbours(graph, v),
    ).keys.toSet();
    seen.addAll(component);
    components.add(component);
  }
  return components;
}

/// The number of links of each node as networkx's `G.degree()` counts them:
/// links out plus links in; a link to itself counts twice.
int degree(AlgorithmGraph graph, String id) =>
    graph.successors[id]!.length + graph.predecessors[id]!.length;

/// The number of edges, as networkx's `number_of_edges()`: pairs of nodes
/// with a link, a node's link to itself included.
int edgeCount(AlgorithmGraph graph) =>
    graph.nodes.fold(0, (sum, id) => sum + graph.successors[id]!.length);

/// Up to [count] shortest paths from [source] to [target] that visit no
/// node twice, of at most [maxLinks] links, following links in their
/// direction; the shortest first (Yen's algorithm, as networkx's
/// `shortest_simple_paths`). Of equally short paths, the one a
/// breadth-first search in link order finds first comes first. A path
/// from a node to itself is the node alone.
List<List<String>> shortestSimplePaths(
  AlgorithmGraph graph,
  String source,
  String target, {
  int count = 3,
  int maxLinks = 8,
}) {
  if (!graph.successors.containsKey(source) ||
      !graph.successors.containsKey(target)) {
    return const [];
  }
  if (source == target) {
    return [
      [source],
    ];
  }

  /// The shortest path from [from] to [target] avoiding [nodes] and the
  /// links in [links], in breadth-first link order; null if none.
  List<String>? shortest(
    String from,
    Set<String> nodes,
    Set<(String, String)> links,
  ) {
    final previous = <String, String>{from: from};
    var frontier = [from];
    while (frontier.isNotEmpty) {
      final next = <String>[];
      for (final v in frontier) {
        for (final w in graph.successors[v]!) {
          if (previous.containsKey(w) ||
              nodes.contains(w) ||
              links.contains((v, w))) {
            continue;
          }
          previous[w] = v;
          if (w == target) {
            final path = [w];
            while (path.last != from) {
              path.add(previous[path.last]!);
            }
            return path.reversed.toList();
          }
          next.add(w);
        }
      }
      frontier = next;
    }
    return null;
  }

  final first = shortest(source, const {}, const {});
  if (first == null || first.length - 1 > maxLinks) return const [];
  final found = [first];
  // Candidates, the shorter first, then in the order found.
  final candidates = <List<String>>[];
  bool known(List<String> path) => [
    ...found,
    ...candidates,
  ].any((p) => p.length == path.length && _samePath(p, path));
  while (found.length < count) {
    final last = found.last;
    for (var i = 0; i < last.length - 1; i++) {
      final spur = last[i];
      final root = last.sublist(0, i + 1);
      final removedLinks = <(String, String)>{
        for (final path in found)
          if (path.length > i + 1 && _samePath(path.sublist(0, i + 1), root))
            (path[i], path[i + 1]),
      };
      final removedNodes = root.sublist(0, i).toSet();
      final rest = shortest(spur, removedNodes, removedLinks);
      if (rest == null) continue;
      final path = [...root.sublist(0, i), ...rest];
      if (path.length - 1 <= maxLinks && !known(path)) candidates.add(path);
    }
    if (candidates.isEmpty) break;
    var best = 0;
    for (var j = 1; j < candidates.length; j++) {
      if (candidates[j].length < candidates[best].length) best = j;
    }
    found.add(candidates.removeAt(best));
  }
  return found;
}

bool _samePath(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
