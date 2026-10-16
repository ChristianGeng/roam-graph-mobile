import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_notes.dart';

void main() {
  const old = '# Changelog\n\nIntro.\n\n'
      '## 2026-10-15: B (#2)\n\n- Added: b.\n\n'
      '## 2026-10-14: A (#1)\n\n- Added: a.\n';
  const now = '# Changelog\n\nIntro.\n\n'
      '## 2026-10-16: D (#4)\n\n- Fixed: d.\n\n'
      '## 2026-10-16: C (#3)\n\n- Added: c.\n  More on c.\n\n'
      '## 2026-10-15: B (#2)\n\n- Added: b.\n\n'
      '## 2026-10-14: A (#1)\n\n- Added: a.\n';

  test('the entries added since the previous release, newest first', () {
    expect(
      releaseNotes(old, now, 'abc'),
      '## 2026-10-16: D (#4)\n\n- Fixed: d.\n\n'
      '## 2026-10-16: C (#3)\n\n- Added: c.\n  More on c.\n\n'
      'Built from abc.\n',
    );
  });

  test('only the top entry when the previous release had no changelog', () {
    expect(releaseNotes(null, now, 'abc'),
        '## 2026-10-16: D (#4)\n\n- Fixed: d.\n\nBuilt from abc.\n');
  });

  test('the top entry when nothing is new, as for a release built again', () {
    expect(releaseNotes(now, now, 'abc'),
        '## 2026-10-16: D (#4)\n\n- Fixed: d.\n\nBuilt from abc.\n');
  });

  test('only the sha when the changelog has no entry', () {
    expect(releaseNotes(null, '# Changelog\n', 'abc'), 'Built from abc.\n');
  });

  test("the repository's changelog has entries with a date, title and PR", () {
    final text = File('CHANGELOG.md').readAsStringSync();
    final headings =
        text.split('\n').where((line) => line.startsWith('## ')).toList();
    expect(headings, isNotEmpty);
    final heading = RegExp(r'^## \d{4}-\d{2}-\d{2}: .+ \(\[#\d+\]\(https://'
        r'github\.com/ChristianGeng/roam-graph-mobile/pull/\d+\)\)$');
    for (final line in headings) {
      expect(line, matches(heading));
    }
  });
}
