import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/backlinks.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

RoamNode node(String id, String title) =>
    RoamNode(id: id, file: '$id.org', level: 0, title: title, line: 1);

RoamLink link(String source, String dest, [List<String> outline = const []]) =>
    RoamLink(
        source: source, dest: dest, file: '$source.org', line: 1,
        outline: outline);

void main() {
  test('one backlink per link, sorted by title, links of a title in order',
      () {
    final graph = RoamGraph.fromFiles([
      RoamFileData(path: 'a.org', nodes: [node('a', 'Zebra')], links: [
        link('a', 't'),
      ]),
      RoamFileData(path: 'b.org', nodes: [node('b', 'Apple')], links: [
        link('b', 't', ['Second']),
        link('b', 'other'),
        link('b', 't', ['First']),
      ]),
      RoamFileData(path: 't.org', nodes: [node('t', 'Target')], links: [
        link('t', 't'),
      ]),
    ]);

    final backlinks = backlinksOf(graph, 't');
    expect(
      [for (final b in backlinks) '${b.source.title} (${b.outline})'],
      ['Apple (Second)', 'Apple (First)', 'Target (Top)', 'Zebra (Top)'],
    );
    expect(backlinksOf(graph, 'a'), isEmpty);
  });

  test('the outline shows link descriptions, joined by >', () {
    const backlink = Backlink(
      RoamNode(id: 's', file: 's.org', level: 0, title: 'S', line: 1),
      RoamLink(
        source: 's', dest: 't', file: 's.org', line: 3,
        outline: ['Projects', 'See [[id:x][the plan]]'],
      ),
    );
    expect(backlink.outline, 'Projects > See the plan');
  });

  // What Emacs 31's org-link-display-format returns for the same strings.
  test('link display format, as org-link-display-format', () {
    expect(linkDisplayFormat('a [[id:x][Desc]] b [[https://e.com]]'),
        'a Desc b https://e.com');
    expect(linkDisplayFormat('[[id:x][]]'), '[[id:x][]]');
    expect(linkDisplayFormat(r'[[file:a\]b.org]]'), r'file:a\]b.org');
    expect(linkDisplayFormat('no link'), 'no link');
    expect(linkDisplayFormat('[[id:y][with [nested] text]]'),
        'with [nested] text');
  });
}
