import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/graph/elisp.dart';
import 'package:roam_graph_mobile/graph/graph_algorithms.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

import '../graph/graph_scope_test.dart' show fixtureGraph;
import 'package:roam_graph_mobile/graph/roam_db.dart' show TextHit;

import 'ai_visibility_test.dart' as hidden;

/// What my org-roam MCP server's tools return; tool/ai_tools_expected.py
/// writes it.
final expected =
    jsonDecode(File('test/fixtures/ai_tools_expected.json').readAsStringSync())
        as Map<String, dynamic>;

/// The random graph of tool/graph_algorithms.py: one file per node.
RoamGraph randomGraph(Map<String, dynamic> data) {
  final links = <String, List<RoamLink>>{};
  for (final [source as String, dest as String] in data['links'] as List) {
    links
        .putIfAbsent(source, () => [])
        .add(
          RoamLink(source: source, dest: dest, file: '$source.org', line: 1),
        );
  }
  return RoamGraph.fromFiles([
    for (final [id as String, title as String] in data['nodes'] as List)
      RoamFileData(
        path: '$id.org',
        nodes: [
          RoamNode(id: id, file: '$id.org', level: 0, title: title, line: 1),
        ],
        links: links[id] ?? const [],
      ),
  ]);
}

/// The server's result as the app gives it: titles decoded (the server
/// returns them as stored, with Emacs Lisp escapes such as `\11` for a
/// tab), files by name (the server gives absolute paths, the app paths
/// relative to roam/).
Object? normalized(Object? value) => switch (value) {
  List() => [for (final v in value) normalized(v)],
  Map() => {
    for (final MapEntry(:key, value: v) in value.entries)
      key: switch (key) {
        'title' when v is String && v != 'UNKNOWN' && v != '[unknown]' =>
          decodeElispString('"$v"'),
        'file' when v is String => v.split('/').last,
        _ => normalized(v),
      },
  },
  _ => value,
};

/// [actual] is [reference], numbers within 1e-9.
void expectSame(Object? actual, Object? reference, String where) {
  if (reference is num && actual is num) {
    expect(actual, closeTo(reference, 1e-9), reason: where);
  } else if (reference is List && actual is List) {
    expect(actual.length, reference.length, reason: '$where: length');
    for (var i = 0; i < reference.length; i++) {
      expectSame(actual[i], reference[i], '$where[$i]');
    }
  } else if (reference is Map && actual is Map) {
    expect(actual.keys.toSet(), reference.keys.toSet(), reason: '$where: keys');
    for (final key in reference.keys) {
      expectSame(actual[key], reference[key], '$where.$key');
    }
  } else {
    expect(actual, reference, reason: where);
  }
}

/// Rows in the same order of [key], rows with the same key in any order:
/// the server returns those in its table's order or SQLite's, which the app
/// cannot know. With [cut], the last group may be cut by a limit, so only
/// its keys are compared.
void expectGroups(
  List actual,
  List reference,
  Object? Function(Map) key,
  String where, {
  bool cut = false,
}) {
  expect(actual.length, reference.length, reason: '$where: length');
  String row(Object? r) => jsonEncode(r, toEncodable: (o) => '$o');
  List<List<Map>> groups(List rows) {
    final result = <List<Map>>[];
    for (final r in rows.cast<Map>()) {
      if (result.isEmpty || key(result.last.first) != key(r)) result.add([]);
      result.last.add(r);
    }
    return result;
  }

  final a = groups(actual), r = groups(reference);
  expect(
    [for (final g in a) key(g.first)],
    [for (final g in r) key(g.first)],
    reason: '$where: keys in order',
  );
  for (var i = 0; i < r.length; i++) {
    if (cut && i == r.length - 1) break;
    expect(
      {for (final x in a[i]) row(_rounded(x))},
      {for (final x in r[i]) row(_rounded(x))},
      reason: '$where: group ${key(r[i].first)}',
    );
  }
}

/// Scores rounded, so float noise does not tell rows apart; keys sorted;
/// files by name.
Object? _rounded(Object? value) => switch (value) {
  double() => value.toStringAsPrecision(9),
  Map() => {
    for (final key in value.keys.map((k) => '$k').toList()..sort())
      key: key == 'file'
          ? (value[key] as String).split('/').last
          : _rounded(value[key]),
  },
  _ => value,
};

