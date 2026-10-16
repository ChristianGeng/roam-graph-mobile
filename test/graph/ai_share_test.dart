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
    file('id-d', 'Plan | Draft'),
  ]);
  final text = graphForAi(graph);
  final lines = text.split('\n');

  test('a header that says what it is and how to link', () {
    expect(lines.first, '# My org-roam graph: 4 nodes, 2 links');
    expect(text, contains('[[id:<ID>][<title>]]'));
    expect(text, contains('ask me for it by title'));
  });

  test('nodes numbered in title order, with ID, title and tags', () {
    final start = lines.indexOf('## Nodes (number | ID | tags | title)');
    expect(lines.sublist(start + 1, start + 5), [
      'n1 | id-a | - | alpha',
      'n2 | id-b | x y | Beta',
      'n3 | id-c | - | Gamma note',
      // The title comes last, so " | " in it cannot look like tags.
      'n4 | id-d | - | Plan | Draft',
    ]);
  });

  test('each pair of linked nodes once; links to missing IDs left out', () {
    final start = lines.indexOf('## Links (source -> target)');
    expect(lines.sublist(start + 1).where((l) => l.isNotEmpty),
        ['n1 -> n2', 'n2 -> n1']);
  });

  group('nodes with their texts (#41)', () {
    const sampleFile = '#+title: F\n* A\n:PROPERTIES:\n:ID: a\n:END:\nText of A.\n'
        '** Inner\nMore of A.\n* B\nText of B.\n';

    test('a heading node: its heading and subtree', () {
      const a = RoamNode(id: 'a', file: 'f.org', level: 1, title: 'A', line: 2);
      expect(nodeText(a, sampleFile),
          '* A\n:PROPERTIES:\n:ID: a\n:END:\nText of A.\n** Inner\nMore of A.');
      const f = RoamNode(id: 'f', file: 'f.org', level: 0, title: 'F', line: 1);
      expect(nodeText(f, sampleFile), sampleFile);
    });

    test('ID, file, tags, links, backlinks and the Org text', () {
      final text = nodesForAi(graph, [(graph.nodes['id-a']!, 'Body of a.')]);
      expect(text, startsWith('# A note from my org-roam graph\n'));
      expect(text, contains('[[id:<ID>][<title>]]'));
      expect(text, contains('## alpha\n\n- ID: id-a\n- File: id-a.org\n'));
      expect(text, contains('- Links to: [[id:id-b][Beta]]\n'));
      expect(text, contains('- Linked from: [[id:id-b][Beta]]\n'));
      expect(text, contains('```org\nBody of a.\n```\n'));
    });

    test('the heading is found by its ID, not by the indexed line', () {
      // Indexed on line 2; lines were added above it since.
      const a = RoamNode(id: 'a', file: 'f.org', level: 1, title: 'A', line: 2);
      expect(nodeText(a, 'New line.\nAnother.\n$sampleFile'),
          startsWith('* A\n:PROPERTIES:\n:ID: a\n:END:\nText of A.'));
      // Gone from the file: nothing, rather than another note's text.
      expect(nodeText(a, '#+title: F\n* B\nText of B.\n'), isNull);
      final graphA = RoamGraph.fromFiles([
        const RoamFileData(path: 'f.org', nodes: [a]),
      ]);
      expect(nodesForAi(graphA, [(a, '* B\n')]),
          contains('(The heading is no longer in f.org; the file changed'));
    });

    test('a heading line inside a block ends the subtree, as in Org', () {
      // Org reads "* x" at the start of a line as a heading, also inside
      // a block (Org escapes such lines with a comma), as the node view
      // does with the same parser.
      const a = RoamNode(id: 'a', file: 'f.org', level: 1, title: 'A', line: 1);
      const text = '* A\n:PROPERTIES:\n:ID: a\n:END:\n#+begin_src org\n'
          '* inner\n#+end_src\nAfter.\n* B\n';
      expect(nodeText(a, text),
          '* A\n:PROPERTIES:\n:ID: a\n:END:\n#+begin_src org');
    });

    test('a fence longer than any backticks in the text', () {
      final text = nodesForAi(graph, [(graph.nodes['id-a']!, 'Code:\n```\nx\n```')]);
      expect(text, contains('````org\nCode:\n```\nx\n```\n````\n'));
    });

    test('links to titles with brackets are escaped as Org writes them', () {
      final g = RoamGraph.fromFiles([
        file('p', 'Plan', to: ['d']),
        file('d', 'Draft [2]'),
      ]);
      expect(nodesForAi(g, [(g.nodes['p']!, 'x')]),
          contains('- Links to: [[id:d][Draft [2]​]]\n'));
    });

    test('several nodes, tags, and a file that could not be read', () {
      final text = nodesForAi(graph, [
        (graph.nodes['id-b']!, 'B text'),
        (graph.nodes['id-c']!, null),
      ]);
      expect(text, startsWith('# 2 notes from my org-roam graph\n'));
      expect(text, contains('- Tags: x y\n'));
      // b links to a twice and to a missing ID.
      expect(text, contains('- Links to: [[id:id-a][alpha]], [[id:gone]]\n'));
      expect(text, contains('## Gamma note\n'));
      expect(text, contains('- Links to: none\n- Linked from: none\n'));
      expect(text, contains('(The file could not be read.)'));
    });
  });
}
