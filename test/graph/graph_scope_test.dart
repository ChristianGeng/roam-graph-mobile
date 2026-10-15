import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/graph_scope.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:sqlite3/sqlite3.dart';

RoamNode node(String id, {String title = ''}) => RoamNode(
      id: id,
      file: '$id.org',
      level: 0,
      title: title.isEmpty ? id.toUpperCase() : title,
      line: 1,
    );

RoamLink link(String source, String dest) =>
    RoamLink(source: source, dest: dest, file: '$source.org', line: 1);

/// A graph of the nodes [ids], with the links [links] as `source>dest`.
RoamGraph graphOf(List<String> ids, List<String> links) {
  final bySource = <String, List<RoamLink>>{};
  for (final pair in links) {
    final [source, dest] = pair.split('>');
    bySource.putIfAbsent(source, () => []).add(link(source, dest));
  }
  return RoamGraph.fromFiles([
    for (final id in ids)
      RoamFileData(path: '$id.org', nodes: [node(id)], links: bySource[id] ?? []),
  ]);
}

Set<String> edgesOf(DrawnGraph drawn) =>
    {for (final (:source, :dest) in drawn.edges) '$source>$dest'};

Set<String> nodesOf(DrawnGraph drawn) => {for (final n in drawn.nodes) n.id};

/// The sample files in test/fixtures/roam/, parsed.
RoamGraph fixtureGraph() {
  const root = 'test/fixtures/roam';
  return RoamGraph.fromFiles([
    for (final entity in Directory(root).listSync(recursive: true))
      if (entity is File)
        if (entity.path.substring(root.length + 1) case final path
            when isRoamFile(path))
          parseRoamFile(path, entity.readAsStringSync()),
  ]);
}

/// A random graph of [nodes] nodes and [links] links, some to IDs that are
/// no node.
RoamGraph randomGraph(int nodes, int links, int seed) {
  final random = Random(seed);
  final ids = [for (var i = 0; i < nodes; i++) 'n$i'];
  return graphOf(ids, [
    for (var i = 0; i < links; i++)
      '${ids[random.nextInt(nodes)]}>'
          '${random.nextInt(20) == 0 ? 'gone$i' : ids[random.nextInt(nodes)]}',
  ]);
}

// The two queries of org-roam-graph--connected-component (org-roam-graph.el),
// unchanged but for the parameters: $s1 is ?1, $s2 is ?2.
const connectedComponentQuery = '''
WITH RECURSIVE
  links_of(source, dest) AS
  (SELECT source, dest FROM links UNION
   SELECT dest, source FROM links),
   connected_component(source) AS
  (SELECT dest FROM links_of WHERE source = ?1 UNION
   SELECT dest FROM links_of JOIN connected_component USING(source))
SELECT DISTINCT source, dest, type FROM links
WHERE source IN connected_component OR dest IN connected_component;''';

const maxDistanceQuery = '''
WITH RECURSIVE
  links_of(source, dest) AS
  (SELECT source, dest FROM links UNION
   SELECT dest, source FROM links),
  connected_component(source, trace) AS
  (VALUES (?1 , json_array(?1)) UNION
   SELECT lo.dest, json_insert(cc.trace, '\$[' || json_array_length(cc.trace) || ']', lo.dest) FROM
   connected_component AS cc JOIN links_of AS lo USING(source)
   WHERE (
    -- Avoid cycles by only visiting each node once.
    (SELECT count(*) FROM json_each(cc.trace) WHERE json_each.value == lo.dest) == 0
    -- Note: BFS is cut off early here.
    AND json_array_length(cc.trace) < ?2)),
  nodes(source) as (SELECT DISTINCT source
   FROM connected_component GROUP BY source ORDER BY min(json_array_length(trace)))
SELECT DISTINCT source, dest, type FROM links WHERE source IN nodes OR dest IN nodes;''';

/// The edges org-roam's query selects for [id] and [distance] (0 for
/// `C-u`), on a `links` table with the `id:` links of [graph].
Set<String> orgRoamEdges(Database db, String id, int distance) {
  final rows = distance == 0
      ? db.select(connectedComponentQuery, [id])
      : db.select(maxDistanceQuery, [id, distance]);
  return {for (final row in rows) '${row['source']}>${row['dest']}'};
}

Database linksTable(RoamGraph graph) {
  final db = sqlite3.openInMemory()
    ..execute('CREATE TABLE links (source, dest, type)');
  final insert = db.prepare('INSERT INTO links VALUES (?, ?, ?)');
  for (final link in graph.links) {
    insert.execute([link.source, link.dest, link.type]);
  }
  insert.dispose();
  return db;
}

