import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';

/// Entries as the folder access lists them. Paths ending in `/` are
/// directories.
List<FolderFile> entries(List<String> paths) => [
      for (final p in paths)
        p.endsWith('/')
            ? FolderFile(
                path: p.substring(0, p.length - 1),
                uri: 'content://test/$p',
                isDirectory: true,
              )
            : FolderFile(path: p, uri: 'content://test/$p'),
    ];

List<String> selected(String folderName, List<String> paths) =>
    selectRoamFiles(folderName, entries(paths)).map((f) => f.path).toList();

void main() {
  group('selectRoamFiles', () {
    test('with the org root chosen, takes only roam/, recursively', () {
      expect(
        selected('org', [
          'roam/',
          'roam/20240101120000-alpha.org',
          'roam/sub/',
          'roam/sub/20240102120000-beta.org',
          'journal/',
          'journal/2024-01-01.org',
          '.archive/',
          '.archive/old.org',
          'ref.org',
          'startpage.org',
        ]),
        ['roam/20240101120000-alpha.org', 'roam/sub/20240102120000-beta.org'],
      );
    });

    test('with the org root chosen and roam/ empty, takes nothing', () {
      expect(selected('org', ['roam/', 'ref.org', 'startpage.org']), isEmpty);
    });

    test('with roam/ itself chosen, takes all its org files', () {
      expect(
        selected('roam', ['20240101120000-alpha.org', 'sub/', 'sub/beta.org']),
        ['20240101120000-alpha.org', 'sub/beta.org'],
      );
    });

    test('with roam/ chosen, a nested roam/ does not change the root', () {
      expect(
        selected('roam', ['a.org', 'roam/', 'roam/b.org']),
        ['a.org', 'roam/b.org'],
      );
    });

    test('a folder without roam/ is taken as roam/ itself', () {
      expect(
        selected('notes', ['a.org', 'sub/', 'sub/b.org']),
        ['a.org', 'sub/b.org'],
      );
    });

    test('does not take a folder that only starts with "roam"', () {
      expect(
        selected('org', ['roam/', 'roam/a.org', 'roamer/', 'roamer/b.org']),
        ['roam/a.org'],
      );
    });

    test('never returns directories', () {
      expect(selected('roam', ['x.org/', 'a.org']), ['a.org']);
    });

    test('keeps the file details', () {
      const file = FolderFile(
        path: 'roam/a.org',
        uri: 'content://test/a',
        modified: 42,
        size: 7,
      );
      const roam = FolderFile(
        path: 'roam',
        uri: 'content://test/roam',
        isDirectory: true,
      );
      final result = selectRoamFiles('org', [roam, file]).single;
      expect(result.uri, 'content://test/a');
      expect(result.modified, 42);
      expect(result.size, 7);
    });

    test('an empty folder gives no files', () {
      expect(selected('org', []), isEmpty);
    });
  });

  group('isRoamFile', () {
    test('takes .org files', () {
      expect(isRoamFile('a.org'), isTrue);
      expect(isRoamFile('deep/er/a.org'), isTrue);
    });

    test('skips other file types', () {
      expect(isRoamFile('a.org_archive'), isFalse);
      expect(isRoamFile('a.txt'), isFalse);
      expect(isRoamFile('image.png'), isFalse);
      expect(isRoamFile('org'), isFalse);
    });

    test("skips Syncthing's folders and conflict copies", () {
      expect(isRoamFile('.stversions/a.org'), isFalse);
      expect(isRoamFile('sub/.stversions/a.org'), isFalse);
      expect(isRoamFile('.stfolder/a.org'), isFalse);
      expect(
        isRoamFile('a.sync-conflict-20241011-120000-ABCDEFG.org'),
        isFalse,
      );
    });

    test('skips editor leftovers', () {
      expect(isRoamFile('a.org~'), isFalse);
      expect(isRoamFile('.#a.org'), isFalse);
      expect(isRoamFile('#a.org#'), isFalse);
    });
  });
}
