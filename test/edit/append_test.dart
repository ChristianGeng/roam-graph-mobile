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
    const t = ':PROPERTIES:\r\n:ID: f\r\n:END:\r\n#+title: F\r\nText.\r\n';
    expect(appendToNode(t, fileNode, 'one\ntwo  \n\n'),
        '${t}one\r\ntwo  \r\n');
  });

  test('a file without a final newline gets one', () {
    const t = ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\nText.';
    expect(appendToNode(t, fileNode, 'x'), '$t\nx\n');
  });

  test('comment lines may come before the file drawer', () {
    const t = '# A comment\n:PROPERTIES:\n:ID: f\n:END:\nText.\n';
    expect(appendToNode(t, fileNode, 'x'), '${t}x\n');
  });

  test("a file whose drawer no longer holds the node's ID gives null", () {
    expect(
        appendToNode(':PROPERTIES:\n:ID: other\n:END:\nText.\n', fileNode,
            'x'),
        isNull);
    expect(appendToNode('#+title: F\nText.\n', fileNode, 'x'), isNull);
  });

  test('an :ID: line in the text of an earlier heading is no match', () {
    const t = '* Notes\n:ID: h1\n* Target\n:PROPERTIES:\n:ID: h1\n:END:\n'
        'Its text.\n* After\n';
    expect(appendToNode(t, h1, 'x'),
        t.replaceFirst('Its text.\n', 'Its text.\nx\n'));
  });

  test('the drawer may follow a planning line', () {
    const t = '* A\nSCHEDULED: <2026-10-17 Sat>\n:PROPERTIES:\n:ID: h1\n'
        ':END:\n* B\n';
    expect(appendToNode(t, h1, 'x'), t.replaceFirst('* B', 'x\n* B'));
  });

  test('IDs that differ only in case are different nodes', () {
    const t = '* Upper\n:PROPERTIES:\n:ID: Task\n:END:\nU.\n'
        '* Lower\n:PROPERTIES:\n:id: task\n:END:\nL.\n';
    const lower =
        RoamNode(id: 'task', file: 'f.org', level: 1, title: 'Lower', line: 6);
    expect(appendToNode(t, lower, 'x'), '${t}x\n');
  });

  test('a heading that is gone gives null', () {
    expect(appendToNode('#+title: F\n* Other\n', h1, 'x'), isNull);
  });

  test('an ID only as text, not after a heading, is no match', () {
    expect(appendToNode(':ID: h1\n#+title: F\n', h1, 'x'), isNull);
  });
}
