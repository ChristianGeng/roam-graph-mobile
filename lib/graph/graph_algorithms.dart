/// Graph algorithms for the graph views (#7), computed as my org-roam MCP
/// server computes them (`cgeng-ai-skills`, `mcps/org_roam`), so both give
/// the same communities, ranking and paths. The server uses networkx and
/// python-louvain; `tool/graph_algorithms.py` writes their results for the
/// tests.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'elisp.dart';
import 'roam_graph.dart';

/// The longest path org_roam_shortest_path follows, in links.
const maxPathLinks = 8;

/// The graph the server builds (`_load_graph_from_db`): a directed graph
/// with every node, and one edge for each pair of nodes with an `id:` link.
/// A link to an ID that is no node adds a node without a title, as
/// networkx's `add_edge` does. A link from a node to itself is an edge.
class AlgorithmGraph {
  AlgorithmGraph._(this.nodes, this.successors, this.predecessors);

  factory AlgorithmGraph.fromRoam(RoamGraph graph) => AlgorithmGraph.of(
    [for (final node in graph.nodes.values) (node.id, node.title)],
    [for (final link in graph.links) (link.source, link.dest)],
  );

  /// [nodes] are ID and title; the server adds them ordered by title, as
  /// its query's `ORDER BY title` sorts them ([compareStoredTitles]).
  /// Nodes with the same title keep their order.
  factory AlgorithmGraph.of(
    List<(String, String)> nodes,
    List<(String, String)> links,
  ) {
    final keys = {for (final (_, title) in nodes) title: storedTitleKey(title)};
    final indexed = [for (var i = 0; i < nodes.length; i++) (i, nodes[i])]
      ..sort((a, b) {
        final byTitle = compareBytes(keys[a.$2.$2]!, keys[b.$2.$2]!);
        return byTitle != 0 ? byTitle : a.$1.compareTo(b.$1);
      });
    final sorted = [for (final (_, node) in indexed) node];
    final successors = <String, LinkedHashSet<String>>{};
    final predecessors = <String, LinkedHashSet<String>>{};
    void add(String id) {
      successors.putIfAbsent(id, LinkedHashSet.new);
      predecessors.putIfAbsent(id, LinkedHashSet.new);
    }

    for (final (id, _) in sorted) {
      add(id);
    }
    for (final (source, dest) in links) {
      add(source);
      add(dest);
      successors[source]!.add(dest);
      predecessors[dest]!.add(source);
    }
    return AlgorithmGraph._(successors.keys.toList(), successors, predecessors);
  }

  /// The nodes, in the order networkx holds them.
  final List<String> nodes;
  final Map<String, LinkedHashSet<String>> successors;
  final Map<String, LinkedHashSet<String>> predecessors;
}

/// [title] as org-roam's database stores it (decision 23), as bytes: SQL's
/// `ORDER BY title` compares these, so `"Beta heading"` comes before
/// `"Beta"` (a space before the closing quote).
List<int> storedTitleKey(String title) => utf8.encode(elispString(title));

