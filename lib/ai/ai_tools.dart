/// The tools an AI in the app calls to read the graph (#58): those of my
/// org-roam MCP server (`org-roam-mcp`), with its names, parameters and
/// results, computed on the app's index instead of Emacs's `org-roam.db`.
/// Nodes hidden from AI (#57) do not exist for them.
///
/// Each tool gives the server's result as data ([RoamTools.run], which the
/// tests compare with the server's) and as compact text for the model
/// ([RoamTools.call]): one line per node, with its ID and title.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'dart:math';

import '../graph/graph_algorithms.dart';
import '../graph/graph_measures.dart';
import '../graph/roam_db.dart' show TextHit;
import '../graph/roam_graph.dart';
import 'ai_visibility.dart';

/// Reads a note's text by its path relative to `roam/`; null if it cannot
/// be read. The node view's `NoteReader`.
typedef NoteTextReader = Future<String?> Function(String path);

/// A tool as the providers describe it to a model: a name, what it does,
/// and a JSON Schema of its parameters.
class AiTool {
  const AiTool(this.name, this.description, this.parameters);

  final String name;
  final String description;

  /// A JSON Schema of type `object`.
  final Map<String, Object?> parameters;
}

/// A call the tool cannot run, such as a missing parameter. The model gets
/// the message as the tool's result.
class ToolError implements Exception {
  const ToolError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The longest note text `org_roam_read_node` returns, in characters; the
/// rest is cut, with a line that says so. The server has no limit, but a
/// chat on the phone pays for every token.
const maxReadLength = 60000;

/// The most lines a list in a tool's text has; the rest is counted.
const maxListLines = 300;

Map<String, Object?> _object(
  Map<String, Object?> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
};

Map<String, Object?> _string(String description) => {
  'type': 'string',
  'description': description,
};

Map<String, Object?> _integer(String description, int defaultValue) => {
  'type': 'integer',
  'description': description,
  'default': defaultValue,
};

/// The tools, in the server's order, with its descriptions.
final aiTools = <AiTool>[
  AiTool(
    'org_roam_find',
    'Find org-roam nodes by title substring.',
    _object(
      {'search': _string('Title fragment to search for (case-insensitive)')},
      ['search'],
    ),
  ),
  AiTool(
    'org_roam_backlinks',
    'Find all nodes that link to the given node.',
    _object({'node_id': _string('UUID of the target node')}, ['node_id']),
  ),
  AiTool(
    'org_roam_bfs',
    'BFS neighbourhood traversal from a node. Returns all nodes reachable '
        'within `depth` hops, following links in their direction.',
    _object(
      {
        'node_id': _string('UUID of the starting node'),
        'depth': _integer('Maximum traversal depth', 2),
      },
      ['node_id'],
    ),
  ),
  AiTool(
    'org_roam_shortest_path',
    'Find shortest paths between two nodes (up to 3, max depth 8), '
        'following links in their direction. Returns paths with titles.',
    _object(
      {
        'start_id': _string('UUID of the start node'),
        'end_id': _string('UUID of the end node'),
      },
      ['start_id', 'end_id'],
    ),
  ),
  AiTool(
    'org_roam_common_neighbors',
    'Synthesis candidates: nodes, other than node_a and node_b, that link '
        'to the same nodes as node_a, with the number of shared links '
        '(at most 15). node_b is only left out of the result.',
    _object(
      {
        'node_a': _string('UUID of the first node'),
        'node_b': _string('UUID of the second node'),
      },
      ['node_a', 'node_b'],
    ),
  ),
  AiTool(
    'org_roam_central',
    'Find the most central nodes by degree centrality: distinct nodes '
        'linked to plus distinct nodes linking to them.',
    _object({'limit': _integer('Number of top nodes to return', 20)}),
  ),
  AiTool(
    'org_roam_orphans',
    'Find orphan nodes with no incoming or outgoing links.',
    _object({}),
  ),
  AiTool(
    'org_roam_search_text',
    'Find notes whose text contains the words: all of them, each also as '
        'the start of a longer word, case and accents ignored. Best matches '
        'first, with a snippet of the text around the match. Not in the '
        'laptop\'s MCP server; the app has its own full-text index.',
    _object({
      'query': _string('The words to find'),
      'limit': _integer('Number of notes to return', 20),
    }, ['query']),
  ),
  AiTool(
    'org_roam_read_node',
    'Read the full content of an org-roam node file (Org mode). For a '
        'heading node, the whole file it is in.',
    _object({'node_id': _string('UUID of the node to read')}, ['node_id']),
  ),
  AiTool(
    'org_roam_pagerank',
    'Compute PageRank node importance scores. Nodes with links from '
        'important nodes score higher.',
    _object({'limit': _integer('Number of top-ranked nodes to return', 20)}),
  ),
  AiTool(
    'org_roam_communities',
    'Detect communities (topic clusters) with the Louvain algorithm. '
        'Resolution below 1 finds larger communities, above 1 smaller.',
    _object({
      'resolution': {
        'type': 'number',
        'description': 'Resolution parameter (0.5-2.0)',
        'default': 1.0,
      },
    }),
  ),
  AiTool(
    'org_roam_betweenness',
    'Find bridge nodes between clusters (betweenness centrality). High '
        'scores indicate synthesis and integration points.',
    _object({'limit': _integer('Number of nodes to return', 20)}),
  ),
  AiTool(
    'org_roam_closeness',
    'Compute closeness centrality: how quickly a node is reached from '
        'the others.',
    _object({'limit': _integer('Number of nodes to return', 20)}),
  ),
  AiTool(
    'org_roam_clustering_coefficient',
    'Measure how clustered a node\'s neighbours are; without node_id, '
        'the average of the graph.',
    _object({
      'node_id': _string('Node to measure; omit for the graph-wide average.'),
    }),
  ),
  AiTool(
    'org_roam_graph_stats',
    'Compute overall graph health metrics: nodes, links, density, '
        'components, diameter.',
    _object({}),
  ),
  AiTool(
    'org_roam_suggest_links',
    'Suggest new links: nodes that the node\'s link targets link to, '
        'scored by shared link targets.',
    _object(
      {
        'node_id': _string('Node to find link suggestions for.'),
        'limit': _integer('Maximum suggestions to return', 10),
      },
      ['node_id'],
    ),
  ),
  AiTool(
    'org_roam_connected_components',
    'Find disconnected parts of the graph, each with its best-linked '
        'node.',
    _object({}),
  ),
];

/// Runs [aiTools] on a graph.
class RoamTools {
  RoamTools(
    RoamGraph full, {
    required this.readNote,
    this.visibility = AiVisibility.none,
    this.searchText,
  }) : graph = visibility.visibleGraph(full),
       _hiddenIds = visibility.hiddenIds(full);

