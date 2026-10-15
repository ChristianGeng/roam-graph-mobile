import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/graph_algorithms.dart';

/// What my MCP server's algorithms (networkx 3.6.1, python-louvain 0.16)
/// return; tool/graph_algorithms.py writes it.
final expected = jsonDecode(
  File('test/fixtures/graph_algorithms_expected.json').readAsStringSync(),
) as Map<String, dynamic>;

AlgorithmGraph graphOf(Map<String, dynamic> data) => AlgorithmGraph.of(
      [
        for (final node in data['nodes'] as List)
          (node[0] as String, node[1] as String),
      ],
      [
        for (final link in data['links'] as List)
          (link[0] as String, link[1] as String),
      ],
    );

void main() {
  for (final name in ['sample_files', 'random']) {
    group(name, () {
      final data = expected[name] as Map<String, dynamic>;
      final graph = graphOf(data);

      test('PageRank as networkx', () {
        final ranks = pageRank(graph)!;
        final reference = data['pagerank'] as Map<String, dynamic>;
        expect(ranks.keys.toSet(), reference.keys.toSet());
        for (final MapEntry(:key, :value) in reference.entries) {
          expect(ranks[key], closeTo(value as num, 1e-9), reason: key);
        }
      });

      test('links per node as org_roam_central', () {
        expect(linkCounts(graph), data['link_counts']);
      });

      test('shortest paths as org_roam_shortest_path', () {
        var found = 0;
        for (final [source as String, target as String, length as int?]
            in data['paths'] as List) {
          final path = shortestPath(graph, source, target);
          expect(path == null ? null : path.length - 1, length,
              reason: '$source -> $target');
          if (path == null) continue;
          found++;
          expect(path.first, source);
          expect(path.last, target);
          for (var i = 0; i + 1 < path.length; i++) {
            expect(graph.successors[path[i]], contains(path[i + 1]));
          }
        }
        expect(found, greaterThan(50));
      });

      test('modularity as python-louvain', () {
        final louvain = data['louvain'] as Map<String, dynamic>;
        final partition = {
          for (final MapEntry(:key, :value)
              in (louvain['partition'] as Map<String, dynamic>).entries)
            key: value as int,
        };
        expect(modularity(graph, partition),
            closeTo(louvain['partition_modularity'] as num, 1e-12));
      });

      test('Louvain communities as good as python-louvain\'s', () {
        final louvain = data['louvain'] as Map<String, dynamic>;
        for (final seed in [0, 1, 2]) {
          final communities = louvainCommunities(graph, seed: seed);
          expect(communities.keys.toSet(), graph.nodes.toSet());
          // Louvain is random: the server's own runs differ. The app's
          // must be as good as the worst of 20 of them.
          expect(modularity(graph, communities),
              greaterThan((louvain['modularity_min'] as num) - 0.01),
              reason: 'seed $seed');
          final count = communities.values.toSet().length;
          expect(count,
              inInclusiveRange((louvain['communities_min'] as int) - 2,
                  (louvain['communities_max'] as int) + 2),
              reason: 'seed $seed');
        }
        // The same seed, the same communities.
        expect(louvainCommunities(graph), louvainCommunities(graph));
      });
    });
  }

  test('a graph without links: each node is its own community', () {
    final graph = AlgorithmGraph.of([('a', 'A'), ('b', 'B')], []);
    expect(louvainCommunities(graph), {'a': 0, 'b': 1});
    expect(modularity(graph, {'a': 0, 'b': 1}), 0);
    expect(pageRank(graph), {'a': 0.5, 'b': 0.5});
    expect(shortestPath(graph, 'a', 'b'), isNull);
  });

  test('paths follow links in their direction, at most 8 links', () {
    final chain = [for (var i = 0; i <= 9; i++) ('n$i', 'N$i')];
    final graph = AlgorithmGraph.of(chain, [
      for (var i = 0; i < 9; i++) ('n$i', 'n${i + 1}'),
    ]);
    expect(shortestPath(graph, 'n0', 'n8'), hasLength(9));
    expect(shortestPath(graph, 'n0', 'n9'), isNull);
    expect(shortestPath(graph, 'n8', 'n0'), isNull);
  });
}
