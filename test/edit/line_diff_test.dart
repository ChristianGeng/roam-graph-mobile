import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/line_diff.dart';

String show(List<DiffLine> lines) => lines.map((l) => '$l').join('\n');

/// [before] rebuilt from the diff's old side, [after] from its new side.
void expectConsistent(String before, String after) {
  final lines = diffLines(before, after);
  final old = [for (final l in lines) if (l.kind != DiffKind.added) l.text];
  final neu = [for (final l in lines) if (l.kind != DiffKind.removed) l.text];
  String join(List<String> l) => l.isEmpty ? '' : '${l.join('\n')}\n';
  expect(join(old), before);
  expect(join(neu), after);
}

void main() {
  test('added, removed and changed lines', () {
    expect(show(diffLines('a\nb\nc\n', 'a\nc\nd\n')), ' a\n-b\n c\n+d');
    expect(show(diffLines('a\nb\nc\n', 'a\nB\nc\n')), ' a\n-b\n+B\n c');
    expect(show(diffLines('', 'x\n')), '+x');
    expect(show(diffLines('x\n', '')), '-x');
    expect(diffLines('a\nb\n', 'a\nb\n').every((l) => l.kind == DiffKind.same),
        isTrue);
  });

  test('line numbers on both sides', () {
    final lines = diffLines('a\nb\nc\n', 'a\nX\nc\n');
    expect([for (final l in lines) (l.oldLine, l.newLine)],
        [(1, 1), (2, null), (null, 2), (3, 3)]);
  });

  test('the shortest script: a moved block is one removal and one addition',
      () {
    final lines = diffLines('a\nb\nc\nd\n', 'b\nc\nd\na\n');
    expect(lines.where((l) => l.kind != DiffKind.same).length, 2);
  });

  test('hunks with three lines of context, merged when close', () {
    final before = [for (var i = 1; i <= 20; i++) 'line $i'].join('\n');
    final after = before
        .replaceFirst('line 2\n', 'line two\n')
        .replaceFirst('line 15\n', 'line fifteen\n');
    final hunks = diffHunks('$before\n', '$after\n');
    expect(hunks, hasLength(2));
    expect(hunks.first.oldStart, 1);
    expect(show(hunks.first.lines),
        ' line 1\n-line 2\n+line two\n line 3\n line 4\n line 5');
    expect(hunks.last.oldStart, 12);
    // Changes 5 lines apart share one hunk.
    final near = before
        .replaceFirst('line 2\n', 'X\n')
        .replaceFirst('line 7\n', 'Y\n');
    expect(diffHunks('$before\n', '$near\n'), hasLength(1));
    expect(diffHunks('a\n', 'a\n'), isEmpty);
  });

  test('random edits: both texts are rebuilt from the diff', () {
    final random = Random(7);
    for (var round = 0; round < 200; round++) {
      final a = [
        for (var i = 0; i < random.nextInt(30); i++) 'l${random.nextInt(6)}'
      ];
      final b = List.of(a);
      for (var e = 0; e < random.nextInt(8); e++) {
        final op = random.nextInt(3);
        if (op == 0 || b.isEmpty) {
          b.insert(random.nextInt(b.length + 1), 'n${random.nextInt(6)}');
        } else if (op == 1) {
          b.removeAt(random.nextInt(b.length));
        } else {
          b[random.nextInt(b.length)] = 'c${random.nextInt(6)}';
        }
      }
      String join(List<String> l) => l.isEmpty ? '' : '${l.join('\n')}\n';
      expectConsistent(join(a), join(b));
    }
  });
}