  /// The graph without the hidden nodes.
  final RoamGraph graph;
  final NoteTextReader readNote;
  final AiVisibility visibility;
  final Set<String> _hiddenIds;

  /// The app's full-text index (#98); without it, the text search tool
  /// says it is not available.
  final Future<List<TextHit>> Function(String query, {int limit})? searchText;

  AlgorithmGraph? _algorithmGraph;

  /// The graph as the server's networkx tools build it (decision 30).
  AlgorithmGraph get algorithmGraph =>
      _algorithmGraph ??= AlgorithmGraph.fromRoam(graph);

  /// Runs the tool [name] and gives its result as text for the model.
  /// Errors are text too, as the server returns them.
  Future<String> call(String name, Map<String, Object?> args) async {
    try {
      return _text(name, await run(name, args));
    } on ToolError catch (e) {
      return 'Error: ${e.message}';
    }
  }

  /// Runs the tool [name] and gives its result as the server's data: lists
  /// and maps with its keys.
  Future<Object?> run(String name, Map<String, Object?> args) async {
    switch (name) {
      case 'org_roam_find':
        return find(_required(args, 'search'));
      case 'org_roam_backlinks':
        return backlinks(_id_(args, 'node_id'));
      case 'org_roam_bfs':
        return bfs(_id_(args, 'node_id'), _int(args, 'depth', 2));
      case 'org_roam_shortest_path':
        return shortestPaths(_id_(args, 'start_id'), _id_(args, 'end_id'));
      case 'org_roam_common_neighbors':
        return commonNeighbours(_id_(args, 'node_a'), _id_(args, 'node_b'));
      case 'org_roam_central':
        return central(_int(args, 'limit', 20));
      case 'org_roam_orphans':
        return orphans();
      case 'org_roam_read_node':
        return readNode(_id_(args, 'node_id'));
      case 'org_roam_search_text':
        return searchTextFor(_required(args, 'query'), _int(args, 'limit', 20));
      case 'org_roam_pagerank':
        return _ranking(
          pageRank(algorithmGraph),
          _int(args, 'limit', 20),
          'PageRank did not converge.',
        );
      case 'org_roam_communities':
        return communities(_double(args, 'resolution', 1));
      case 'org_roam_betweenness':
        return _ranking(betweenness(algorithmGraph), _int(args, 'limit', 20));
      case 'org_roam_closeness':
        return _ranking(closeness(algorithmGraph), _int(args, 'limit', 20));
      case 'org_roam_clustering_coefficient':
        final id = args['node_id'];
        return clusteringCoefficient(
          id == null || id == '' ? null : _id_(args, 'node_id'),
        );
      case 'org_roam_graph_stats':
        return graphStats();
      case 'org_roam_suggest_links':
        return suggestLinks(_id_(args, 'node_id'), _int(args, 'limit', 10));
      case 'org_roam_connected_components':
        return connectedComponents();
    }
    throw ToolError('There is no tool $name.');
  }

