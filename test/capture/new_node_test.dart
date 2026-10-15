import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/capture/new_node.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';

void main() {
  // What Emacs's org-roam-node-slugify returns for each title;
  // tool/org_roam_parity/slugs.el writes it.
  final slugs = (jsonDecode(
          File('test/fixtures/org_roam_slugs.json').readAsStringSync())
      as Map<String, dynamic>);

  test('slugs as org-roam-node-slugify', () {
    expect(slugs, hasLength(greaterThan(20)));
    for (final MapEntry(key: title, value: slug) in slugs.entries) {
      expect(slugify(title), slug, reason: title);
    }
  });

  test('file names as the default capture template', () {
    expect(nodeFileName(DateTime(2025, 5, 1, 16, 59, 38), 'Attention'),
        '20250501165938-attention.org');
    expect(nodeFileName(DateTime(2026, 1, 2, 3, 4, 5), 'Crème brûlée'),
        '20260102030405-creme_brulee.org');
  });

  test('IDs as org-id-new with uuidgen', () {
    final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    final ids = {for (var i = 0; i < 100; i++) newOrgId()};
    expect(ids, hasLength(100));
    for (final id in ids) {
      expect(id, matches(pattern));
    }
    expect(newOrgId(Random(1)), newOrgId(Random(1)));
  });

  test('tags', () {
    expect(parseTags(' org, roam :emacs: '), ['org', 'roam', 'emacs']);
    expect(parseTags(''), isEmpty);
  });

  test('the file is a node org-roam reads as written', () {
    const id = '0f6b1b3e-2c4d-4e5f-8a9b-0c1d2e3f4a5b';
    final text = nodeFileText(
      id: id,
      title: 'Crème\nbrûlée',
      tags: ['food', 'french'],
      body: 'Some text.\n\n',
    );
    expect(
        text,
        ':PROPERTIES:\n:ID:       $id\n:END:\n#+title: Crème brûlée\n'
        '#+filetags: :food:french:\n\nSome text.\n');
    // The app's parser, which matches org-roam (#4), finds the node.
    final parsed = parseRoamFile('x.org', text);
    expect(parsed.nodes.single.id, id);
    expect(parsed.nodes.single.title, 'Crème brûlée');
    expect(parsed.nodes.single.tags, ['food', 'french']);
  });

  test('without tags or text, just the title', () {
    expect(nodeFileText(id: 'i', title: 'T'),
        ':PROPERTIES:\n:ID:       i\n:END:\n#+title: T\n');
  });
}
