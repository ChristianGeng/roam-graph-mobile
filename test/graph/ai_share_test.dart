import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/ai_share.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

RoamFileData file(String id, String title,
        {List<String> tags = const [], List<String> to = const []}) =>
    RoamFileData(
      path: '$id.org',
      nodes: [
        RoamNode(
            id: id, file: '$id.org', level: 0, title: title, line: 1,
            tags: tags),
      ],
      links: [
        for (final dest in to)
          RoamLink(source: id, dest: dest, file: '$id.org', line: 1),
      ],
    );

void main() {
  final graph = RoamGraph.fromFiles([
    file('id-b', 'Beta', tags: ['x', 'y'], to: ['id-a', 'id-a', 'gone']),
    file('id-a', 'alpha', to: ['id-b']),
    file('id-c', 'Gamma\nnote'),
  ]);
  final text = graphForAi(graph);
  final lines = text.split('\n');

  test('a header that says what it is and how to link', () {
    expect(lines.first, '# My org-roam graph: 3 nodes, 2 links');
    expect(text, contains('[[id:<ID>][<title>]]'));
    expect(text, contains('ask me for it by title'));
  });

  test('nodes numbered in title order, with ID, title and tags', () {
    final start = lines.indexOf('## Nodes (number | ID | title | tags)');
    expect(lines.sublist(start + 1, start + 4), [
      'n1 | id-a | alpha',
      'n2 | id-b | Beta | x y',
      'n3 | id-c | Gamma note',
    ]);
  });

  test('each pair of linked nodes once; links to missing IDs left out', () {
    final start = lines.indexOf('## Links (source -> target)');
    expect(lines.sublist(start + 1).where((l) => l.isNotEmpty),
        ['n1 -> n2', 'n2 -> n1']);
  });
}
