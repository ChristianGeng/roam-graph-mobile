import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart' show SearchResultKey;
import 'package:roam_graph_mobile/node_view/note_search.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import 'node_screen_test.dart' show graphOf, notes, open, orgText;

/// Synthetic notes only (AGENTS.md). S: two levels of headings, one of
/// them matching "apple".
const sNote = ':PROPERTIES:\n:ID: s\n:END:\n#+title: S\nIntro.\n'
    '* One\n** Apple pie\nSweet.\n** Bread\nPlain.\n'
    '* Two\nNothing here.\n';

final withS = {...notes, 's.org': sNote};

/// Opens the search bar and types [query].
Future<void> search(WidgetTester tester, String query) async {
  await tester.tap(find.byTooltip('Search in this note'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('note-search')), query);
  await tester.pumpAndSettle();
}

/// What the search bar says about the matches.
String count(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('note-search-count')))
    .data!;

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('the pattern: as typed, any case; nothing for an empty query', () {
    expect(notePattern(''), isNull);
    final pattern = notePattern('a.b')!;
    expect(pattern.hasMatch('A.B'), isTrue);
    expect(pattern.hasMatch('axb'), isFalse);
  });

  test('the count', () {
    final a = SearchResultKey(), b = SearchResultKey(), c = SearchResultKey();
    expect(hitCount(const [], null), 'No matches');
    expect(hitCount([a], null), '1 match');
    expect(hitCount([a, b, c], null), '3 matches');
    expect(hitCount([a, b, c], b), '2 of 3');
    expect(hitCount([a, b], c), '2 matches');
  });

  group('search inside a note (#152)', () {
    testWidgets('every match is marked and counted, any case',
        (tester) async {
      await open(tester, 'b');
      await search(tester, 'TEXT');
      // "Top text of B.", "Part text.", "Deeper text.", "Other text".
      expect(count(tester), '4 matches');
      expect(find.text('text', findRichText: true), findsNWidgets(4));
      await search(tester, 'nowhere');
      expect(count(tester), 'No matches');
    });

    testWidgets('next and previous go around the ends', (tester) async {
      await open(tester, 'b');
      await search(tester, 'text');
      await tapAndSettle(tester, find.byTooltip('Next match'));
      expect(count(tester), '1 of 4');
      for (var i = 0; i < 3; i++) {
        await tapAndSettle(tester, find.byTooltip('Next match'));
      }
      expect(count(tester), '4 of 4');
      await tapAndSettle(tester, find.byTooltip('Next match'));
      expect(count(tester), '1 of 4');
      await tapAndSettle(tester, find.byTooltip('Previous match'));
      expect(count(tester), '4 of 4');
    });

    testWidgets('Enter in the field goes to the next match', (tester) async {
      await open(tester, 'b');
      await search(tester, 'text');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(count(tester), '1 of 4');
    });

    testWidgets('a match in a folded section opens it', (tester) async {
      await open(tester, 'b', sections: SectionsOnOpen.collapsed);
      expect(orgText('Deeper text.'), findsNothing);
      await search(tester, 'deeper text');
      expect(count(tester), '1 match');
      expect(find.text('Deeper text', findRichText: true), findsOneWidget);
    });

    testWidgets('"Only matching sections" folds the others away',
        (tester) async {
      await open(tester, 's',
          texts: withS, graph: ValueNotifier(graphOf(withS)));
      await search(tester, 'apple');
      // Without it, the heading of a section without a match still shows.
      expect(orgText('Bread'), findsOneWidget);
      expect(orgText('Two'), findsOneWidget);
      await tapAndSettle(tester, find.byKey(const ValueKey('only-matching')));
      expect(orgText('Bread'), findsNothing);
      // A top-level heading stays as a folded line, as in Org.
      expect(orgText('Two'), findsOneWidget);
      expect(orgText('Nothing here.'), findsNothing);
      expect(find.text('Apple', findRichText: true), findsOneWidget);
      await tapAndSettle(tester, find.byKey(const ValueKey('only-matching')));
      expect(orgText('Bread'), findsOneWidget);
    });

    testWidgets('closing removes the marks and restores the folding',
        (tester) async {
      await open(tester, 'b');
      expect(orgText('Other text'), findsOneWidget);
      await search(tester, 'deeper');
      // The search folds the sections without a match.
      expect(orgText('Other text'), findsNothing);
      await tapAndSettle(tester, find.byTooltip('Close search'));
      expect(find.byKey(const ValueKey('note-search')), findsNothing);
      expect(orgText('Other text'), findsOneWidget);
      // Unmarked: the paragraph is one text again.
      expect(orgText('Deeper text.'), findsOneWidget);
    });

    testWidgets('closing after a folded start folds again', (tester) async {
      await open(tester, 'b', sections: SectionsOnOpen.collapsed);
      await search(tester, 'deeper text');
      expect(find.text('Deeper text', findRichText: true), findsOneWidget);
      await tapAndSettle(tester, find.byTooltip('Close search'));
      expect(orgText('Deeper text.'), findsNothing);
    });

    testWidgets('Back closes the search first', (tester) async {
      await open(tester, 'b');
      await search(tester, 'text');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note-search')), findsNothing);
      expect(orgText('Top text of B.'), findsOneWidget);
    });

    testWidgets('Ctrl+F opens it, on the desktop', (tester) async {
      await open(tester, 'b');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note-search')), findsOneWidget);
    });

    testWidgets('dark mode: the marks use the theme\'s colours',
        (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await open(tester, 'b');
      await search(tester, 'text');
      expect(count(tester), '4 matches');
    });
  });
}
