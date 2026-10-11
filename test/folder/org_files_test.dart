import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';

List<FolderFile> files(List<String> paths) => [
      for (final p in paths) FolderFile(path: p, uri: 'content://test/$p'),
    ];

List<String> selected(List<String> paths) =>
    selectRoamFiles(files(paths)).map((f) => f.path).toList();

void main() {
  group('selectRoamFiles', () {
    test('with the org root chosen, takes only roam/, recursively', () {
      expect(
        selected([
          'roam/20240101120000-alpha.org',
          'roam/sub/20240102120000-beta.org',
          'journal/2024-01-01.org',
          '.archive/old.org',
          'ref.org',
          'startpage.org',
        ]),
        ['roam/20240101120000-alpha.org', 'roam/sub/20240102120000-beta.org'],
      );
    });

    test('with roam/ itself chosen, takes all its org files', () {
      expect(
        selected(['20240101120000-alpha.org', 'sub/beta.org']),
        ['20240101120000-alpha.org', 'sub/beta.org'],
      );
    });

    test('does not take a folder that only starts with "roam"', () {
      expect(selected(['roam/a.org', 'roamer/b.org']), ['roam/a.org']);
    });

    test('keeps the file details', () {
      const file = FolderFile(
        path: 'roam/a.org',
        uri: 'content://test/a',
        modified: 42,
        size: 7,
      );
      final result = selectRoamFiles([file]).single;
      expect(result.uri, 'content://test/a');
      expect(result.modified, 42);
      expect(result.size, 7);
    });

    test('an empty folder gives no files', () {
      expect(selected([]), isEmpty);
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
