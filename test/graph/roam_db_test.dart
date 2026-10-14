import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/elisp.dart';
import 'package:roam_graph_mobile/graph/indexer.dart';
import 'package:roam_graph_mobile/graph/roam_db.dart';

Uint8List bytes(String text) => utf8.encode(text);

void main() {
  group('Emacs Lisp printing', () {
    test('strings keep their quotes, as emacsql stores them', () {
      expect(elispString('abc'), '"abc"');
      expect(elispString('say "hi" \\'), r'"say \"hi\" \\"');
      expect(elispString('a\nb'), r'"a\nb"');
      expect(elispString('TODO\tPlan'), r'"TODO\11Plan"');
      // Three digits when an octal digit follows, as Emacs prints it.
      expect(elispString('\t7'), r'"\0117"');
      expect(elispString('Übung 🙂'), '"Übung 🙂"');
    });

    test('lists, text properties, and reading back', () {
      expect(elispList([]), 'nil');
      expect(elispList(['A', 'B']), '("A" "B")');
      expect(elispPropertized(':a:b:', [(1, 2)]), '#(":a:b:" 1 2 (inherited t))');
      expect(elispPropertized(':a:', []), '":a:"');
      for (final text in ['plain', 'say "hi" \\', 'a\nb', 'TODO\tPlan', '\t7']) {
        expect(decodeElispString(elispString(text)), text);
      }
      expect(decodeElispString('#("tag" 0 3 (inherited t))'), 'tag');
    });
  });

  group('RoamDatabase', () {
    late RoamDatabase db;
    setUp(() => db = RoamDatabase.inMemory(root: '/roam'));
    tearDown(() => db.close());

    const a = ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n#+filetags: :t:\n'
        '[[id:b]] [[https://example.com][web]]\n';
    const b = ':PROPERTIES:\n:ID: b\n:ROAM_ALIASES: Bee\n:END:\n';

    test('stores paths below the root, and remembers hash and time', () {
      updateIndex(db, {'a.org': 5000}, {'a.org': bytes(a)});
      final stored = db.storedFiles();
      expect(stored.keys, ['a.org']);
      expect(stored['a.org']!.mtime, 5000);
      expect(stored['a.org']!.hash, hasLength(40));
      final tables = db.dumpTables();
      expect(tables['files']!.single.first, '"/roam/a.org"');
      expect(tables['links'], hasLength(2));
    });

    test('reads only new and changed files', () {
      updateIndex(db, {'a.org': 1, 'b.org': 1},
          {'a.org': bytes(a), 'b.org': bytes(b)});
      expect(filesToRead(db, {'a.org': 1, 'b.org': 1}), isEmpty);
      expect(filesToRead(db, {'a.org': 1, 'b.org': 2, 'c.org': 1}),
          ['b.org', 'c.org']);
    });

    test('a removed file takes its rows with it', () {
      updateIndex(db, {'a.org': 1, 'b.org': 1},
          {'a.org': bytes(a), 'b.org': bytes(b)});
      final graph = updateIndex(db, {'a.org': 1}, {});
      expect(graph.files, ['a.org']);
      final tables = db.dumpTables();
      expect(tables['nodes'], hasLength(1));
      expect(tables['aliases'], isEmpty);
    });

    test('the graph read back matches what was stored', () {
      final graph = updateIndex(db, {'a.org': 1, 'b.org': 1},
          {'a.org': bytes(a), 'b.org': bytes(b)});
      expect(graph.nodes.keys, unorderedEquals(['a', 'b']));
      expect(graph.links.single.dest, 'b');
      expect(graph.tagCount, 1);
      expect(graph.aliasCount, 1);
      expect(graph.nodes['a']!.title, 'A');
    });

    test('same content with a new time only updates the time', () {
      updateIndex(db, {'a.org': 1}, {'a.org': bytes(a)});
      updateIndex(db, {'a.org': 9000}, {'a.org': bytes(a)});
      expect(db.storedFiles()['a.org']!.mtime, 9000);
      expect(db.dumpTables()['nodes'], hasLength(1));
    });

    test('a file org-roam fails on is not stored, and is reported', () {
      final graph = updateIndex(db, {'bad.org': 1},
          {'bad.org': bytes(':PROPERTIES:\n:ID: x\n:ROAM_ALIASES: "open\n:END:\n')});
      expect(db.storedFiles(), isEmpty);
      expect(graph.failedFiles.keys, ['bad.org']);
    });

    test('an ID used twice keeps the first node and is reported', () {
      final graph = updateIndex(db, {'a.org': 1, 'b.org': 1}, {
        'a.org': bytes(':PROPERTIES:\n:ID: same\n:END:\n'),
        'b.org': bytes(':PROPERTIES:\n:ID: same\n:END:\n'),
      });
      expect(graph.nodes, hasLength(1));
      expect(graph.duplicateIds, {
        'same': ['a.org', 'b.org'],
      });
    });

    test('the schema is org-roam version 20', () {
      expect(orgRoamDbVersion, 20);
      expect(db.dumpTables().keys, roamTables);
    });
  });
}
