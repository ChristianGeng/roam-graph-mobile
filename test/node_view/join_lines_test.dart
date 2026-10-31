import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/edit/org_toggles.dart';
import 'package:roam_graph_mobile/node_view/join_lines.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import 'node_screen_test.dart' show graphOf, notes, open, orgText;
import 'note_search_test.dart' show count, search;

/// [text] as the node view shows it with the lines joined, written back
/// as Org text.
String joined(String text) => withJoinedLines(parseNote(text)).toMarkup();

/// Synthetic notes only (AGENTS.md). F: a paragraph filled at a short
/// width, as M-q leaves it, and one under a heading.
const fNote = ':PROPERTIES:\n:ID: f\n:END:\n#+title: F\n'
    'A paragraph that was filled\nin Emacs goes on here.\n'
    '* Later\nText under a heading,\nalso filled.\n';

final withF = {...notes, 'f.org': fNote};

void main() {
  group('the lines of a paragraph are joined (#219)', () {
    test('a filled paragraph is one line, with a space for each break', () {
      expect(joined('One line\nand the next,\n   indented.\n'),
          'One line and the next, indented.\n');
    });

    test('an empty line still starts a new paragraph', () {
      expect(joined('First\npart.\n\nSecond\npart.\n'),
          'First part.\n\nSecond part.\n');
    });

    test(r'a line ending with \\ keeps its line break', () {
      expect(joined('Break here\\\\\nnext line\nand on.\n'),
          'Break here\\\\\nnext line and on.\n');
      expect(joined('Break here \\\\  \nnext.\n'),
          'Break here \\\\  \nnext.\n');
    });

    test('a list item with two lines is one line, each item its own', () {
      expect(joined('- one first\n  one second\n- two\n'),
          '- one first one second\n- two\n');
      // A list inside an item stays on its own line.
      expect(joined('- one first\n  one second\n  - inner a\n    inner b\n'),
          '- one first one second\n  - inner a inner b\n');
    });

    test('blocks, tables, fixed-width lines and drawers keep their lines',
        () {
      const kept = '#+begin_src python\nx = 1\ny = 2\n#+end_src\n'
          '#+begin_verse\nverse one\nverse two\n#+end_verse\n'
          '#+begin_example\nex one\nex two\n#+end_example\n'
          '| a | b |\n| c | d |\n'
          ': fixed one\n: fixed two\n'
          ':NOTES:\ndrawer one\ndrawer two\n:END:\n'
          '#+caption: a\n#+name: b\n'
          '\\begin{equation}\nx\n= y\n\\end{equation}\n';
      expect(joined(kept), kept);
    });

    test('a quote block is joined, as in Org', () {
      expect(joined('#+begin_quote\nquote one\nquote two\n#+end_quote\n'),
          '#+begin_quote\nquote one quote two\n#+end_quote\n');
    });

    test('emphasis and links across a line break are joined', () {
      expect(
          joined('Some *bold\ntext* and [[https://example.com][a\nlink]]\n'
              'go on.\n'),
          'Some *bold text* and [[https://example.com][a link]] go on.\n');
    });

    test('headings and list items stay in place for the quick edits', () {
      const text = '* TODO One\nFilled\ntext.\n- [ ] a\n  b\n'
          '** Two\n- [X] c\n  d\n';
      final shown = withJoinedLines(parseNote(text));
      expect(sectionsOf(shown).length, sectionsOf(parseNote(text)).length);
      expect(listItemsOf(shown).length, 2);
      expect(listItemsOf(shown).last.checkbox, '[X]');
    });

    test('a note without filled lines is the same document', () {
      final document = parseNote('* One\nShort.\n');
      expect(identical(withJoinedLines(document), document), isTrue);
    });
  });

  group('in the node view (#219)', () {
    testWidgets('a filled paragraph shows joined', (tester) async {
      await open(tester, 'f', texts: withF, graph: ValueNotifier(graphOf(withF)));
      expect(orgText('was filled in Emacs goes on'), findsOneWidget);
      expect(orgText('Text under a heading, also filled.'), findsOneWidget);
    });

    testWidgets('with the setting off, the lines show as written',
        (tester) async {
      await open(tester, 'f',
          texts: withF, graph: ValueNotifier(graphOf(withF)), joinLines: false);
      expect(orgText('was filled in Emacs'), findsNothing);
      expect(orgText('was filled\nin Emacs'), findsOneWidget);
    });

    testWidgets('search finds a match across a joined line break',
        (tester) async {
      await open(tester, 'f',
          texts: withF,
          graph: ValueNotifier(graphOf(withF)),
          sections: SectionsOnOpen.collapsed);
      expect(orgText('also filled'), findsNothing);
      await search(tester, 'heading, also');
      // The folded section with the match opens.
      expect(count(tester), '1 match');
      expect(orgText('filled.'), findsOneWidget);
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(count(tester), '1 of 1');
    });
  });

  group('the stored setting (#219)', () {
    test('old saved settings get the default: joined', () {
      expect(ViewSettings.fromJson({'theme': 'dark'}).joinLines, isTrue);
      expect(ViewSettings.fromJson({'joinLines': 'no'}).joinLines, isTrue);
    });

    test('off is kept', () {
      final back = ViewSettings.fromJson(
          const ViewSettings(joinLines: false).toJson());
      expect(back.joinLines, isFalse);
      expect(back, const ViewSettings(joinLines: false));
    });
  });
}