  String _title(String id) => graph.nodes[id]?.title ?? 'UNKNOWN';

  final _titleKeys = <String, List<int>>{};

  /// Nodes by title as SQL's `ORDER BY title` sorts them: by the stored,
  /// quoted title. Nodes with the same title keep their order, as the
  /// server's rows keep their table's order, which the app cannot know.
  int _byTitle(RoamNode a, RoamNode b) => compareBytes(
    _titleKeys.putIfAbsent(a.title, () => storedTitleKey(a.title)),
    _titleKeys.putIfAbsent(b.title, () => storedTitleKey(b.title)),
  );

  /// `org_roam_find`: title `LIKE '%search%'`, as SQLite matches it: `%`
  /// and `_` in [search] are wildcards, and letters match in either case
  /// only from A to Z. By title.
  List<Map<String, Object?>> find(String search) {
    final pattern = RegExp(
      '^.*${[for (final char in _asciiLower(search).split('')) char == '%'
            ? '.*'
            : char == '_'
            ? '.'
            : RegExp.escape(char)].join()}.*\$',
      dotAll: true,
    );
    final found = [
      for (final node in graph.nodes.values)
        if (pattern.hasMatch(_asciiLower(node.title))) node,
    ];
    _stableSort(found, _byTitle);
    return [
      for (final n in found) {'id': n.id, 'title': n.title, 'file': n.file},
    ];
  }

  /// `org_roam_backlinks`: one row for each `id:` link to [id], from a
  /// node, by the linking node's title.
  List<Map<String, Object?>> backlinks(String id) {
    final sources = [
      for (final link in graph.links)
        if (link.dest == id) ?graph.nodes[link.source],
    ];
    _stableSort(sources, _byTitle);
    return [
      for (final n in sources) {'title': n.title, 'id': n.id, 'file': n.file},
    ];
  }

  /// `org_roam_bfs`: the nodes [depth] or fewer links away from [id], in
  /// the links' direction, with the fewest links to each; by that number,
  /// then title.
  List<Map<String, Object?>> bfs(String id, int depth) {
    final distance = <String, int>{id: 0};
    var frontier = [id];
    for (var d = 1; d <= depth && frontier.isNotEmpty; d++) {
      final next = <String>[];
      for (final v in frontier) {
        for (final w in algorithmGraph.successors[v] ?? const <String>{}) {
          if (distance.containsKey(w)) continue;
          distance[w] = d;
          next.add(w);
        }
      }
      frontier = next;
    }
    final found = [
      for (final MapEntry(key: other, value: hops) in distance.entries)
        if (other != id) ?graph.nodes[other]?.withHops(hops),
    ];
    _stableSort(found, (a, b) {
      final byHops = a.$2.compareTo(b.$2);
      return byHops != 0 ? byHops : _byTitle(a.$1, b.$1);
    });
    return [
      for (final (n, hops) in found)
        {'title': n.title, 'id': n.id, 'hops': hops},
    ];
  }

  /// `org_roam_shortest_path`: up to 3 paths of at most 8 links that visit
  /// no node twice, the shortest first.
  List<Map<String, Object?>> shortestPaths(String start, String end) {
    final paths = shortestSimplePaths(
      algorithmGraph,
      start,
      end,
      maxLinks: maxPathLinks,
    );
    if (paths.isEmpty) {
      return [
        {'message': 'No path found between the two nodes (within depth 8).'},
      ];
    }
    return [
      for (final path in paths)
        {
          'hops': path.length - 1,
          'path': [
            for (final id in path)
              {'id': id, 'title': graph.nodes[id]?.title ?? '[unknown]'},
          ],
        },
    ];
  }

  /// `org_roam_common_neighbors`: the nodes other than [a] and [b] that
  /// link to nodes [a] links to, with the number of such link pairs, the
  /// most first; at most 15. As the server's query, [b] is only left out.
  List<Map<String, Object?>> commonNeighbours(String a, String b) {
    final linksTo = <String, List<RoamLink>>{};
    for (final link in graph.links) {
      linksTo.putIfAbsent(link.dest, () => []).add(link);
    }
    final shared = <String, int>{};
    for (final first in graph.links) {
      if (first.source != a) continue;
      for (final second in linksTo[first.dest] ?? const <RoamLink>[]) {
        final other = second.source;
        if (other == a || other == b || !graph.nodes.containsKey(other)) {
          continue;
        }
        shared[other] = (shared[other] ?? 0) + 1;
      }
    }
    final ranked = shared.keys.toList()
      ..sort((x, y) {
        final byCount = shared[y]!.compareTo(shared[x]!);
        return byCount != 0 ? byCount : y.compareTo(x);
      });
    return [
      for (final id in ranked.take(15))
        {'title': _title(id), 'id': id, 'shared_links': shared[id]},
    ];
  }

  /// `org_roam_central`: each node's distinct link targets and distinct
  /// linking nodes, the most in total first.
  List<Map<String, Object?>> central(int limit) {
    final g = algorithmGraph;
    final ids = graph.nodes.keys.toList()
      ..sort((x, y) {
        final byTotal = degree(g, y).compareTo(degree(g, x));
        return byTotal != 0 ? byTotal : y.compareTo(x);
      });
    return [
      for (final id in limit < 0 ? ids : ids.take(limit))
        {
          'title': _title(id),
          'id': id,
          'out_links': g.successors[id]!.length,
          'in_links': g.predecessors[id]!.length,
          'total': degree(g, id),
        },
    ];
  }

  /// `org_roam_orphans`: nodes without `id:` links, to or from them; by
  /// title.
  List<Map<String, Object?>> orphans() {
    final linked = {
      for (final link in graph.links) ...[link.source, link.dest],
    };
    final found = [
      for (final node in graph.nodes.values)
        if (!linked.contains(node.id)) node,
    ];
    _stableSort(found, _byTitle);
    return [
      for (final n in found) {'title': n.title, 'id': n.id, 'file': n.file},
    ];
  }

  /// `org_roam_read_node`: the whole file of the node, without hidden
  /// headings and with hidden titles left out (#57), at most
  /// [maxReadLength] characters.
  /// `org_roam_search_text` (#98): the index's hits, without notes hidden
  /// from AI and without hits only in hidden parts of a note: each hit is
  /// checked against the note's text as `org_roam_read_node` shows it.
  Future<String> searchTextFor(String query, int limit) async {
    final search = searchText;
    if (search == null) {
      throw const ToolError('Text search is not available here.');
    }
    final words = [
      for (final w in foldForSearch(query).split(RegExp(r'\s+')))
        if (w.isNotEmpty) w,
    ];
    if (words.isEmpty) throw const ToolError('query is empty.');
    final rows = <String>[];
    for (final hit in await search(query, limit: limit * 3)) {
      if (rows.length >= limit) break;
      final inFile = [
        for (final node in graph.nodes.values)
          if (node.file == hit.path) node,
      ];
      if (inFile.isEmpty) continue;
      final node = inFile.where((n) => n.isFile).firstOrNull ?? inFile.first;
      final text = await readNote(node.file);
      if (text == null || visibility.hidesInText(node, text)) continue;
      final shown = visibility.filterText(
          text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'), _hiddenIds);
      // Folded as the index folds, so "cafe" also finds "Café" here;
      // folding keeps the length, so the snippet's place is the same.
      final folded = foldForSearch(shown);
      final lower = folded.length == shown.length ? folded : shown.toLowerCase();
      // Every word must be in what the AI may see.
      if (!words.every(lower.contains)) continue;
      final at = lower.indexOf(words.first);
      final from = (at - 60).clamp(0, shown.length);
      final to = (at + words.first.length + 60).clamp(0, shown.length);
      final snippet = shown
          .substring(from, to)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      rows.add('${node.id} | ${node.displayTitle} | ${node.file} | '
          '${from > 0 ? '…' : ''}$snippet${to < shown.length ? '…' : ''}');
    }
    if (rows.isEmpty) return 'No notes contain: $query';
    return ['Notes containing "$query" (${rows.length}):', ...rows].join('\n');
  }

  Future<String> readNode(String id) async {
    final node = graph.nodes[id];
    if (node == null) return 'Error: No node found with id $id';
    final text = await readNote(node.file);
    if (text == null) return 'Error: File not found: ${node.file}';
    // The file may hide the node now, before the index knows (#57).
    if (visibility.hidesInText(node, text)) {
      return 'Error: No node found with id $id';
    }
    // Line ends as Python's read_text gives them to the server.
    final visible = visibility.filterText(
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
      _hiddenIds,
    );
    if (visible.length <= maxReadLength) return visible;
    return '${visible.substring(0, maxReadLength)}\n'
        '[The note is ${visible.length} characters long; only the first '
        '$maxReadLength are shown.]';
  }

  /// The [limit] best of [scores], the best first, as the server's
  /// `sorted(...)[:limit]`: the order of the nodes breaks ties, and nodes
  /// that are links to missing IDs take a place but are not listed.
  Object _ranking(
    Map<String, double>? scores,
    int limit, [
    String failure = '',
  ]) {
    if (scores == null) throw ToolError(failure);
    if (algorithmGraph.nodes.isEmpty) return const <Object>[];
    final ids = algorithmGraph.nodes.toList();
    _stableSort(ids, (x, y) => scores[y]!.compareTo(scores[x]!));
    final end = limit < 0 ? max(0, ids.length + limit) : min(limit, ids.length);
    return [
      for (final id in ids.sublist(0, end))
        if (graph.nodes[id] case final node?)
          {'title': node.title, 'id': id, 'score': scores[id]},
    ];
  }

  /// `org_roam_communities`: Louvain at [resolution], communities in the
  /// order of their first node; modularity at resolution 1, as the server
  /// computes it.
  Map<String, Object?> communities(double resolution) {
    final g = algorithmGraph;
    if (g.nodes.isEmpty) {
      return {'communities': const <Object>[], 'num_communities': 0};
    }
    final partition = louvainCommunities(g, resolution: resolution);
    final groups = <int, List<Map<String, Object?>>>{};
    for (final id in g.nodes) {
      groups.putIfAbsent(partition[id]!, () => []).add({
        'title': _title(id),
        'id': id,
      });
    }
    return {
      'communities': {
        for (final MapEntry(:key, :value) in groups.entries) '$key': value,
      },
      'num_communities': groups.length,
      'modularity': modularity(g, partition),
    };
  }

  /// `org_roam_clustering_coefficient`.
  Map<String, Object?> clusteringCoefficient(String? id) {
    final g = algorithmGraph;
    if (g.nodes.isEmpty) return {'error': 'Graph is empty'};
    if (id != null) {
      if (!g.successors.containsKey(id)) return {'error': 'Node $id not found'};
      final c = clustering(g, id);
      return {
        'node_id': id,
        'title': _title(id),
        'clustering_coefficient': c,
        'interpretation': c > 0.5
            ? 'High (>0.5): Node is in a tight cluster'
            : c > 0.2
            ? 'Medium (0.2-0.5): Mixed connectivity'
            : 'Low (<0.2): Node bridges different clusters',
      };
    }
    final average = averageClustering(g);
    return {
      'average_clustering_coefficient': average,
      'interpretation': average > 0.5
          ? 'High (>0.5): Graph has tight clusters'
          : average > 0.2
          ? 'Medium (0.2-0.5): Mixed structure'
          : 'Low (<0.2): Graph is sparse/decentralized',
    };
  }

  /// `org_roam_graph_stats`. Diameter and average path length are those of
  /// the largest component, with links in both directions; the average
  /// divides by the number of nodes squared, as the server does.
  Map<String, Object?> graphStats() {
    final g = algorithmGraph;
    final n = g.nodes.length;
    if (n == 0) {
      return {'error': 'Graph is empty', 'num_nodes': 0, 'num_edges': 0};
    }
    final edges = edgeCount(g);
    final density = n > 1 ? edges / (n * (n - 1)) : 0.0;
    final components = weaklyConnectedComponents(g);
    var largest = components.first;
    for (final c in components) {
      if (c.length > largest.length) largest = c;
    }
    int? diameter;
    double? averagePath;
    if (largest.length > 1) {
      var longest = 0, total = 0;
      for (final id in largest) {
        final distances = distancesFrom(id, (v) => undirectedNeighbours(g, v));
        for (final d in distances.values) {
          total += d;
          if (d > longest) longest = d;
        }
      }
      diameter = longest;
      final average = total / (largest.length * largest.length);
      averagePath = average == 0 ? null : average;
    }
    final degrees = g.nodes.fold(0, (s, id) => s + degree(g, id));
    return {
      'num_nodes': n,
      'num_edges': edges,
      'density': density,
      'num_components': components.length,
      'largest_component_size': largest.length,
      'avg_degree': degrees / n,
      'diameter': diameter,
      'avg_shortest_path': averagePath,
      'interpretation': {
        'density':
            'Sparse graph (${density.toStringAsFixed(4)}). '
            'Most nodes only connected to small subset.',
        'components':
            'Graph has ${components.length} connected '
            'component(s). Largest contains ${largest.length}/$n nodes.',
      },
    };
  }

  /// `org_roam_suggest_links`: nodes two links away, not linked yet,
  /// scored by the link targets they share with [id], summed over each
  /// way to reach them; the best first.
  List<Map<String, Object?>> suggestLinks(String id, int limit) {
    final g = algorithmGraph;
    final own = g.successors[id];
    if (own == null) return const [];
    final scores = <String, int>{};
    for (final neighbour in own) {
      for (final candidate in g.successors[neighbour]!) {
        if (candidate == id || own.contains(candidate)) continue;
        final shared = own.intersection(g.successors[candidate]!).length;
        scores[candidate] = (scores[candidate] ?? 0) + shared;
      }
    }
    final ranked = scores.keys.toList();
    _stableSort(ranked, (x, y) => scores[y]!.compareTo(scores[x]!));
    final end = limit < 0
        ? max(0, ranked.length + limit)
        : min(limit, ranked.length);
    return [
      for (final other in ranked.sublist(0, end))
        if (graph.nodes[other] case final node?)
          {
            'title': node.title,
            'id': other,
            'score': scores[other],
            'reason': 'shared connections via 2-hop neighbors',
          },
    ];
  }

  /// `org_roam_connected_components`: the largest first; the hub is the
  /// node with the most links (of several, the first by ID: the server's
  /// choice depends on Python's set order).
  Map<String, Object?> connectedComponents() {
    final g = algorithmGraph;
    if (g.nodes.isEmpty) {
      return {'components': const <Object>[], 'num_components': 0};
    }
    final components = weaklyConnectedComponents(g);
    _stableSort(components, (a, b) => b.length.compareTo(a.length));
    return {
      'num_components': components.length,
      'components': [
        for (final (i, component) in components.indexed)
          () {
            final ids = component.toList()..sort();
            String? hub;
            var most = 0;
            for (final id in ids) {
              if (degree(g, id) > most) {
                most = degree(g, id);
                hub = id;
              }
            }
            return {
              'component_id': i,
              'size': component.length,
              'hub_node': hub == null
                  ? null
                  : {'title': _title(hub), 'id': hub, 'degree': most},
              'nodes': [
                for (final id in ids)
                  if (graph.nodes[id] case final node?)
                    {'title': node.title, 'id': id},
              ],
            };
          }(),
      ],
      'interpretation': components.length == 1
          ? 'Graph is fully connected (1 component).'
          : 'Graph has ${components.length} separate components. '
                'Largest component has ${components.first.length} nodes. '
                'Consider linking isolated areas.',
    };
  }

  /// [result] of the tool [name] as compact text.
  String _text(String name, Object? result) {
    if (result is String) return result;
    String node(Map<String, Object?> row) {
      final id = row['id'] as String;
      final title = graph.nodes[id]?.displayTitle ?? row['title'];
      return '$id | $title';
    }

    String list(String header, Iterable<String> lines) {
      final all = lines.toList();
      if (all.isEmpty) return '$header: none';
      return [
        '$header (${all.length}):',
        ...all.take(maxListLines),
        if (all.length > maxListLines)
          '… and ${all.length - maxListLines} more.',
      ].join('\n');
    }

    /// One line per group, with its members, at most [maxListLines] nodes
    /// in all, as [list] gives at most that many lines; the rest counted.
    List<String> groupLines(List<(String, List<Map<String, Object?>>)> groups) {
      var left = maxListLines;
      final lines = <String>[];
      var groupsLeft = groups.length;
      for (final (header, members) in groups) {
        if (left <= 0) break;
        groupsLeft--;
        final shown = members.take(left).map(node).join('; ');
        final more = members.length > left
            ? '; … and ${members.length - left} more'
            : '';
        left -= members.length;
        lines.add('$header: $shown$more');
      }
      if (groupsLeft > 0) lines.add('… and $groupsLeft more groups.');
      return lines;
    }

    String score(Object? value) => (value as num).toStringAsPrecision(6);
    final rows = result is List ? result.cast<Map<String, Object?>>() : null;
    final map = result is Map ? result.cast<String, Object?>() : null;
    if (map?['error'] case final String error) return 'Error: $error';
    switch (name) {
      case 'org_roam_find':
        return list('Nodes (ID | title | file)', [
          for (final r in rows!) '${node(r)} | ${r['file']}',
        ]);
      case 'org_roam_backlinks':
        return list('Backlinks, one per link (ID | title)', rows!.map(node));
      case 'org_roam_orphans':
        return list('Orphans (ID | title)', rows!.map(node));
      case 'org_roam_bfs':
        return list('Nodes (hops | ID | title)', [
          for (final r in rows!) '${r['hops']} | ${node(r)}',
        ]);
      case 'org_roam_shortest_path':
        if (rows!.first['message'] case final String message) return message;
        return [
          for (final r in rows)
            '${r['hops']} hops: ${[for (final step in (r['path'] as List).cast<Map<String, Object?>>()) '${graph.nodes[step['id']]?.displayTitle ?? step['title']} '
                  '[${step['id']}]'].join(' -> ')}',
        ].join('\n');
      case 'org_roam_common_neighbors':
        return list('Nodes (shared links | ID | title)', [
          for (final r in rows!) '${r['shared_links']} | ${node(r)}',
        ]);
      case 'org_roam_central':
        return list('Nodes (total = out + in | ID | title)', [
          for (final r in rows!)
            '${r['total']} = ${r['out_links']} + ${r['in_links']} | ${node(r)}',
        ]);
      case 'org_roam_pagerank' ||
          'org_roam_betweenness' ||
          'org_roam_closeness':
        return list('Nodes (score | ID | title)', [
          for (final r in rows!) '${score(r['score'])} | ${node(r)}',
        ]);
      case 'org_roam_suggest_links':
        return list('Suggestions (score | ID | title)', [
          for (final r in rows!) '${r['score']} | ${node(r)}',
        ]);
      case 'org_roam_communities':
        final communities = map!['communities'];
        if (communities is! Map) return 'No communities: the graph is empty.';
        final groups = [
          for (final members in communities.values)
            (members as List).cast<Map<String, Object?>>(),
        ]..sort((a, b) => b.length.compareTo(a.length));
        return [
          '${map['num_communities']} communities, modularity '
              '${score(map['modularity'])}. Largest first; members as '
              'ID | title, separated by "; ".',
          ...groupLines([
            for (final (i, members) in groups.indexed)
              ('Community ${i + 1} (${members.length})', members),
          ]),
        ].join('\n');
      case 'org_roam_clustering_coefficient':
        if (map!.containsKey('node_id')) {
          return 'Clustering coefficient of ${node({'id': map['node_id'], 'title': map['title']})}: ${score(map['clustering_coefficient'])}. '
              '${map['interpretation']}';
        }
        return 'Average clustering coefficient: '
            '${score(map['average_clustering_coefficient'])}. '
            '${map['interpretation']}';
      case 'org_roam_graph_stats':
        final interpretation = (map!['interpretation'] as Map)
            .cast<String, Object?>();
        return [
          'Nodes: ${map['num_nodes']}',
          'Links (pairs of nodes): ${map['num_edges']}',
          'Density: ${score(map['density'])}',
          'Components: ${map['num_components']}, the largest with '
              '${map['largest_component_size']} nodes',
          'Average links per node: ${score(map['avg_degree'])}',
          'Diameter of the largest component: ${map['diameter'] ?? '-'}',
          'Average shortest path: '
              '${map['avg_shortest_path'] == null ? '-' : score(map['avg_shortest_path'])}',
          '${interpretation['density']} ${interpretation['components']}',
        ].join('\n');
      case 'org_roam_connected_components':
        final components = (map!['components'] as List)
            .cast<Map<String, Object?>>();
        if (components.isEmpty) return 'No components: the graph is empty.';
        return [
          '${map['interpretation']}',
          ...groupLines([
            for (final c in components)
              (
                'Component ${c['component_id']}: ${c['size']} nodes'
                    '${switch (c['hub_node']) {
                      final Map<String, Object?> hub => ', hub ${node(hub)} (${hub['degree']} links)',
                      _ => '',
                    }}. Nodes',
                (c['nodes'] as List).cast<Map<String, Object?>>(),
              ),
          ]),
        ].join('\n');
    }
    return '$result';
  }
}