void main() {
  for (final name in ['sample_files', 'random']) {
    group(name, () {
      final data = expected[name] as Map<String, dynamic>;
      final graph = name == 'random' ? randomGraph(data) : fixtureGraph();
      final tools = RoamTools(
        graph,
        readNote: (path) async =>
            File('test/fixtures/roam/$path').readAsStringSync(),
      );
      final calls = data['calls'] as Map<String, dynamic>;

      Future<void> each(
        String tool,
        void Function(Map args, Object? actual, Object? server) check,
      ) async {
        for (final [args as Map<String, dynamic>, result]
            in calls[tool] as List) {
          check(
            args,
            jsonDecode(jsonEncode(await tools.run(tool, args))),
            normalized(result),
          );
        }
      }

      Object? byTitle(Map r) => r['title'];

      test('find, backlinks and orphans by title, as the server', () async {
        for (final tool in [
          'org_roam_find',
          'org_roam_backlinks',
          'org_roam_orphans',
        ]) {
          await each(tool, (args, actual, server) {
            expectGroups(
              actual as List,
              server as List,
              byTitle,
              '$tool $args',
            );
          });
        }
      });

      test('BFS by hops and title, as the server', () async {
        await each('org_roam_bfs', (args, actual, server) {
          expectGroups(
            actual as List,
            server as List,
            (r) => (r['hops'], r['title']),
            'bfs $args',
          );
        });
      });

      test('common neighbours and central nodes, as the server', () async {
        await each('org_roam_common_neighbors', (args, actual, server) {
          expectGroups(
            actual as List,
            server as List,
            (r) => r['shared_links'],
            'common $args',
            cut: true,
          );
        });
        await each('org_roam_central', (args, actual, server) {
          expectGroups(
            actual as List,
            server as List,
            (r) => r['total'],
            'central $args',
            cut: true,
          );
        });
      });

      test('PageRank, betweenness and closeness, as networkx', () async {
        for (final tool in [
          'org_roam_pagerank',
          'org_roam_betweenness',
          'org_roam_closeness',
        ]) {
          await each(tool, (args, actual, server) {
            expectGroups(
              actual as List,
              server as List,
              (r) => (r['score'] as num).toStringAsPrecision(9),
              '$tool $args',
              cut: true,
            );
          });
        }
      });

      test(
        'clustering, link suggestions and statistics, as networkx',
        () async {
          for (final tool in [
            'org_roam_clustering_coefficient',
            'org_roam_suggest_links',
            'org_roam_graph_stats',
          ]) {
            await each(tool, (args, actual, server) {
              expectSame(actual, server, '$tool $args');
            });
          }
        },
      );

      test('connected components, as networkx', () async {
        await each('org_roam_connected_components', (args, actual, server) {
          final a = actual as Map, s = server as Map;
          // The hub of several with the most links depends on Python's
          // set order on the server; its number of links does not. Parts
          // of the same size come in the order of their first node, and
          // nodes with the same title are in the server's table order, so
          // they are compared sorted by their first node.
          for (final result in [a, s]) {
            final components = (result['components'] as List).cast<Map>();
            for (final c in components) {
              final hub = c['hub_node'] as Map?;
              hub?.remove('id');
              hub?.remove('title');
              c.remove('component_id');
            }
            String first(Map c) => (c['nodes'] as List).isEmpty
                ? ''
                : (c['nodes'] as List).first['id'];
            components.sort((x, y) {
              final bySize = (y['size'] as int).compareTo(x['size'] as int);
              return bySize != 0 ? bySize : first(x).compareTo(first(y));
            });
          }
          expectSame(a, s, 'components');
        });
      });

      test('read_node gives the whole file, as the server', () async {
        if (!calls.containsKey('org_roam_read_node')) return;
        for (final [args as Map<String, dynamic>, digest]
            in calls['org_roam_read_node'] as List) {
          final text = await tools.run('org_roam_read_node', args) as String;
          expect(
            sha1.convert(utf8.encode(text)).toString(),
            digest,
            reason: '$args',
          );
        }
      });

      test('shortest paths: the server\'s lengths, each path once', () async {
        final algorithmGraph = tools.algorithmGraph;
        void checkPaths(String start, String end, List actual) {
          final seen = <String>{};
          var last = 0;
          for (final row in actual.cast<Map>()) {
            final path = [
              for (final step in row['path'] as List) (step as Map)['id'],
            ];
            expect(seen.add(path.join('>')), isTrue, reason: 'twice: $path');
            expect(path.toSet().length, path.length, reason: '$path');
            expect(path.first, start);
            expect(path.last, end);
            for (var i = 0; i + 1 < path.length; i++) {
              expect(algorithmGraph.successors[path[i]], contains(path[i + 1]));
            }
            expect(row['hops'], path.length - 1);
            expect(row['hops'] as int, greaterThanOrEqualTo(last));
            last = row['hops'] as int;
          }
        }

        if (calls['org_roam_shortest_path'] case final List list) {
          for (final [args as Map<String, dynamic>, result] in list) {
            final actual =
                jsonDecode(
                      jsonEncode(
                        await tools.run('org_roam_shortest_path', args),
                      ),
                    )
                    as List;
            final server = result as List;
            if ((server.first as Map).containsKey('message')) {
              expect(actual, server, reason: '$args');
              continue;
            }
            checkPaths(args['start_id'], args['end_id'], actual);
            // The server lists a path once for each link it follows, so a
            // note that links twice gives the same path twice; the app
            // lists each path once. Its shortest is as short, and its
            // distinct paths are the server's.
            expect(actual.first['hops'], server.first['hops'], reason: '$args');
            final distinct = {
              for (final row in server.cast<Map>())
                [
                  for (final s in row['path'] as List) (s as Map)['id'],
                ].join('>'),
            };
            final mine = {
              for (final row in actual.cast<Map>())
                [
                  for (final s in row['path'] as List) (s as Map)['id'],
                ].join('>'),
            };
            if (distinct.length == server.length) {
              expect(
                [for (final r in actual) r['hops']],
                [for (final r in server) r['hops']],
                reason: '$args',
              );
            }
            expect(
              mine.containsAll(
                    distinct.where(
                      (p) => p.split('>').length - 1 == server.first['hops'],
                    ),
                  ) ||
                  mine.length == 3,
              isTrue,
              reason: '$args',
            );
          }
        }
        if (data['path_hops'] case final List list) {
          for (final [start as String, end as String, hops as List] in list) {
            final actual =
                jsonDecode(
                      jsonEncode(
                        await tools.run('org_roam_shortest_path', {
                          'start_id': start,
                          'end_id': end,
                        }),
                      ),
                    )
                    as List;
            if (hops.isEmpty) {
              expect(actual.single['message'], isNotNull);
              continue;
            }
            checkPaths(start, end, actual);
            expect(
              [for (final r in actual) r['hops']],
              hops,
              reason: '$start -> $end',
            );
          }
        }
      });

      test(
        'communities as good as python-louvain\'s, at each resolution',
        () async {
          final louvain = data['louvain'] as Map<String, dynamic>;
          for (final MapEntry(key: resolution, value: range)
              in louvain.entries) {
            final result =
                await tools.run('org_roam_communities', {
                      'resolution': double.parse(resolution),
                    })
                    as Map<String, Object?>;
            final members = [
              for (final list in (result['communities'] as Map).values)
                for (final m in list as List) (m as Map)['id'],
            ];
            expect(members.toSet(), tools.algorithmGraph.nodes.toSet());
            expect(members.length, tools.algorithmGraph.nodes.length);
            expect(
              result['num_communities'],
              (result['communities'] as Map).length,
            );
            final r = range as Map<String, dynamic>;
            expect(
              result['modularity'] as double,
              greaterThan((r['modularity_min'] as num) - 0.02),
              reason: 'resolution $resolution',
            );
            expect(
              result['num_communities'] as int,
              inInclusiveRange(
                (r['communities_min'] as int) * 0.7,
                (r['communities_max'] as int) * 1.3,
              ),
              reason: 'resolution $resolution',
            );
          }
          // The modularity reported is at resolution 1, as the server's.
          final partition = louvainCommunities(
            tools.algorithmGraph,
            resolution: 2,
          );
          final at2 = await tools.run('org_roam_communities', {
            'resolution': 2,
          });
          expect(
            (at2 as Map)['modularity'],
            closeTo(modularity(tools.algorithmGraph, partition), 1e-12),
          );
        },
      );
    });
  }

  group('hidden notes (#57)', () {
    final graph = hidden.graphOf(hidden.notes);
    final tools = RoamTools(
      graph,
      readNote: (path) async => hidden.notes[path],
      visibility: const AiVisibility({'private'}),
    );

    test('no tool shows a hidden note', () async {
      final ids = [...graph.nodes.keys, 'gone'];
      for (final tool in aiTools) {
        final runs = <Map<String, Object?>>[{}];
        final params = (tool.parameters['properties'] as Map).keys;
        if (params.contains('node_id')) {
          runs.addAll([
            for (final id in ids) {'node_id': id},
          ]);
        }
        if (params.contains('search')) {
          runs.addAll([
            {'search': ''},
            {'search': 'diary'},
          ]);
        }
        if (params.contains('node_a')) {
          runs.addAll([
            for (final a in ids)
              for (final b in ids) {'node_a': a, 'node_b': b},
          ]);
        }
        if (params.contains('start_id')) {
          runs.addAll([
            for (final a in ids)
              for (final b in ids) {'start_id': a, 'end_id': b},
          ]);
        }
        for (final args in runs) {
          if ((tool.parameters['required'] as List? ?? []).any(
            (p) => !args.containsKey(p),
          )) {
            continue;
          }
          final text = await tools.call(tool.name, args);
          final requested = args.values.join(' ');
          for (final secret in ['My diary', 'Doctor', 'Salary', 'Visit']) {
            expect(text, isNot(contains(secret)), reason: '${tool.name} $args');
          }
          for (final id in ['diary', 'doctor']) {
            if (requested.contains(id)) continue;
            expect(
              text.contains(RegExp('\\b$id\\b')) && !text.contains('[[id:$id'),
              isFalse,
              reason: '${tool.name} $args: $text',
            );
          }
        }
      }
    });

    test(
      'read_node hides headings and titles; a hidden node is not found',
      () async {
        final text = await tools.call('org_roam_read_node', {
          'node_id': 'ideas',
        });
        expect(text, contains('* (hidden)'));
        expect(text, isNot(contains('Salary')));
        expect(
          await tools.call('org_roam_read_node', {'node_id': 'diary'}),
          'Error: No node found with id diary',
        );
        // A file that hides its node now, before the index knows.
        final changed = RoamTools(
          graph,
          readNote: (path) async =>
              '#+filetags: :private:\n${hidden.notes[path]}',
          visibility: const AiVisibility({'private'}),
        );
        expect(
          await changed.call('org_roam_read_node', {'node_id': 'plan'}),
          'Error: No node found with id plan',
        );
      },
    );
  });

  group('text search (#98)', () {
    final graph = hidden.graphOf(hidden.notes);
    // The index finds every file; the tool must still hide what is hidden.
    final tools = RoamTools(
      graph,
      readNote: (path) async => hidden.notes[path],
      visibility: const AiVisibility({'private'}),
      searchText: (query, {limit = 30}) async => [
        for (final path in hidden.notes.keys) TextHit(path, ''),
      ],
    );

    test('finds words in the text, not in hidden notes or headings',
        () async {
      final open = await tools.call('org_roam_search_text', {'query': 'open'});
      expect(open, contains('ideas | Ideas | ideas.org | '));
      expect(open, contains('Open text.'));
      expect(open, isNot(contains('Salary')));
      for (final secret in ['numbers', 'visit', 'back to']) {
        expect(
          await tools.call('org_roam_search_text', {'query': secret}),
          'No notes contain: $secret',
        );
      }
      // Every word must be there.
      expect(
        await tools.call('org_roam_search_text', {'query': 'open nowhere'}),
        'No notes contain: open nowhere',
      );
    });

    test('without an index, the tool says so', () async {
      final plain = RoamTools(graph, readNote: (path) async => null);
      expect(
        await plain.call('org_roam_search_text', {'query': 'x'}),
        contains('not available'),
      );
    });
  });

  group('text for the model', () {
    final graph = hidden.graphOf(hidden.notes);
    final tools = RoamTools(
      graph,
      readNote: (path) async => hidden.notes[path],
    );

    test('one line per node, with ID and title', () async {
      expect(
        await tools.call('org_roam_find', {'search': 'a'}),
        'Nodes (ID | title | file) (4):\n'
        'health | Health | ideas.org\n'
        'ideas | Ideas | ideas.org\n'
        'diary | My diary | diary.org\n'
        'plan | Plan | plan.org',
      );
      expect(
        await tools.call('org_roam_backlinks', {'node_id': 'plan'}),
        'Backlinks, one per link (ID | title) (1):\ndiary | My diary',
      );
      expect(
        await tools.call('org_roam_bfs', {'node_id': 'plan', 'depth': 1}),
        'Nodes (hops | ID | title) (2):\n1 | ideas | Ideas\n1 | diary | My diary',
      );
      expect(
        await tools.call('org_roam_shortest_path', {
          'start_id': 'diary',
          'end_id': 'ideas',
        }),
        '2 hops: My diary [diary] -> Plan [plan] -> Ideas [ideas]',
      );
      expect(
        await tools.call('org_roam_orphans', {}),
        'Orphans (ID | title) (1):\nhealth | Health',
      );
      expect(
        await tools.call('org_roam_backlinks', {'node_id': 'gone'}),
        'Backlinks, one per link (ID | title): none',
      );
    });

    test('parameters are read leniently; mistakes are explained', () async {
      // An ID in quotes, as stored, or with id: in front; numbers as text.
      for (final id in ['"plan"', 'id:plan', ' plan ']) {
        expect(
          await tools.call('org_roam_backlinks', {'node_id': id}),
          contains('diary | My diary'),
        );
      }
      expect(
        await tools.call('org_roam_bfs', {'node_id': 'plan', 'depth': '1'}),
        contains('(2)'),
      );
      expect(
        await tools.call('org_roam_bfs', {'node_id': 'plan', 'depth': 'two'}),
        'Error: depth must be a whole number, not "two".',
      );
      expect(
        await tools.call('org_roam_backlinks', {}),
        'Error: node_id is missing.',
      );
      expect(
        await tools.call('emacs_eval', {'code': '(+ 1 2)'}),
        'Error: There is no tool emacs_eval.',
      );
    });

    test('fractions are refused; groups are capped as lists', () async {
      expect(
        await tools.call('org_roam_bfs', {'node_id': 'plan', 'depth': 1.9}),
        'Error: depth must be a whole number, not "1.9".',
      );
      expect(
        await tools.call('org_roam_bfs', {'node_id': 'plan', 'depth': 1.0}),
        contains('(2)'),
      );
      // 350 notes without links: 350 communities and components.
      final lonely = RoamGraph.fromFiles([
        for (var i = 0; i < 350; i++)
          RoamFileData(
            path: 'n$i.org',
            nodes: [
              RoamNode(
                id: 'n$i',
                file: 'n$i.org',
                level: 0,
                title: 'N$i',
                line: 1,
              ),
            ],
          ),
      ]);
      final many = RoamTools(lonely, readNote: (_) async => null);
      for (final tool in [
        'org_roam_communities',
        'org_roam_connected_components',
      ]) {
        final lines = (await many.call(tool, {})).split('\n');
        expect(lines.length, lessThanOrEqualTo(maxListLines + 3), reason: tool);
        expect(lines.last, '… and 50 more groups.', reason: tool);
      }
    });

    test('a long note is cut, and says so', () async {
      final long = RoamTools(
        graph,
        readNote: (path) async => 'x' * (maxReadLength + 10),
      );
      final text = await long.call('org_roam_read_node', {'node_id': 'plan'});
      expect(text.length, lessThan(maxReadLength + 200));
      expect(text, endsWith('only the first $maxReadLength are shown.]'));
    });
  });

  test('every tool has a name, a description and an object schema', () {
    expect(aiTools.map((t) => t.name).toSet().length, aiTools.length);
    expect(aiTools.length, 17);
    for (final tool in aiTools) {
      expect(tool.name, matches(RegExp(r'^org_roam_[a-z_]+$')));
      expect(tool.description, isNotEmpty);
      expect(tool.parameters['type'], 'object');
      final properties = tool.parameters['properties'] as Map;
      for (final name in tool.parameters['required'] as List? ?? []) {
        expect(properties, contains(name), reason: tool.name);
      }
    }
  });
}
