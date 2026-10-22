import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart' show defaultTodoStates;
import 'package:roam_graph_mobile/edit/org_toggles.dart';
import 'package:roam_graph_mobile/edit/structure_edits.dart';

import '../widget_test.dart';
import 'add_link_test.dart' show openNode;

/// [marked] without its `|` marks, and where they were: one mark is the
/// cursor, two are a selection.
(String, int, int) _marks(String marked) {
  final first = marked.indexOf('|');
  final second = marked.indexOf('|', first + 1);
  final text = marked.replaceAll('|', '');
  return (text, first, second < 0 ? first : second - 1);
}

/// [action] on [marked] (see [_marks]); synthetic text only (AGENTS.md).
StructureResult run(StructureAction action, String marked,
    {int topLevel = 1, String? keywords}) {
  final (text, start, end) = _marks(marked);
  return applyStructureAction(action, text,
      start: start,
      end: end,
      topLevel: topLevel,
      todoStates: keywords == null
          ? [defaultTodoStates]
          : todoStatesOf(parseNote(keywords)));
}

/// The text after [action], with `|` at the cursor, or around the
/// selection.
String after(StructureAction action, String marked,
    {int topLevel = 1, String? keywords}) {
  final result =
      run(action, marked, topLevel: topLevel, keywords: keywords);
  if (result is StructureRefused) fail('refused: ${result.reason}');
  final changed = result as StructureChanged;
  final text = changed.text;
  if (changed.start == changed.end) {
    return '${text.substring(0, changed.start)}|${text.substring(changed.start)}';
  }
  return '${text.substring(0, changed.start)}|'
      '${text.substring(changed.start, changed.end)}|'
      '${text.substring(changed.end)}';
}

String refused(StructureAction action, String marked, {int topLevel = 1}) {
  final result = run(action, marked, topLevel: topLevel);
  if (result is! StructureRefused) {
    fail('changed to: ${(result as StructureChanged).text}');
  }
  return result.reason;
}

const drawerA = '* a\n:PROPERTIES:\n:ID: 1\n:END:\n';

