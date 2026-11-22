import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/latex.dart';

/// The sample note with inline, display and broken formulas and an
/// `equation` environment (decision 14: synthetic).
final mu = File('test/fixtures/roam/20240112120000-mu.org').readAsStringSync();

List<T> nodesOf<T extends OrgNode>(OrgDocument document) {
  final found = <T>[];
  document.visit<T>((node) {
    found.add(node);
    return true;
  });
  return found;
}

void main() {
  test('display formulas become LaTeX blocks, inline ones stay', () {
    final document = withDisplayFormulas(OrgDocument.parse(mu));
    expect(
        [
          for (final block in nodesOf<OrgLatexBlock>(document))
            (block.begin, block.content.trim(), block.end),
        ],
        [
          (r'\[', r'\int_0^1 x^2 \, dx = \frac{1}{3}', r'\]'),
          (r'$$', r'\sum_{k=1}^{n} k = \frac{n(n+1)}{2}', r'$$'),
          (r'\begin{equation}', r'\nabla \cdot \mathbf{B} = 0',
              r'\end{equation}'),
        ]);
    expect(
        [
          for (final inline in nodesOf<OrgLatexInline>(document))
            inline.leadingDecoration,
        ],
        [r'\(', r'$', r'\(']);
  });

  test('a document without display formulas is left as it is', () {
    final document = OrgDocument.parse(r'Only \(x\) here.');
    expect(withDisplayFormulas(document), same(document));
  });
}