void main() {
  group('the whole graph', () {
    test('one edge per pair of nodes, and every node', () {
      final graph = graphOf(
        ['a', 'b', 'c', 'lonely'],
        ['a>b', 'a>b', 'b>a', 'b>c', 'c>gone'],
      );
      final drawn = DrawnGraph.of(graph, const WholeGraph());

      expect(edgesOf(drawn), {'a>b', 'b>a', 'b>c', 'c>gone'});
      // The ends of the edges first, then the nodes without edges, as
      // org-roam writes them.
      expect([for (final n in drawn.nodes) n.id],
          ['a', 'b', 'c', 'gone', 'lonely']);
      final gone = drawn.nodes.firstWhere((n) => n.id == 'gone');
      expect(gone.isMissing, isTrue);
      expect(gone.label, 'id:gone');
      expect(drawn.nodes.first.label, 'A');
      expect(drawn.neighbours['b'], {'a', 'c'});
      expect(drawn.neighbours['lonely'], isEmpty);
    });

    test('only id: links are edges', () {
      final graph = RoamGraph.fromFiles([
        RoamFileData(path: 'a.org', nodes: [node('a')], links: [
          link('a', 'b'),
          const RoamLink(
              source: 'a', dest: '//example.com', file: 'a.org', line: 1,
              type: 'https'),
          const RoamLink(
              source: 'a', dest: 'b.org', file: 'a.org', line: 1,
              type: 'file'),
        ]),
        RoamFileData(path: 'b.org', nodes: [node('b')]),
      ]);
      expect(edgesOf(DrawnGraph.of(graph, const WholeGraph())), {'a>b'});
    });

    test('a node without a title shows its file name', () {
      final graph = RoamGraph.fromFiles([
        const RoamFileData(path: '20240101-x.org', nodes: [
          RoamNode(id: 'x', file: '20240101-x.org', level: 0, title: '', line: 1),
        ]),
      ]);
      expect(DrawnGraph.of(graph, const WholeGraph()).nodes.single.label,
          '20240101-x');
    });
  });

  test('titles longer than 100 characters are cut, as org-roam does', () {
    final exact = 'x' * 100;
    expect(truncateTitle(exact), exact);
    final long = 'Ü' * 101;
    expect(truncateTitle(long), '${'Ü' * 97}...');
    expect(truncateTitle(long).length, 100);
  });

  group('around a node', () {
    // a - b - c - d in a row, and e linked to both b and c.
    final graph = graphOf(
      ['a', 'b', 'c', 'd', 'e', 'other', 'x'],
      ['a>b', 'b>c', 'c>d', 'e>b', 'c>e', 'other>x'],
    );

    test('1 step: the node and its links', () {
      final drawn = DrawnGraph.of(graph, const Neighbourhood('b', 1));
      expect(edgesOf(drawn), {'a>b', 'b>c', 'e>b'});
      // c - e links two neighbours, but neither end is b: org-roam leaves
      // it out.
      expect(nodesOf(drawn), {'a', 'b', 'c', 'e'});
    });

    test('2 steps: also the links of its neighbours', () {
      final drawn = DrawnGraph.of(graph, const Neighbourhood('a', 2));
      expect(edgesOf(drawn), {'a>b', 'b>c', 'e>b'});
      expect(nodesOf(drawn), {'a', 'b', 'c', 'e'});
      expect(nodesOf(DrawnGraph.of(graph, const Neighbourhood('a', 3))),
          {'a', 'b', 'c', 'd', 'e'});
    });

    test('the connected part', () {
      final drawn = DrawnGraph.of(graph, const ConnectedPart('d'));
      expect(nodesOf(drawn), {'a', 'b', 'c', 'd', 'e'});
      expect(edgesOf(drawn), hasLength(5));
    });

    test('a node without links is still drawn', () {
      final lonely = graphOf(['a', 'b'], []);
      for (final scope in [
        const ConnectedPart('a'),
        const Neighbourhood('a', 2),
      ]) {
        final drawn = DrawnGraph.of(lonely, scope);
        expect(nodesOf(drawn), {'a'});
        expect(drawn.edges, isEmpty);
      }
    });
  });

  // org-roam-graph's own SQL, run on the id: links, gives the same edges
  // for every node and distance. org-roam follows links of every type;
  // decision 24 says why the app follows only id: links.
  for (final (name, graph) in [
    ('the sample files', fixtureGraph()),
    ('a random graph', randomGraph(60, 90, 3)),
  ]) {
    test('neighbourhoods match org-roam-graph\'s query on $name', () {
      final db = linksTable(graph);
      addTearDown(db.dispose);
      final ids = {
        ...graph.nodes.keys,
        for (final link in graph.links) link.dest,
      };
      var compared = 0;
      for (final id in ids) {
        for (final distance in [0, 1, 2, 3]) {
          final scope = distance == 0
              ? ConnectedPart(id) as GraphScope
              : Neighbourhood(id, distance);
          expect(
            edgesOf(DrawnGraph.of(graph, scope)),
            orgRoamEdges(db, id, distance),
            reason: '$id, distance $distance',
          );
          compared++;
        }
      }
      expect(compared, greaterThan(100));
    });
  }
}