/// Compares two byte strings as SQLite compares text: byte by byte, a
/// shorter one first when it is the start of the other.
int compareBytes(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// The results the graph views (#7) show, computed together, for
/// [computeAlgorithmResults] on another isolate.
class AlgorithmResults {
  const AlgorithmResults(this.communities, this.ranks, this.links);

  final Map<String, int> communities;
  final Map<String, double> ranks;
  final Map<String, int> links;
}

/// Louvain communities, PageRank and link counts of [graph].
AlgorithmResults computeAlgorithmResults(AlgorithmGraph graph) =>
    AlgorithmResults(
      louvainCommunities(graph),
      pageRank(graph) ?? const {},
      linkCounts(graph),
    );

/// PageRank as networkx's `nx.pagerank(G)` computes it: damping 0.85, at
/// most 100 iterations, tolerance 1e-6 per node, and a node without
/// outgoing links spreads its rank over all nodes. Null if it does not
/// converge, where networkx raises an error.
Map<String, double>? pageRank(AlgorithmGraph graph) {
  const alpha = 0.85, maxIterations = 100, tolerance = 1e-6;
  final nodes = graph.nodes;
  final n = nodes.length;
  if (n == 0) return {};
  final index = {for (var i = 0; i < n; i++) nodes[i]: i};
  final out = [for (final id in nodes) graph.successors[id]!.length];
  final targets = [
    for (final id in nodes)
      [for (final dest in graph.successors[id]!) index[dest]!],
  ];
  var x = List.filled(n, 1 / n);
  for (var iteration = 0; iteration < maxIterations; iteration++) {
    final last = x;
    var dangling = 0.0;
    for (var i = 0; i < n; i++) {
      if (out[i] == 0) dangling += last[i];
    }
    final next = List.filled(n, alpha * dangling / n + (1 - alpha) / n);
    for (var i = 0; i < n; i++) {
      if (out[i] == 0) continue;
      final share = alpha * last[i] / out[i];
      for (final j in targets[i]) {
        next[j] += share;
      }
    }
    x = next;
    var error = 0.0;
    for (var i = 0; i < n; i++) {
      error += (x[i] - last[i]).abs();
    }
    if (error < n * tolerance) {
      return {for (var i = 0; i < n; i++) nodes[i]: x[i]};
    }
  }
  return null;
}

/// The number of links of each node, as org_roam_central counts it: the
/// distinct nodes it links to plus the distinct nodes that link to it.
Map<String, int> linkCounts(AlgorithmGraph graph) => {
  for (final id in graph.nodes)
    id: graph.successors[id]!.length + graph.predecessors[id]!.length,
};

/// A shortest path from [source] to [target], following links in their
/// direction, of at most [maxPathLinks] links, as org_roam_shortest_path
/// finds one; null if there is none. With several shortest paths, the one
/// a breadth-first search finds first in link order.
List<String>? shortestPath(AlgorithmGraph graph, String source, String target) {
  if (source == target ||
      !graph.successors.containsKey(source) ||
      !graph.successors.containsKey(target)) {
    return null;
  }
  final previous = <String, String>{source: source};
  var frontier = [source];
  for (var depth = 0; depth < maxPathLinks && frontier.isNotEmpty; depth++) {
    final next = <String>[];
    for (final id in frontier) {
      for (final dest in graph.successors[id]!) {
        if (previous.containsKey(dest)) continue;
        previous[dest] = id;
        if (dest == target) {
          final path = [target];
          while (path.last != source) {
            path.add(previous[path.last]!);
          }
          return path.reversed.toList();
        }
        next.add(dest);
      }
    }
    frontier = next;
  }
  return null;
}

/// An undirected graph with weighted edges, as networkx's `to_undirected`
/// makes it from [AlgorithmGraph] and as Louvain's levels combine it. A
/// node's own loop is kept in [loops].
class _WeightedGraph {
  _WeightedGraph(this.nodes);

  final List<int> nodes;

  /// Weights of the edges to other nodes, both directions.
  final neighbours = <int, Map<int, double>>{};

  /// Weight of each node's edge to itself.
  final loops = <int, double>{};

  void addEdge(int a, int b, double weight) {
    if (a == b) {
      loops[a] = (loops[a] ?? 0) + weight;
      return;
    }
    neighbours.putIfAbsent(a, () => {})[b] = (neighbours[a]?[b] ?? 0) + weight;
    neighbours.putIfAbsent(b, () => {})[a] = (neighbours[b]?[a] ?? 0) + weight;
  }

  /// networkx's `degree`: a loop counts twice.
  double degree(int node) =>
      (neighbours[node]?.values.fold<double>(0, (s, w) => s + w) ?? 0) +
      2 * (loops[node] ?? 0);

  /// networkx's `size`: the sum of the edge weights, a loop once.
  double get size {
    var total = loops.values.fold<double>(0, (s, w) => s + w);
    for (final entry in neighbours.entries) {
      for (final MapEntry(key: other, value: w) in entry.value.entries) {
        if (entry.key < other) total += w;
      }
    }
    return total;
  }
}

/// Communities by the Louvain method, as python-louvain's `best_partition`
/// finds them on the undirected graph: community numbers by node. Louvain
/// visits nodes in a random order; the server uses no seed, so its
/// communities differ a little from run to run. Here the order comes from
/// [seed], so the app's colours stay the same. A [resolution] below 1
/// gives larger communities, above 1 smaller ones (org_roam_communities'
/// parameter, #58).
Map<String, int> louvainCommunities(
  AlgorithmGraph graph, {
  int seed = 0,
  double resolution = 1,
}) {
  final ids = graph.nodes;
  final undirected = _undirected(graph);
  if (undirected.size == 0) {
    return {for (var i = 0; i < ids.length; i++) ids[i]: i};
  }
  final random = Random(seed);
  // Community of each original node, refined level by level.
  var partition = {for (var i = 0; i < ids.length; i++) i: i};
  var current = undirected;
  var level = _Status(current);
  _oneLevel(current, level, random, resolution);
  var modularity = level.modularity(resolution);
  var renumbered = _renumber(level.nodeToCommunity);
  partition = {
    for (final MapEntry(:key, :value) in partition.entries)
      key: renumbered[value]!,
  };
  while (true) {
    current = _induced(renumbered, current);
    level = _Status(current);
    _oneLevel(current, level, random, resolution);
    final next = level.modularity(resolution);
    if (next - modularity < _minimumGain) break;
    modularity = next;
    renumbered = _renumber(level.nodeToCommunity);
    partition = {
      for (final MapEntry(:key, :value) in partition.entries)
        key: renumbered[value]!,
    };
  }
  return {for (var i = 0; i < ids.length; i++) ids[i]: partition[i]!};
}

/// The modularity of [communities] on the undirected graph, as
/// python-louvain's `modularity` computes it.
double modularity(AlgorithmGraph graph, Map<String, int> communities) {
  final undirected = _undirected(graph);
  final links = undirected.size;
  if (links == 0) return 0;
  final community = [for (final id in graph.nodes) communities[id]!];
  final inside = <int, double>{};
  final degree = <int, double>{};
  for (final node in undirected.nodes) {
    final c = community[node];
    degree[c] = (degree[c] ?? 0) + undirected.degree(node);
    for (final MapEntry(key: other, value: w)
        in (undirected.neighbours[node] ?? const <int, double>{}).entries) {
      if (community[other] == c) inside[c] = (inside[c] ?? 0) + w / 2;
    }
    inside[c] = (inside[c] ?? 0) + (undirected.loops[node] ?? 0);
  }
  var result = 0.0;
  for (final c in degree.keys) {
    result += (inside[c] ?? 0) / links - pow(degree[c]! / (2 * links), 2);
  }
  return result;
}

/// python-louvain's `__MIN`: a pass that gains less modularity stops.
const _minimumGain = 0.0000001;

_WeightedGraph _undirected(AlgorithmGraph graph) {
  final index = {
    for (var i = 0; i < graph.nodes.length; i++) graph.nodes[i]: i,
  };
  final result = _WeightedGraph([
    for (var i = 0; i < graph.nodes.length; i++) i,
  ]);
  final seen = <(int, int)>{};
  for (final id in graph.nodes) {
    for (final dest in graph.successors[id]!) {
      final a = index[id]!, b = index[dest]!;
      // to_undirected keeps one edge for a -> b and b -> a.
      if (seen.add(a <= b ? (a, b) : (b, a))) result.addEdge(a, b, 1);
    }
  }
  return result;
}

/// python-louvain's `Status`: the communities of one level.
class _Status {
  _Status(_WeightedGraph graph) : totalWeight = graph.size {
    for (final node in graph.nodes) {
      nodeToCommunity[node] = node;
      final degree = graph.degree(node);
      degrees[node] = degree;
      nodeDegrees[node] = degree;
      final loop = graph.loops[node] ?? 0;
      loops[node] = loop;
      internals[node] = loop;
    }
  }

  final double totalWeight;
  final nodeToCommunity = <int, int>{};
  final degrees = <int, double>{};
  final nodeDegrees = <int, double>{};
  final loops = <int, double>{};
  final internals = <int, double>{};

  void remove(int node, int community, double weight) {
    degrees[community] = (degrees[community] ?? 0) - nodeDegrees[node]!;
    internals[community] = (internals[community] ?? 0) - weight - loops[node]!;
    nodeToCommunity[node] = -1;
  }

  void insert(int node, int community, double weight) {
    nodeToCommunity[node] = community;
    degrees[community] = (degrees[community] ?? 0) + nodeDegrees[node]!;
    internals[community] = (internals[community] ?? 0) + weight + loops[node]!;
  }

  /// python-louvain's `__modularity`.
  double modularity(double resolution) {
    var result = 0.0;
    for (final community in nodeToCommunity.values.toSet()) {
      final inside = internals[community] ?? 0;
      final degree = degrees[community] ?? 0;
      if (totalWeight > 0) {
        result +=
            inside * resolution / totalWeight -
            pow(degree / (2 * totalWeight), 2);
      }
    }
    return result;
  }
}

/// python-louvain's `__one_level`: moves nodes to the neighbouring
/// community that gains the most modularity, until no pass gains enough.
void _oneLevel(
  _WeightedGraph graph,
  _Status status,
  Random random,
  double resolution,
) {
  var modified = true;
  var current = status.modularity(resolution);
  var next = current;
  while (modified) {
    current = next;
    modified = false;
    for (final node in [...graph.nodes]..shuffle(random)) {
      final community = status.nodeToCommunity[node]!;
      final degreeShare = status.nodeDegrees[node]! / (status.totalWeight * 2);
      final weights = <int, double>{};
      for (final MapEntry(key: other, value: w)
          in (graph.neighbours[node] ?? const <int, double>{}).entries) {
        final c = status.nodeToCommunity[other]!;
        weights[c] = (weights[c] ?? 0) + w;
      }
      final removeCost =
          -(weights[community] ?? 0) +
          resolution *
              (status.degrees[community]! - status.nodeDegrees[node]!) *
              degreeShare;
      status.remove(node, community, weights[community] ?? 0);
      var best = community;
      var bestIncrease = 0.0;
      for (final MapEntry(key: c, value: w)
          in (weights.entries.toList()..shuffle(random))) {
        final increase =
            removeCost +
            w -
            resolution * (status.degrees[c] ?? 0) * degreeShare;
        if (increase > bestIncrease) {
          bestIncrease = increase;
          best = c;
        }
      }
      status.insert(node, best, weights[best] ?? 0);
      if (best != community) modified = true;
    }
    next = status.modularity(resolution);
    if (next - current < _minimumGain) break;
  }
}

/// Community numbers from 0, in the order they first appear.
Map<int, int> _renumber(Map<int, int> nodeToCommunity) {
  final numbers = <int, int>{};
  for (final community in nodeToCommunity.values) {
    numbers.putIfAbsent(community, () => numbers.length);
  }
  return {
    for (final MapEntry(:key, :value) in nodeToCommunity.entries)
      key: numbers[value]!,
  };
}

/// python-louvain's `induced_graph`: one node per community; the weight
/// between two communities is the sum of the weights between their nodes.
_WeightedGraph _induced(Map<int, int> partition, _WeightedGraph graph) {
  final communities = partition.values.toSet().toList()..sort();
  final result = _WeightedGraph(communities);
  for (final MapEntry(key: node, value: loop) in graph.loops.entries) {
    result.addEdge(partition[node]!, partition[node]!, loop);
  }
  for (final entry in graph.neighbours.entries) {
    for (final MapEntry(key: other, value: w) in entry.value.entries) {
      if (entry.key < other) {
        result.addEdge(partition[entry.key]!, partition[other]!, w);
      }
    }
  }
  return result;
}
