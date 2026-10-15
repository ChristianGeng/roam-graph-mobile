import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/node_search.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

RoamFileData file(
  String id,
  String title, {
  int mtime = 0,
  List<String> aliases = const [],
  List<String> tags = const [],
}) =>
    RoamFileData(
      path: '$id.org',
      mtime: mtime,
      nodes: [
        RoamNode(
          id: id, file: '$id.org', level: 0, title: title, line: 1,
          aliases: aliases, tags: tags),
      ],
    );

final graph = RoamGraph.fromFiles([
  file('emacs', 'Emacs Lisp basics', mtime: 300, tags: ['emacs', 'code']),
  file('roam', 'Org-roam setup', mtime: 100, aliases: ['Zettelkasten'],
      tags: ['emacs']),
  file('flutter', 'Flutter and Dart', mtime: 200, tags: ['code']),
  file('old', 'Old notes on lisp', tags: ['archive']),
  const RoamFileData(path: '20240101-untitled.org', nodes: [
    RoamNode(
        id: 'u', file: '20240101-untitled.org', level: 0, title: '', line: 1),
  ]),
]);

List<String> found(String query, {Set<String> tags = const {}}) =>
    [for (final hit in searchNodes(graph, query, tags: tags)) hit.text];

void main() {
  test('everything, newest file first', () {
    expect(found(''), [
      'Emacs Lisp basics',
      'Flutter and Dart',
      'Org-roam setup',
      'Zettelkasten',
      // Unknown times last, in path order.
      '20240101-untitled',
      'Old notes on lisp',
    ]);
  });

  test('part of the title, ignoring case', () {
    expect(found('LISP'), ['Emacs Lisp basics', 'Old notes on lisp']);
    expect(found('fl'), ['Flutter and Dart']);
    expect(found('nothing like this'), isEmpty);
  });

  test('every word, in any order', () {
    expect(found('lisp old'), ['Old notes on lisp']);
    expect(found('  dart   flutter '), ['Flutter and Dart']);
  });

  test('an alias is a candidate of its own', () {
    final hits = searchNodes(graph, 'zettel');
    expect(hits.single.node.id, 'roam');
    expect(hits.single.alias, 'Zettelkasten');
    expect(found('setup'), ['Org-roam setup']);
  });

  test('a node without a title is found by its file name', () {
    expect(found('untitled'), ['20240101-untitled']);
  });

  test('tags filter, all of them', () {
    expect(found('', tags: {'emacs'}),
        ['Emacs Lisp basics', 'Org-roam setup', 'Zettelkasten']);
    expect(found('', tags: {'emacs', 'code'}), ['Emacs Lisp basics']);
    expect(found('lisp', tags: {'archive'}), ['Old notes on lisp']);
  });

  test('tags, the most used first', () {
    expect(tagsByUse(graph), ['code', 'emacs', 'archive']);
  });
}
