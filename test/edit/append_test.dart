import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/append.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

const fileNode =
    RoamNode(id: 'f', file: 'f.org', level: 0, title: 'F', line: 1);
const h1 = RoamNode(id: 'h1', file: 'f.org', level: 1, title: 'H1', line: 6);
const h2 = RoamNode(id: 'h2', file: 'f.org', level: 2, title: 'H2', line: 10);

const text = ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\n\n'
    '* H1\n:PROPERTIES:\n:ID: h1\n:END:\nText of H1.\n'
    '** H2\n:PROPERTIES:\n:ID: h2\n:END:\nText of H2.\n\n'
    '* Next\nText of Next.\n';

void main() {
  test('a file node: at the end of the file', () {
    expect(appendToNode(text, fileNode, 'Added.'), '${text}Added.\n');
  });

  test('a heading node: at the end of its subtree, before the next heading',
      () {
    // H1's subtree holds H2, so the text goes after H2's text, and the
    // blank line before "* Next" stays where it is.
    expect(
        appendToNode(text, h1, 'Added.'),
        text.replaceFirst(
            'Text of H2.\n\n* Next', 'Text of H2.\nAdded.\n\n* Next'));
    expect(
        appendToNode(text, h2, 'Added.'),
        text.replaceFirst(
            'Text of H2.\n\n* Next', 'Text of H2.\nAdded.\n\n* Next'));
  });

  test('a heading that is only a heading and its drawer', () {
    const t = '* A\n:PROPERTIES:\n:ID: a\n:END:\n* B\n';
    const a = RoamNode(id: 'a', file: 'f.org', level: 1, title: 'A', line: 1);
    expect(appendToNode(t, a, 'x'),
        '* A\n:PROPERTIES:\n:ID: a\n:END:\nx\n* B\n');
  });

  test('several lines, trailing blank lines dropped, CRLF kept', () {
    const t = '#+title: F\r\nText.\r\n';
    expect(appendToNode(t, fileNode, 'one\ntwo\n\n'),
        '#+title: F\r\nText.\r\none\r\ntwo\r\n');
  });

  test('a file without a final newline gets one', () {
    expect(appendToNode('#+title: F\nText.', fileNode, 'x'),
        '#+title: F\nText.\nx\n');
  });

  test('a heading that is gone gives null', () {
    expect(appendToNode('#+title: F\n* Other\n', h1, 'x'), isNull);
  });

  test('an ID only as text, not after a heading, is no match', () {
    expect(appendToNode(':ID: h1\n#+title: F\n', h1, 'x'), isNull);
  });
}