void main() {
  group('new heading', () {
    test('after the subtree, at the level of the heading above', () {
      expect(after(StructureAction.newHeading, '* a\nTe|xt\n** a1\n\n* b\n'),
          '* a\nText\n** a1\n* |\n\n* b\n');
      expect(after(StructureAction.newHeading, '* a\n** a|1\nx\n* b\n'),
          '* a\n** a1\nx\n** |\n* b\n');
    });

    test('without a heading above: at the highest level the text may have',
        () {
      expect(after(StructureAction.newHeading, '|Intro\n* b\n'),
          'Intro\n* |\n* b\n');
      // In a heading node at level 2, its sub-headings start at level 3.
      expect(after(StructureAction.newHeading, 'Intro|\n', topLevel: 3),
          'Intro\n*** |\n');
    });

    test('at the first and the last line, and in an empty text', () {
      expect(after(StructureAction.newHeading, '|'), '* |');
      expect(after(StructureAction.newHeading, '* a\nlast|'),
          '* a\nlast\n* |');
      expect(after(StructureAction.newHeading, '|* a\n'), '* a\n* |\n');
    });

    test('with a selection: after the subtree of the selection\'s end', () {
      expect(after(StructureAction.newHeading, '* |a\n* b|\nB\n'),
          '* a\n* b\nB\n* |\n');
    });
  });

  group('promote and demote', () {
    test('a heading goes with its subtree', () {
      expect(after(StructureAction.demote, '* |a\n** b\ntext\n* c\n'),
          '** |a\n*** b\ntext\n* c\n');
      expect(after(StructureAction.promote, '** |a\n*** b\ntext\n* c\n'),
          '* |a\n** b\ntext\n* c\n');
    });

    test('level 1 cannot go up, nor out of a heading node', () {
      expect(refused(StructureAction.promote, '* |a\n'),
          'A heading at level 1 cannot go up a level.');
      expect(refused(StructureAction.promote, '** |a\n', topLevel: 2),
          contains('no longer be part of the note'));
      expect(after(StructureAction.demote, '** |a\n', topLevel: 2),
          '*** |a\n');
    });

    test('a selection: every heading in it, each line once', () {
      expect(after(StructureAction.demote, '|* a\n* b|\n* c\n'),
          '|** a\n** b|\n* c\n');
      expect(after(StructureAction.demote, '|* a\n** a1\n|* b\n'),
          '|** a\n*** a1\n|* b\n');
    });

    test('a list item goes with its children, below the item above', () {
      expect(after(StructureAction.demote, '- a\n- |b\n  - c\n- d\n'),
          '- a\n  - |b\n    - c\n- d\n');
      expect(after(StructureAction.promote, '- a\n  - |b\n    - c\n- d\n'),
          '- a\n- |b\n  - c\n- d\n');
      expect(after(StructureAction.demote, '1. a\n2. |b\n'),
          '1. a\n   2. |b\n');
      // The cursor on a later line of the item.
      expect(after(StructureAction.demote, '- a\n- b\n  more| text\n'),
          '- a\n  - b\n    more| text\n');
    });

    test('the first item cannot go down, a top item not up', () {
      expect(refused(StructureAction.demote, '- |a\n- b\n'),
          contains('first item of a list'));
      expect(refused(StructureAction.promote, '- a\n- |b\n'),
          contains('top level of its list'));
    });

    test('elsewhere nothing changes', () {
      expect(refused(StructureAction.demote, '* a\nplain |text\n'),
          'Put the cursor on a heading or in a list item.');
    });

    test('a heading above a property drawer keeps its level', () {
      expect(refused(StructureAction.demote, '|$drawerA'),
          contains('property drawer'));
      // Also as part of a subtree.
      expect(
          refused(StructureAction.demote,
              '* |b\n** a\n:PROPERTIES:\n:ID: 1\n:END:\n'),
          contains('property drawer'));
    });
  });

  group('move up and down', () {
    test('a heading with its subtree past its sibling', () {
      expect(after(StructureAction.moveUp, '* a\nA\n\n* |b\nB\n* c\n'),
          '* |b\nB\n\n* a\nA\n* c\n');
      expect(after(StructureAction.moveDown, '* a\nA\n\n* |b\nB\n* c\n'),
          '* a\nA\n\n* c\n* |b\nB\n');
      expect(after(StructureAction.moveUp, '* a\n** a1\n* |b\n'),
          '* |b\n* a\n** a1\n');
    });

    test('at the ends, and not out of its parent', () {
      expect(refused(StructureAction.moveUp, '* |a\n* b\n'),
          'This heading is the first at its level here.');
      expect(refused(StructureAction.moveDown, '* a\n* |b\n'),
          'This heading is the last at its level here.');
      expect(refused(StructureAction.moveUp, '* a\n** x\n* b\n** |y\n'),
          'This heading is the first at its level here.');
    });

    test('a list item with its children past its sibling', () {
      expect(after(StructureAction.moveUp, '- a\n  - a1\n- |b\n'),
          '- |b\n- a\n  - a1\n');
      expect(after(StructureAction.moveDown, '- |a\n  - a1\n- b\n'),
          '- b\n- |a\n  - a1\n');
      expect(refused(StructureAction.moveDown, '- a\n- |b\n'),
          'This item is the last of its list.');
      expect(refused(StructureAction.moveUp, '- a\n  - |a1\n- b\n'),
          'This item is the first of its list.');
    });

    test('a drawer may move with its heading, but not past another drawer',
        () {
      expect(
          after(StructureAction.moveUp,
              '* x\n* |b\n:PROPERTIES:\n:ID: 2\n:END:\n'),
          '* |b\n:PROPERTIES:\n:ID: 2\n:END:\n* x\n');
      expect(
          refused(StructureAction.moveUp,
              '$drawerA* |b\n:PROPERTIES:\n:ID: 2\n:END:\n'),
          contains('property drawer'));
    });

    test('#+title: and #+filetags: lines keep their order', () {
      expect(
          refused(StructureAction.moveUp,
              '* a\n#+title: T\n* |b\n#+filetags: :x:\n'),
          contains('#+title:'));
    });

    test('Windows line ends stay', () {
      final (text, start, _) = _marks('* a\r\n|* b\r\n');
      final result = applyStructureAction(StructureAction.moveUp, text,
          start: start, end: start, todoStates: [defaultTodoStates]);
      expect((result as StructureChanged).text, '* b\r\n* a\r\n');
      expect(result.start, 0);
    });
  });

  test('mixed line ends stay where they are', () {
    final (text, start, _) = _marks('* a\n* b\r\n|* c\n');
    final result = applyStructureAction(StructureAction.moveUp, text,
        start: start, end: start, todoStates: [defaultTodoStates]);
    expect((result as StructureChanged).text, '* a\n* c\r\n* b\n');
    expect(result.start, 4);
    final (text2, start2, _) = _marks('* a\r\nx|\n* b\n');
    final inserted = applyStructureAction(StructureAction.newItem, text2,
        start: start2, end: start2, todoStates: [defaultTodoStates]);
    expect((inserted as StructureChanged).text, '* a\r\nx\n- \n* b\n');
    expect(inserted.start, 9);
  });

  group('list items and checkboxes', () {
    test('a new item after the current one, with its bullet', () {
      expect(after(StructureAction.newItem, '- |a\n- b\n'), '- a\n- |\n- b\n');
      expect(after(StructureAction.newItem, '+ a|\n'), '+ a\n+ |\n');
      expect(after(StructureAction.newItem, '- a|\n  - c\n- b\n'),
          '- a\n  - c\n- |\n- b\n');
      expect(after(StructureAction.newItem, '- [X] a|\n'),
          '- [X] a\n- [ ] |\n');
    });

    test('numbered items are numbered on', () {
      expect(after(StructureAction.newItem, '1. a|\n2. b\n'),
          '1. a\n2. |\n3. b\n');
      expect(after(StructureAction.newItem, '1) a|\n'), '1) a\n2) |\n');
    });

    test('outside a list a new list starts', () {
      expect(after(StructureAction.newItem, 'Text\n|'), 'Text\n- |');
      expect(after(StructureAction.newItem, 'Te|xt\nmore\n'),
          'Text\n- |\nmore\n');
      expect(refused(StructureAction.newItem, '* |a\n'),
          contains('below a heading'));
    });

    test('a checkbox on and off', () {
      expect(after(StructureAction.checkbox, '- a|\n'), '- [ ] a|\n');
      expect(after(StructureAction.checkbox, '- [ ] a|\n'), '- a|\n');
      expect(after(StructureAction.checkbox, '1. [X] done|\n'), '1. done|\n');
      expect(after(StructureAction.checkbox, '- |\n'), '- [ ] |\n');
      expect(refused(StructureAction.checkbox, 'pla|in\n'),
          'Put the cursor in a list item.');
    });

    test('a selection: all items as the first one', () {
      expect(after(StructureAction.checkbox, '|- a\n- [ ] b|\n'),
          '|- [ ] a\n- [ ] b|\n');
      expect(after(StructureAction.checkbox, '|- [X] a\n- b|\n'),
          '|- a\n- b|\n');
    });
  });

  group('TODO states', () {
    test('cycled as org-todo does, with the default keywords', () {
      expect(after(StructureAction.todo, '* |a\n'), '* |TODO a\n');
      expect(after(StructureAction.todo, '* TODO a|\n'), '* DONE a|\n');
      expect(after(StructureAction.todo, '* DONE a|\n'), '* a|\n');
      // A selection: each heading to its own next state.
      expect(after(StructureAction.todo, '|* a\n* TODO b\ntext|\n'),
          '|* TODO a\n* DONE b\ntext|\n');
      // From a line below the heading.
      expect(after(StructureAction.todo, '** b\nbo|dy\n'),
          '** TODO b\nbo|dy\n');
    });

    test('with the note\'s #+TODO: keywords', () {
      const keywords = '#+TODO: TODO NEXT | DONE CANCELLED\n';
      expect(after(StructureAction.todo, '* NEXT |b\n', keywords: keywords),
          '* DONE |b\n');
      expect(
          after(StructureAction.todo, '* CANCELLED b|\n', keywords: keywords),
          '* b|\n');
    });

    test('a heading above a drawer may change its state; no heading: nothing',
        () {
      expect(after(StructureAction.todo, '|$drawerA'),
          '|* TODO a\n:PROPERTIES:\n:ID: 1\n:END:\n');
      expect(refused(StructureAction.todo, 'te|xt\n'),
          'There is no heading at or above the cursor.');
      expect(refused(StructureAction.todo, 'te|xt\n', topLevel: 2),
          contains('note view'));
    });
  });

  test('without a cursor nothing changes', () {
    final result = applyStructureAction(StructureAction.newHeading, '* a\n',
        start: -1, end: -1, todoStates: [defaultTodoStates]);
    expect((result as StructureRefused).reason, contains('Tap in the text'));
  });

  group('the buttons in "Edit text" (#151)', () {
    Future<TextEditingController> openEditor(
        WidgetTester tester, FakeFolderAccess access) async {
      await openNode(tester, access, 'b');
      await tester.tap(find.byTooltip('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit text'));
      await tester.pumpAndSettle();
      return tester
          .widget<TextField>(find.byKey(const ValueKey('edit-text')))
          .controller!;
    }

    testWidgets('a TODO state is set and saved with the diff', (tester) async {
      final access = withNotes(saved: writableOrg);
      final before = access.texts['roam/b.org']!;
      final text = await openEditor(tester, access);
      // b.org's text: a heading with its own drawer.
      expect(text.text, '* Heading\n:PROPERTIES:\n:ID: h\n:END:\n');
      text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await tester.tap(find.byTooltip('Next TODO state'));
      await tester.pump();
      expect(text.text, '* TODO Heading\n:PROPERTIES:\n:ID: h\n:END:\n');
      expect(access.replaced, isEmpty);

      await tester.tap(find.byTooltip('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(access.texts['roam/b.org'],
          before.replaceFirst('* Heading', '* TODO Heading'));
    });

    testWidgets('a button that would change a drawer says why',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      final text = await openEditor(tester, access);
      text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await tester.tap(find.byTooltip('Down a level (demote)'));
      await tester.pump();
      expect(text.text, '* Heading\n:PROPERTIES:\n:ID: h\n:END:\n');
      expect(find.textContaining('would change a property drawer'),
          findsOneWidget);
    });

    testWidgets('a new heading in the text', (tester) async {
      final access = withNotes(saved: writableOrg);
      final text = await openEditor(tester, access);
      text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await tester.tap(find.byTooltip('New heading'));
      await tester.pump();
      expect(text.text, '* Heading\n:PROPERTIES:\n:ID: h\n:END:\n* \n');
      expect(text.selection, const TextSelection.collapsed(offset: 38));
    });
  });
}
