import 'package:flutter_test/flutter_test.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/edit/org_toggles.dart';
import 'package:roam_graph_mobile/edit/unlink.dart';

/// The lines of [after] that differ from [before], by number; both must
/// have the same number of lines.
Map<int, String> changedLines(String before, String after) {
  final a = before.split('\n'), b = after.split('\n');
  expect(b, hasLength(a.length));
  return {
    for (var i = 0; i < a.length; i++)
      if (a[i] != b[i]) i: b[i],
  };
}

/// Synthetic notes only (AGENTS.md).
const busy = ':PROPERTIES:\n:ID: 0e1f\n:ROAM_ALIASES: "Some note"\n:END:\n'
    '#+title: A busy note\n#+filetags: :test:\n\n'
    'Text with *bold*, /italic/ and a [[id:other][link]].   \n'
    '\n'
    '| a  | b |\n|----+---|\n| 1 |  2 |\n\n'
    '#+begin_src python\n  print("x")   \n#+end_src\n\n'
    '* Tasks [1/3]\n:PROPERTIES:\n:ID: 9a8b\n:END:\n'
    '- [X] first\n- [ ] second   \n- [ ] third\n\n'
    '  Some text after the list.\n'
    '** A heading\twith a tab :tag:\n'
    '+ plain item\n'
    '1. [ ] numbered\n';

