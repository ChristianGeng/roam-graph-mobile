import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

/// The rows of one category, as sorted JSON strings, so they compare as a
/// multiset.
List<String> rows(Object? list) => [
      for (final row in list! as List) jsonEncode(row),
    ]..sort();

void main() {
  // org_roam_expected.json is what real org-roam stored for the sample
  // files in test/fixtures/roam/; tool/org_roam_parity/ rebuilds it.
  test('the parser finds what org-roam finds in the sample files', () {
    const root = 'test/fixtures/roam';
    final files = <RoamFileData>[
      for (final entity in Directory(root).listSync(recursive: true))
        if (entity is File)
          if (entity.path.substring(root.length + 1) case final path
              when isRoamFile(path))
            parseRoamFile(path, entity.readAsStringSync()),
    ];
    final actual = RoamGraph.fromFiles(files).toNormalizedJson();
    final expected = jsonDecode(
      File('test/fixtures/org_roam_expected.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    for (final category in const [
      'files',
      'nodes',
      'links',
      'tags',
      'aliases',
      'refs',
      // Each link's file and line, so the check can point to it.
      'link_locations',
    ]) {
      expect(
        rows(actual[category]),
        rows(expected[category]),
        reason: 'The $category differ from org-roam.',
      );
    }
  });
}
