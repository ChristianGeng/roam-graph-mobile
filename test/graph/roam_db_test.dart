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
      // c.org has rows in every table.
      const c = ':PROPERTIES:\n:ID: c\n:ROAM_ALIASES: Sea\n'
          ':ROAM_REFS: https://example.org @key\n:END:\n'
          '#+title: C\n#+filetags: :c:\n[[id:a]] [cite:@other]\n';
      updateIndex(db, {'a.org': 1, 'c.org': 1},
          {'a.org': bytes(a), 'c.org': bytes(c)});
      final before = db.dumpTables();
      for (final table in roamTables) {
        expect(before[table], isNotEmpty, reason: table);
      }
      final graph = updateIndex(db, {'a.org': 1}, {});
      expect(graph.files, ['a.org']);
      final after = db.dumpTables();
      for (final table in roamTables) {
        expect(after[table], hasLength(before[table]!.length - _rowsOfC(table)),
            reason: table);
      }
      expect(after['aliases'], isEmpty);
      expect(after['refs'], isEmpty);
      expect(after['citations'], isEmpty);
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
      final before = db.dumpTables(); // without the times
      updateIndex(db, {'a.org': 9000}, {'a.org': bytes(a)});
      expect(db.storedFiles()['a.org']!.mtime, 9000);
      expect(db.dumpTables(), before);
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

    test('the schema is org-roam version 20, with its columns', () {
      expect(db.userVersion, 20);
      expect({for (final table in roamTables) table: db.columns(table)}, {
        'files': ['file', 'title', 'hash', 'atime', 'mtime'],
        'nodes': ['id', 'file', 'level', 'pos', 'todo', 'priority',
            'scheduled', 'deadline', 'title', 'properties', 'olp'],
        'aliases': ['node_id', 'alias'],
        'citations': ['node_id', 'cite_key', 'pos', 'properties'],
        'refs': ['node_id', 'ref', 'type'],
        'tags': ['node_id', 'tag'],
        'links': ['pos', 'source', 'dest', 'type', 'properties'],
      });
    });

    test('files without a modification time are always read', () {
      updateIndex(db, {'a.org': 0}, {'a.org': bytes(a)});
      expect(filesToRead(db, {'a.org': 0}), ['a.org']);
    });

    test('a replacing update drops what was stored before', () {
      updateIndex(db, {'a.org': 1, 'b.org': 1},
          {'a.org': bytes(a), 'b.org': bytes(b)});
      updateIndex(db, {'b.org': 1}, {'b.org': bytes(b)}, replace: true);
      expect(db.storedFiles().keys, ['b.org']);
    });

    test('a replacing update keeps an unreadable file, unless told not to',
        () {
      updateIndex(db, {'a.org': 1, 'b.org': 1},
          {'a.org': bytes(a), 'b.org': bytes(b)});
      updateIndex(db, {'a.org': 1, 'b.org': 1},
          {'a.org': bytes(a), 'b.org': null}, replace: true);
      expect(db.storedFiles().keys, unorderedEquals(['a.org', 'b.org']));
      updateIndex(db, {'a.org': 1, 'b.org': 1},
          {'a.org': bytes(a), 'b.org': null},
          replace: true, keepUnreadable: false);
      expect(db.storedFiles().keys, ['a.org']);
    });
  });
}

/// The rows c.org has in [table], in the removal test.
int _rowsOfC(String table) => switch (table) {
      'files' || 'nodes' || 'aliases' || 'tags' || 'links' || 'citations' => 1,
      'refs' => 2,
      _ => 0,
    };
