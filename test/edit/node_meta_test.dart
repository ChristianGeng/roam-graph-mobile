import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/node_meta.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

import 'note_editor_test.dart' show MemoryNoteStore;

const fileNode = RoamNode(id: 'f', file: 'f.org', level: 0, title: 'F', line: 1);
const heading = RoamNode(id: 'h', file: 'f.org', level: 1, title: 'H', line: 6);

const text = ':PROPERTIES:\n:ID: f\n:ROAM_ALIASES: Eff "F one"\n:END:\n'
    '#+title: F\n#+filetags: :a:b:\nIntro.\n'
    '* TODO [#A] Heading H :x:\n:PROPERTIES:\n:ID: h\n:END:\nText.\n';

void main() {
  test('reads a file node and a heading node', () {
    final f = readMeta(text, fileNode)!;
    expect(f.title, 'F');
    expect(f.tags, ['a', 'b']);
    expect(f.aliases, ['Eff', 'F one']);
    final h = readMeta(text, heading)!;
    expect(h.title, 'Heading H');
    expect(h.tags, ['x']);
    expect(h.aliases, isEmpty);
  });

  test('a file node: only the title, filetags and aliases lines change', () {
    final after = withMeta(text, fileNode,
        const NodeMeta(title: 'New', tags: ['c'], aliases: ['Say "hi"', 'x']));
    expect(after,
        text
            .replaceFirst(':ROAM_ALIASES: Eff "F one"',
                r':ROAM_ALIASES: "Say \"hi\"" x')
            .replaceFirst('#+title: F', '#+title: New')
            .replaceFirst('#+filetags: :a:b:', '#+filetags: :c:'));
    // What the index reads back.
    final node = parseRoamFile('f.org', after).nodes.first;
    expect(node.title, 'New');
    expect(node.aliases, ['Say "hi"', 'x']);
  });

  test('tags and aliases can be removed, and added where none were', () {
    final none = withMeta(text, fileNode, const NodeMeta(title: 'F'));
    expect(none, isNot(contains('#+filetags')));
    expect(none, isNot(contains('ROAM_ALIASES')));
    final back = withMeta(none, fileNode,
        const NodeMeta(title: 'F', tags: ['a', 'b'], aliases: ['Eff', 'F one']));
    expect(back, text);
  });

  test('a heading keeps its TODO keyword and priority', () {
    final after = withMeta(text, heading,
        const NodeMeta(title: 'Renamed', tags: ['y', 'z'], aliases: ['Aitch']));
    expect(after, contains('* TODO [#A] Renamed :y:z:\n'));
    expect(after, contains(':ID: h\n:ROAM_ALIASES: Aitch\n:END:'));
    expect(after, startsWith(text.substring(0, text.indexOf('* TODO'))));
  });

  test('bad tags and a title with a line break are refused', () {
    expect(() => withMeta(text, fileNode, const NodeMeta(title: 'A\nB')),
        throwsA(isA<MetaError>()));
    expect(
        () => withMeta(text, fileNode,
            const NodeMeta(title: 'F', tags: ['two words'])),
        throwsA(isA<MetaError>()));
    expect(() => withMeta(text, heading, const NodeMeta(title: ' ')),
        throwsA(isA<MetaError>()));
  });

  test('the save allows the aliases line of a drawer to change, no other',
      () async {
    final store = MemoryNoteStore({'f.org': text});
    final editor = NoteEditor(store: store, history: MemoryEditHistory());
    final base = (await editor.read('f.org'))!;
    final aliases = withMeta(text, fileNode,
        const NodeMeta(title: 'F', tags: ['a', 'b'], aliases: ['Other']));
    expect(await editor.save('f.org', base, aliases), isA<LockedPartChanged>());
    expect(await editor.save('f.org', base, aliases, aliasesMayChange: true),
        isA<Saved>());
    final now = (await editor.read('f.org'))!;
    expect(
        await editor.save('f.org', now,
            now.text.replaceFirst(':ID: f', ':ID: g'),
            aliasesMayChange: true),
        isA<LockedPartChanged>());
  });

  test('aliases are quoted as org-roam-alias-add writes them', () {
    expect(quoteAliases(['plain', 'two words', r'back\slash', 'q"uote']),
        r'plain "two words" "back\\slash" "q\"uote"');
  });
}