void main() {
  group('checkboxes (#150)', () {
    test('a box is ticked and unticked', () {
      const text = '#+title: T\n- [ ] one\n- [X] two\n';
      final ticked = toggleCheckbox(text, 0);
      expect(ticked, '#+title: T\n- [X] one\n- [X] two\n');
      expect(toggleCheckbox(ticked, 0), text);
      expect(toggleCheckbox(text, 1), '#+title: T\n- [ ] one\n- [ ] two\n');
    });

    test('the message names the item', () {
      String? said;
      toggleCheckbox('- [ ] buy bread\n', 0, describe: (d) => said = d);
      expect(said, 'Ticked "buy bread".');
    });

    test('[-] becomes [X], with its sub-items', () {
      const text = '- [-] parent\n  - [X] a\n  - [ ] b\n';
      expect(toggleCheckbox(text, 0), '- [X] parent\n  - [X] a\n  - [X] b\n');
    });

    test('the box above follows its sub-items', () {
      const text = '- [-] parent\n  - [X] a\n  - [ ] b\n';
      expect(toggleCheckbox(text, 2), '- [X] parent\n  - [X] a\n  - [X] b\n');
      expect(toggleCheckbox(text, 1), '- [ ] parent\n  - [ ] a\n  - [ ] b\n');
    });

    test("a heading's [n/m] cookie is brought up to date", () {
      const text = '* Tasks [1/3]\n- [X] a\n- [ ] b\n- [ ] c\n';
      expect(toggleCheckbox(text, 1),
          '* Tasks [2/3]\n- [X] a\n- [X] b\n- [ ] c\n');
    });

    test("an item's [%] cookie is brought up to date", () {
      const text = '- [ ] parent [0%]\n  - [ ] a\n  - [ ] b\n';
      expect(toggleCheckbox(text, 1),
          '- [-] parent [50%]\n  - [X] a\n  - [ ] b\n');
    });

    test('the rest of the file stays byte for byte', () {
      final items = listItemsOf(parseNote(busy));
      final second =
          items.indexWhere((i) => i.body!.toMarkup().contains('second'));
      final after = toggleCheckbox(busy, second);
      final changed = changedLines(busy, after);
      expect(changed.values, ['* Tasks [2/3]', '- [X] second   ']);
      final numbered =
          items.indexWhere((i) => i.body!.toMarkup().contains('numbered'));
      expect(changedLines(busy, toggleCheckbox(busy, numbered)).values,
          ['1. [X] numbered']);
    });

    test('an item without a box, or a number past the end, is refused', () {
      expect(() => toggleCheckbox('- plain\n', 0),
          throwsA(isA<NoteChangeError>()));
      expect(() => toggleCheckbox('- [ ] a\n', 3),
          throwsA(isA<NoteChangeError>()));
    });
  });

  group('TODO states (#150)', () {
    final now = DateTime(2026, 10, 22, 9, 45);

    test("cycling with Org's default keywords", () {
      final states = todoStatesOf(parseNote('* Task\n'));
      expect(allKeywords(states), ['TODO', 'DONE']);
      expect(nextKeyword(states, null), 'TODO');
      expect(nextKeyword(states, 'TODO'), 'DONE');
      expect(nextKeyword(states, 'DONE'), isNull);
      final todo = setTodo('* Task\n', 0, 'TODO', now: now);
      expect(todo, '* TODO Task\n');
      final done = setTodo(todo, 0, 'DONE', now: now);
      expect(done, '* DONE Task\n');
      expect(setTodo(done, 0, null, now: now), '* Task\n');
    });

    test("cycling with the file's #+TODO: keywords", () {
      const text = '#+TODO: TODO NEXT | DONE CANCELLED\n* NEXT Task :x:\n';
      final states = todoStatesOf(parseNote(text));
      expect(allKeywords(states), ['TODO', 'NEXT', 'DONE', 'CANCELLED']);
      expect(nextKeyword(states, 'NEXT'), 'DONE');
      expect(nextKeyword(states, 'CANCELLED'), isNull);
      expect(setTodo(text, 0, 'CANCELLED', now: now),
          '#+TODO: TODO NEXT | DONE CANCELLED\n* CANCELLED Task :x:\n');
      expect(() => setTodo(text, 0, 'WAITING', now: now),
          throwsA(isA<NoteChangeError>()));
    });

    test('with #+STARTUP: logdone, CLOSED: is added and removed', () {
      const text = '#+STARTUP: logdone\n* TODO Task\n:PROPERTIES:\n'
          ':ID: 5c6d\n:END:\nBody.\n';
      final done = setTodo(text, 0, 'DONE', now: now);
      expect(
          done,
          '#+STARTUP: logdone\n* DONE Task\nCLOSED: [2026-10-22 Thu 09:45]\n'
          ':PROPERTIES:\n:ID: 5c6d\n:END:\nBody.\n');
      expect(setTodo(done, 0, 'TODO', now: now), text);
    });

    test('CLOSED: goes first on an existing planning line', () {
      const text =
          '#+STARTUP: logdone\n* TODO Task\nSCHEDULED: <2026-10-23 Fri>\n';
      final done = setTodo(text, 0, 'DONE', now: now);
      expect(
          done,
          '#+STARTUP: logdone\n* DONE Task\n'
          'CLOSED: [2026-10-22 Thu 09:45] SCHEDULED: <2026-10-23 Fri>\n');
      expect(setTodo(done, 0, 'TODO', now: now), text);
    });

    test('without logdone no CLOSED: is added', () {
      expect(setTodo('* TODO Task\nBody.\n', 0, 'DONE', now: now),
          '* DONE Task\nBody.\n');
    });

    test("the cookie of the heading above counts its TODO sub-headings", () {
      const text = '* Project [0/2]\n** TODO a\n** TODO b\n';
      expect(setTodo(text, 1, 'DONE', now: now),
          '* Project [1/2]\n** DONE a\n** TODO b\n');
    });

    test('a repeating heading is not marked done here', () {
      expect(
          () => setTodo('* TODO Water\nSCHEDULED: <2026-10-23 Fri +1w>\n', 0,
              'DONE', now: now),
          throwsA(isA<NoteChangeError>()));
      expect(
          () => setTodo('* TODO Water\nEvery week: <2026-10-23 Fri +1w>\n', 0,
              'DONE', now: now),
          throwsA(isA<NoteChangeError>()));
    });

    test('the rest of the file stays byte for byte', () {
      final sections = sectionsOf(parseNote(busy));
      final heading = sections.indexWhere(
          (s) => s.headline.rawTitle?.contains('A heading') ?? false);
      expect(changedLines(busy, setTodo(busy, heading, 'TODO', now: now)).values,
          ['** TODO A heading\twith a tab :tag:']);
    });
  });

  test('items and headings are found again by their number', () {
    final document = parseNote(busy);
    final item = listItemsOf(document)[2];
    expect(listItemIndex(document, item), 2);
    final section = sectionsOf(document)[1];
    expect(sectionIndex(document, section), 1);
    expect(listItemIndex(document, listItemsOf(parseNote(busy))[2]), isNull);
  });

  test('logdone is read from #+STARTUP:', () {
    expect(logsDone(parseNote('#+STARTUP: logdone\n')), isTrue);
    expect(logsDone(parseNote('#+STARTUP: showall\n')), isFalse);
    expect(logsDone(OrgDocument.parse('* x\n')), isFalse);
  });
}
