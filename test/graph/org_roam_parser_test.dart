import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

RoamFileData parse(String text, {String path = 'note.org'}) =>
    parseRoamFile(path, text);

List<String> dests(String text) =>
    [for (final link in parse(text).links) link.dest];

const drawer = ':PROPERTIES:\n:ID: file-id\n:END:\n';

void main() {
  group('file node', () {
    test('a file with a top drawer is a node with its title', () {
      final node = parse('$drawer#+title: Hello\n').nodes.single;
      expect(node.id, 'file-id');
      expect(node.level, 0);
      expect(node.title, 'Hello');
      expect(node.line, 1);
    });

    test('without #+title the title is empty, as in org-roam', () {
      final node = parse(drawer, path: 'sub/20240101-note.org').nodes.single;
      expect(node.title, '');
      expect(node.displayTitle, '20240101-note');
    });

    test('only comment lines may come before the drawer', () {
      expect(parse('# comment\n$drawer').nodes, hasLength(1));
      expect(parse('\n$drawer').nodes, isEmpty);
      expect(parse('#+title: x\n$drawer').nodes, isEmpty);
    });

    test('ROAM_EXCLUDE removes the node, unless it is nil', () {
      expect(
        parse(':PROPERTIES:\n:ID: x\n:ROAM_EXCLUDE: t\n:END:\n').nodes,
        isEmpty,
      );
      expect(
        parse(':PROPERTIES:\n:ID: x\n:ROAM_EXCLUDE: nil\n:END:\n').nodes,
        hasLength(1),
      );
    });

    test('an empty ID is no ID', () {
      expect(parse(':PROPERTIES:\n:ID:\n:END:\n').nodes, isEmpty);
    });

    test('CRLF line endings work', () {
      final file = parse(
        ':PROPERTIES:\r\n:ID: x\r\n:END:\r\n#+title: Win\r\n[[id:y]]\r\n',
      );
      expect(file.nodes.single.title, 'Win');
      expect(file.links.single.dest, 'y');
    });
  });

  group('heading nodes', () {
    test('title without keyword, priority and tags', () {
      final node = parse(
        '* TODO [#A] Plan [[id:x][the thing]] [1/2] :work:\n'
        ':PROPERTIES:\n:ID: h\n:END:\n',
      ).nodes.single;
      expect(node.level, 1);
      expect(node.title, 'Plan the thing [1/2]');
      expect(node.line, 1);
    });

    test("Doom's keywords are keywords, unless the file has its own", () {
      expect(
        parse('* PROJ Big\n:PROPERTIES:\n:ID: h\n:END:\n').nodes.single.title,
        'Big',
      );
      expect(
        parse('#+TODO: WAIT | DONE\n* TODO Big\n:PROPERTIES:\n:ID: h\n:END:\n')
            .nodes
            .single
            .title,
        'TODO Big',
      );
    });

    test('tags include file tags and ancestors, without repeats', () {
      final nodes = parse(
        '#+filetags: :f:\n'
        '* Top :a:\n'
        '** Child :b:a:\n'
        ':PROPERTIES:\n:ID: c\n:END:\n',
      ).nodes;
      expect(nodes.single.tags, ['f', 'b', 'a']);
    });

    test('the drawer must follow the heading or its planning line', () {
      expect(
        parse('* H\nSCHEDULED: <2024-01-01>\n:PROPERTIES:\n:ID: h\n:END:\n')
            .nodes,
        hasLength(1),
      );
      expect(parse('* H\n\n:PROPERTIES:\n:ID: h\n:END:\n').nodes, isEmpty);
    });

    test('a heading without a title is not a node', () {
      expect(parse('* :tag:\n:PROPERTIES:\n:ID: h\n:END:\n').nodes, isEmpty);
    });
  });

  group('aliases and refs', () {
    test('ROAM_ALIASES splits at spaces and keeps quoted words together', () {
      final node = parse(
        ':PROPERTIES:\n:ID: x\n:ROAM_ALIASES: A "B C"\n'
        ':ROAM_ALIASES+: D\n:END:\n',
      ).nodes.single;
      expect(node.aliases, ['A', 'B C', 'D']);
    });

    test('splitStringAndUnquote matches Emacs', () {
      expect(splitStringAndUnquote('a "b c" d"e f"g'),
          ['a', 'b c', 'd', 'e f', 'g']);
      expect(splitStringAndUnquote(''), isEmpty);
    });

    test('refs are read like org-roam reads them', () {
      List<List<String>> refs(String ref) =>
          [for (final r in parseRoamRef(ref)) [r.ref, r.type]];

      expect(refs('https://example.com/a'), [
        ['//example.com/a', 'https'],
      ]);
      expect(refs('@smith2020'), [
        ['smith2020', 'cite'],
      ]);
      expect(refs('[cite:@a;@b]'), [
        ['a', 'cite'],
        ['b', 'cite'],
      ]);
      expect(refs('[[https://example.org/p][Example]]'), [
        ['//example.org/p', 'https'],
      ]);
      expect(refs('doi:10.1000/xyz'), [
        ['10.1000/xyz', 'doi'],
      ]);
      expect(refs('https://example.com/a b'), [
        ['//example.com/a b', 'https'],
      ]);
      expect(refs('https://example.com/%C3%BC'), [
        ['//example.com/ü', 'https'],
      ]);
      // Not a registered link type, or not a link: org-roam skips them.
      expect(refs('cite:key'), isEmpty);
      expect(refs('nonsense'), isEmpty);
    });
  });

  group('links', () {
    test('bracket, plain and angle id links count', () {
      expect(
        dests('$drawer[[id:a]] [[id:b][B]] id:c, (id:d) <id:e>'),
        ['a', 'b', 'c', 'd', 'e'],
      );
    });

    test('a search option is not part of the ID', () {
      expect(dests('$drawer[[id:a::*Heading][x]]'), ['a']);
    });

    test('a description may wrap onto the next line', () {
      final file = parse('$drawer[[id:a][long\ndescription]] [[id:b]]');
      expect([for (final l in file.links) l.dest], ['a', 'b']);
      expect([for (final l in file.links) l.line], [4, 5]);
    });

    test('verbatim, code, comments and source blocks hide links', () {
      expect(
        dests('$drawer'
            '=[[id:a]]= ~x [[id:b]] y~ src_python{"[[id:c]]"}\n'
            '# [[id:d]]\n'
            ': [[id:e]]\n'
            '#+begin_src emacs-lisp\n[[id:f]]\n#+end_src\n'
            '#+BEGIN_EXAMPLE\n[[id:g]]\n#+END_EXAMPLE\n'
            '#+begin_quote\n[[id:h]]\n#+end_quote\n'),
        ['h'],
      );
    });

    test('a heading ends an unclosed block', () {
      expect(
        dests('$drawer#+begin_src\n[[id:a]]\n* H\n[[id:b]]\n'),
        ['a', 'b'],
      );
    });

    test('an id inside another link or URL is no id link', () {
      expect(
        dests('$drawer'
            'https://example.com/?q=id:a [[https://example.com/id:b][x]]'),
        isEmpty,
      );
    });

    test('property and keyword links count, except ROAM_REFS and transclude',
        () {
      expect(
        dests(':PROPERTIES:\n:ID: x\n:ROAM_REFS: [[id:a]]\n'
            ':RELATED: [[id:b]]\n:END:\n'
            '#+title: [[id:c][C]]\n#+transclude: [[id:d]]\n'),
        ['b', 'c'],
      );
    });

    test('links belong to the nearest node above them', () {
      final links = parse('$drawer'
              '[[id:a]]\n'
              '* Node\n:PROPERTIES:\n:ID: h\n:END:\n'
              '** Not a node\n[[id:b]]\n'
              '* Excluded\n:PROPERTIES:\n:ID: e\n:ROAM_EXCLUDE: t\n:END:\n'
              '[[id:c]]\n')
          .links;
      expect([for (final l in links) '${l.source}>${l.dest}'],
          ['file-id>a', 'h>b', 'file-id>c']);
    });

    test('links without a node above them are dropped', () {
      expect(parse('[[id:a]]\n* H\n[[id:b]]\n').links, isEmpty);
    });
  });

  group('RoamGraph', () {
    RoamFileData file(String path, List<String> ids, List<String> linksTo) =>
        RoamFileData(
          path: path,
          nodes: [
            for (final id in ids)
              RoamNode(id: id, file: path, level: 0, title: id, line: 1,
                  tags: const ['t']),
          ],
          links: [
            for (final dest in linksTo)
              RoamLink(source: ids.first, dest: dest, file: path, line: 2),
          ],
        );

    test('counts nodes, links and links to missing notes', () {
      final graph = RoamGraph.fromFiles([
        file('a.org', ['a'], ['b', 'missing']),
        file('b.org', ['b'], ['a']),
      ]);
      expect(graph.nodes.keys, unorderedEquals(['a', 'b']));
      expect(graph.links, hasLength(3));
      expect([for (final l in graph.danglingLinks) l.dest], ['missing']);
      expect(graph.tagCount, 2);
      expect(graph.duplicateIds, isEmpty);
    });

    test('reports IDs used twice and keeps the first by path', () {
      final graph = RoamGraph.fromFiles([
        file('b.org', ['x'], []),
        file('a.org', ['x'], []),
      ]);
      expect(graph.nodes['x']!.file, 'a.org');
      expect(graph.duplicateIds, {
        'x': ['a.org', 'b.org'],
      });
    });
  });
}