extension on RoamNode {
  (RoamNode, int) withHops(int hops) => (this, hops);
}

/// Sorts [list] keeping the order of equal elements, as Python's `sorted`.
void _stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}

/// Lower case from A to Z only, as SQLite's `LIKE`.
String _asciiLower(String text) => String.fromCharCodes([
  for (final c in text.codeUnits) c >= 65 && c <= 90 ? c + 32 : c,
]);

String _required(Map<String, Object?> args, String name) {
  final value = args[name];
  if (value == null) throw ToolError('$name is missing.');
  return '$value';
}

/// A node ID parameter. Quotes around it are removed, as the server
/// removes Emacs Lisp quotes; so is an `id:` in front.
String _id_(Map<String, Object?> args, String name) {
  var id = _required(args, name).trim();
  if (id.length >= 2 && id.startsWith('"') && id.endsWith('"')) {
    id = id.substring(1, id.length - 1);
  }
  return id.startsWith('id:') ? id.substring(3) : id;
}

int _int(Map<String, Object?> args, String name, int defaultValue) {
  final value = args[name];
  if (value == null) return defaultValue;
  if (value is num) {
    // A fraction would silently run another query.
    if (value.isFinite && value == value.truncate()) return value.toInt();
    throw ToolError('$name must be a whole number, not "$value".');
  }
  return int.tryParse('$value'.trim()) ??
      (throw ToolError('$name must be a whole number, not "$value".'));
}

double _double(Map<String, Object?> args, String name, double defaultValue) {
  final value = args[name];
  if (value == null) return defaultValue;
  if (value is num) return value.toDouble();
  return double.tryParse('$value'.trim()) ??
      (throw ToolError('$name must be a number, not "$value".'));
}

/// Letters with accents, and what the index's `remove_diacritics 2` makes
/// of them, for the letters of Latin-1 and Latin Extended-A.
const _accented =
    'àáâãäåçèéêëìíîïñòóôõöùúûüýÿāăąćĉċčďēĕėęěĝğġģĥĩīĭįĵķĺļľńņňōŏőŕŗřśŝşšţťũūŭůűųŵŷźżžđħıłøŧ';
const _plain =
    'aaaaaaceeeeiiiinooooouuuuyyaaaccccdeeeeegggghiiiijklllnnnooorrrssssttuuuuuuwyzzzdhilot';

/// [text] in lower case without accents, one letter for one, as the
/// full-text index matches (#98).
String foldForSearch(String text) {
  final lower = text.toLowerCase();
  final out = StringBuffer();
  for (final char in lower.split('')) {
    final at = _accented.indexOf(char);
    out.write(at < 0 ? char : _plain[at]);
  }
  return out.toString();
}
