import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/node_text.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

const fileNode =
    RoamNode(id: 'f', file: 'f.org', level: 0, title: 'F', line: 1);
const h1 = RoamNode(id: 'h1', file: 'f.org', level: 1, title: 'H1', line: 6);

const text = ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\n#+filetags: :x:\n\n'
    'Intro.\n\n'
    '* H1 :tag:\nSCHEDULED: <2026-10-17 Sat>\n:PROPERTIES:\n:ID: h1\n:END:\n'
    'Text of H1.\n** Sub\nMore.\n* Next\n';

void main() {
  test('a file node: the drawer and keywords are the head', () {
    final lines = NodeLines.find(text, fileNode)!;
    expect(lines.head, ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\n#+filetags: :x:');
    expect(lines.body, startsWith('\nIntro.\n'));
    expect(lines.withBody(lines.body), text);
  });

  test('a heading node: heading line, planning and drawer are the head; '
      'the subtree is the body', () {
    final lines = NodeLines.find(text, h1)!;
    expect(lines.head,
        '* H1 :tag:\nSCHEDULED: <2026-10-17 Sat>\n:PROPERTIES:\n:ID: h1\n:END:');
    expect(lines.body, 'Text of H1.\n** Sub\nMore.');
    expect(lines.withBody('New text.'),
        text.replaceFirst('Text of H1.\n** Sub\nMore.\n', 'New text.\n'));
  });

  test('keywords after blank lines still belong to the head', () {
    const t = ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\n\n#+filetags: :x:\nBody.\n';
    expect(NodeLines.find(t, fileNode)!.body, 'Body.\n');
  });

  test('a file without the node\'s drawer is not found', () {
    expect(NodeLines.find('Just text.\n', fileNode), isNull);
  });

  test('a file node with only a drawer: the rest is the body', () {
    final lines =
        NodeLines.find(':PROPERTIES:\n:ID: f\n:END:\nJust text.\n', fileNode)!;
    expect(lines.body, 'Just text.\n');
  });
}
