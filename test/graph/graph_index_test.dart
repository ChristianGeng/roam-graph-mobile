import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/graph_index.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('the marker names the folder and the root for the same parser', () {
    final marker = folderMarker('content://tree/org', '/notes/roam');
    expect(markedFolder(marker),
        (folder: 'content://tree/org', root: '/notes/roam'));
  });

  test('an index from another parser is no index: it is rebuilt', () {
    // Before the parser version, the marker held the folder alone.
    expect(markedFolder('content://tree/org'), isNull);
    final plain = folderMarker('content://tree/org', '/notes/roam',
        parserFingerprint(plainOrgRoamLinkTypes));
    expect(markedFolder(plain), isNull);
    expect(parserFingerprint(), contains('parser $parserVersion'));
  });

  test('a marker from before the root was kept is no index (#303)', () {
    expect(markedFolder('content://tree/org\n${parserFingerprint()}'),
        isNull);
  });

  group('the root of the paths in the database (#303)', () {
    String root(String setting,
            {String uri = 'content://tree/org',
            String name = 'org',
            String prefix = 'roam/',
            bool desktop = false}) =>
        databaseRoot(
          setting: setting,
          folderUri: uri,
          folderName: name,
          roamPrefix: prefix,
          desktop: desktop,
        );

    test('the setting, when it is set, on every platform', () {
      expect(root('/notes/elsewhere/roam'), '/notes/elsewhere/roam');
      expect(root('/notes/elsewhere/roam/', desktop: true),
          '/notes/elsewhere/roam');
      expect(root('  c:\\notes\\roam\\ '), 'c:/notes/roam');
    });

    test('not set on Android: /notes/ and the folder name', () {
      expect(root(''), '/notes/org/roam');
      expect(root('   '), '/notes/org/roam');
      expect(root('', name: 'roam', prefix: ''), '/notes/roam');
      // Never a slash from the name, nor an empty name.
      expect(root('', name: 'a/b'), '/notes/a_b/roam');
      expect(root('', name: ''), '/notes/notes/roam');
    });

    test('a setting with a line break counts as not set (#306)', () {
      // As from a view-settings.json edited by hand: the marker keeps the
      // root on one line.
      expect(cleanRoot('/emacs/org\n/roam'), isNull);
      expect(cleanRoot('/emacs/org\r\n/roam'), isNull);
      expect(cleanRoot('/emacs/org\r'), '/emacs/org');
      expect(root('/emacs/org\n/roam'), '/notes/org/roam');
      expect(root('/emacs/org\n/roam', uri: '/data/org', desktop: true),
          '/data/org/roam');
    });

    test('a folder name with a line break gives a root on one line (#306)',
        () {
      expect(root('', name: 'my\nnotes'), '/notes/my_notes/roam');
      expect(root('', name: 'my\r\nnotes', prefix: ''), '/notes/my__notes');
      final marker =
          folderMarker('content://tree/org', root('', name: 'my\nnotes'));
      expect(markedFolder(marker),
          (folder: 'content://tree/org', root: '/notes/my_notes/roam'));
    });

    test('not set on the desktop: the notes folder itself', () {
      expect(root('', uri: '/data/org', desktop: true), '/data/org/roam');
      expect(root('', uri: '/data/roam/', name: 'roam', prefix: '',
              desktop: true),
          '/data/roam');
      expect(root('', uri: r'C:\data\org', desktop: true),
          'C:/data/org/roam');
    });
  });

  group('SqliteGraphIndex stores the paths below the root (#303)', () {
    late Directory dir;
    late String path;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('graph-index-');
      path = '${dir.path}/org-roam.db';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    final contents = {
      'a.org': Uint8List.fromList(
          utf8.encode(':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n[[id:b]]\n')),
      'sub/b.org': Uint8List.fromList(
          utf8.encode(':PROPERTIES:\n:ID: b\n:END:\n#+title: B\n')),
    };
    const listing = {'a.org': 1, 'sub/b.org': 1};

    /// What the org-roam MCP server's queries read: `files.file` and
    /// `nodes.file`, as stored (Emacs Lisp strings).
    List<String> stored(String sql) {
      final db = sqlite3.open(path);
      try {
        return [for (final row in db.select(sql).rows) row[0]! as String]
          ..sort();
      } finally {
        db.dispose();
      }
    }

    test('the paths follow the root, and another root rebuilds the index',
        () async {
      final index = SqliteGraphIndex(databasePath: path);
      await index.update(listing, contents,
          folder: 'content://tree/org', root: '/notes/org/roam');
      expect(stored('SELECT file FROM files'),
          ['"/notes/org/roam/a.org"', '"/notes/org/roam/sub/b.org"']);
      expect(stored('SELECT file FROM nodes'),
          ['"/notes/org/roam/a.org"', '"/notes/org/roam/sub/b.org"']);
      expect(await index.indexedFolder(),
          (folder: 'content://tree/org', root: '/notes/org/roam'));
      expect(await index.filesToRead(listing, root: '/notes/org/roam'),
          isEmpty);

      // The setting changed: the folder screen sees another root and
      // reads every file again.
      expect(await index.filesToRead(listing, root: '/emacs/roam'),
          unorderedEquals(['a.org', 'sub/b.org']));
      final graph = await index.update(listing, contents,
          folder: 'content://tree/org', root: '/emacs/roam', replace: true);
      expect(stored('SELECT file FROM files'),
          ['"/emacs/roam/a.org"', '"/emacs/roam/sub/b.org"']);
      expect(stored('SELECT file FROM nodes'),
          ['"/emacs/roam/a.org"', '"/emacs/roam/sub/b.org"']);
      expect(await index.indexedFolder(),
          (folder: 'content://tree/org', root: '/emacs/roam'));
      // The graph itself keeps paths relative to roam/.
      expect(graph.nodes['a']!.file, 'a.org');
    });

    test('a folder name with a line break: no rebuild on the next scan '
        '(#306)', () async {
      final root = databaseRoot(
          setting: '',
          folderUri: 'content://tree/org',
          folderName: 'my\nnotes',
          roamPrefix: 'roam/',
          desktop: false);
      final index = SqliteGraphIndex(databasePath: path);
      await index.update(listing, contents,
          folder: 'content://tree/org', root: root);
      // What the folder screen compares to decide on a rebuild.
      expect(await index.indexedFolder(),
          (folder: 'content://tree/org', root: root));
      expect(await index.filesToRead(listing, root: root), isEmpty);
    });

    test('an update with another root rebuilds even without replace',
        () async {
      final index = SqliteGraphIndex(databasePath: path);
      await index.update(listing, contents,
          folder: 'content://tree/org', root: '/notes/org/roam');
      // A file that cannot be read now is not kept from the old root.
      await index.update(listing, {...contents, 'sub/b.org': null},
          folder: 'content://tree/org', root: '/emacs/roam');
      expect(stored('SELECT file FROM files'), ['"/emacs/roam/a.org"']);
    });
  });
}
