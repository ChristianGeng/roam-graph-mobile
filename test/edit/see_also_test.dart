import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/node_text.dart';
import 'package:roam_graph_mobile/edit/see_also.dart';

import '../ai/ai_visibility_test.dart' show graphOf;

NodeLines linesOf(String text, String id) {
  final node = graphOf({'n.org': text}).nodes[id]!;
  return NodeLines.find(text, node)!;
}

const head = ':PROPERTIES:\n:ID: n\n:END:\n#+title: N\n';

void main() {
  test('a new "See also:" line after the last line of text', () {
    expect(withSeeAlso(linesOf('${head}Text.\n\n', 'n'), 'b', '[[id:b][B]]'),
        '${head}Text.\nSee also: [[id:b][B]]\n\n');
  });

  test('an existing "See also:" line gets the link', () {
    expect(
        withSeeAlso(linesOf('${head}Text.\nSee also: [[id:c][C]]\n', 'n'),
            'b', '[[id:b][B]]'),
        '${head}Text.\nSee also: [[id:c][C]], [[id:b][B]]\n');
  });

  test('linked already: null', () {
    expect(
        withSeeAlso(linesOf('${head}See [[id:b][it]].\n', 'n'), 'b',
            '[[id:b][B]]'),
        isNull);
  });

  test('before a subheading that is a node of its own', () {
    const text = '${head}Text.\n* Child\n:PROPERTIES:\n:ID: c\n:END:\n'
        'Child text.\n';
    expect(
        withSeeAlso(linesOf(text, 'n'), 'b', '[[id:b][B]]'),
        '${head}Text.\nSee also: [[id:b][B]]\n* Child\n:PROPERTIES:\n:ID: c\n'
        ':END:\nChild text.\n');
  });
}
