import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/indexer.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_db.dart';

/// The rows of one table, as sorted JSON strings, so they compare as a
/// multiset.
List<String> rows(Object? list) => [
      for (final row in list! as List) jsonEncode(row),
    ]..sort();

void main() {
  // org_roam_expected_tables.json is every table real org-roam built from
  // the sample files in test/fixtures/roam/, with paths starting "{roam}/";
  // tool/org_roam_parity/ rebuilds it.
  test("the database matches org-roam's, every table and column", () {
    const root = 'test/fixtures/roam';
    final db = RoamDatabase.inMemory(root: '{roam}');
    final listing = <String, int>{};
    final contents = <String, Uint8List?>{};
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path.substring(root.length + 1);
      if (!isRoamFile(path)) continue;
      listing[path] = 0;
      contents[path] = entity.readAsBytesSync();
    }
    // The expected database was built by a plain Emacs.
    updateIndex(db, listing, contents, linkTypes: plainOrgRoamLinkTypes);
    final actual = db.dumpTables();
    final expected = jsonDecode(
      File('test/fixtures/org_roam_expected_tables.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    expect(db.userVersion, 20);
    for (final table in roamTables) {
      final expectedTable = expected[table] as Map<String, dynamic>;
      // The export leaves out atime and mtime.
      expect(
        [
          for (final c in db.columns(table))
            if (table != 'files' || (c != 'atime' && c != 'mtime')) c,
        ],
        expectedTable['columns'],
        reason: 'The $table table has other columns than org-roam.',
      );
      expect(
        rows(actual[table]),
        rows(expectedTable['rows']),
        reason: 'The $table table differs from org-roam.',
      );
    }
    db.close();
  });
}
