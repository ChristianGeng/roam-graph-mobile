import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/folder/folder_screen.dart'
    show changeCheckInterval;
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../folder/graph_updates_test.dart' show changeOutside;
import '../widget_test.dart';
import 'node_screen_test.dart' show graphOf, notes, open, orgText;
import 'quick_edits_test.dart' show note, openTasks, rich, withTasks;

/// A synthetic note with two top-level headings, all folded when it opens.
const shopping = ':PROPERTIES:\n:ID: t\n:END:\n#+title: Tasks\n'
    'See [[id:o][Other note]].\n'
    '* Shopping\n- [ ] bread\n- [ ] milk\n'
    '* Letters\nLetter text.\n';

void main() {
  group('an opened heading stays open (#254)', () {
    testWidgets('after a rebuild with the same text', (tester) async {
      final graph = ValueNotifier(graphOf(notes));
      await open(tester, 'b',
          graph: graph, sections: SectionsOnOpen.collapsed);
      expect(orgText('Part text.'), findsNothing);
      await tester.tap(orgText('Part').first);
      await tester.pumpAndSettle();
      expect(orgText('Part text.'), findsOneWidget);

      // A new graph object for the same notes reads the note again.
      graph.value = graphOf(notes);
      await tester.pumpAndSettle();
      expect(orgText('Part text.'), findsOneWidget);
      expect(orgText('Deeper text.'), findsNothing);
    });

    testWidgets('when the text of the note changed and the heading is there',
        (tester) async {
      final graph = ValueNotifier(graphOf(notes));
      final texts = {...notes};
      await open(tester, 'b',
          graph: graph, texts: texts, sections: SectionsOnOpen.collapsed);
      await tester.tap(orgText('Part').first);
      await tester.pumpAndSettle();
      expect(orgText('Part text.'), findsOneWidget);

      texts['b.org'] = notes['b.org']!
              .replaceFirst('Top text of B.', 'Top text of B, changed.') +
          '* Third\nThird text.\n';
      graph.value = graphOf(texts);
      await tester.pumpAndSettle();
      expect(orgText('Top text of B, changed.'), findsOneWidget);
      expect(orgText('Part text.'), findsOneWidget);
      // The new heading follows the setting: folded.
      expect(orgText('Third'), findsWidgets);
      expect(orgText('Third text.'), findsNothing);
      expect(orgText('Other text'), findsNothing);
    });
  });

  group('the folding in the app (#254)', () {
    Future<void> openShopping(WidgetTester tester, FakeFolderAccess access) async {
      await openTasks(tester, access);
      expect(rich('milk'), findsNothing);
      await tester.tap(rich('Shopping').first);
      await tester.pumpAndSettle();
      expect(rich('milk'), findsOneWidget);
    }

    testWidgets('a new graph from a scan, with another note changed',
        (tester) async {
      final access = withTasks(text: shopping);
      await openShopping(tester, access);
      final before = lastGraph!.value;
      changeOutside(access, 'roam/o.org', 'More outside text.\n');
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(identical(lastGraph!.value, before), isFalse);
      expect(rich('milk'), findsOneWidget);
      expect(rich('Letter text.'), findsNothing);
    });

    testWidgets('the note changed in Emacs; a new heading follows the setting',
        (tester) async {
      final access = withTasks(text: shopping);
      await openShopping(tester, access);
      changeOutside(access, 'roam/t.org',
          '${shopping.replaceFirst('See', 'Look at')}* Added\nAdded text.\n');
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(rich('Look at'), findsOneWidget);
      expect(rich('milk'), findsOneWidget);
      expect(rich('Added'), findsWidgets);
      expect(rich('Added text.'), findsNothing);
      expect(rich('Letter text.'), findsNothing);
    });

    testWidgets('a quick edit of a checkbox', (tester) async {
      final access = withTasks(text: shopping);
      await openShopping(tester, access);
      await tester.tap(rich('bread').last);
      await tester.pumpAndSettle();
      expect(note(access), contains('- [X] bread\n- [ ] milk\n'));
      expect(rich('milk'), findsOneWidget);
      expect(rich('Letter text.'), findsNothing);
    });

    testWidgets('coming back to the app with nothing changed builds no '
        'new graph', (tester) async {
      final access = withTasks(text: shopping);
      await openShopping(tester, access);
      final before = lastGraph!.value;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(identical(lastGraph!.value, before), isTrue);
      expect(rich('milk'), findsOneWidget);
    });

    testWidgets("Emacs's lock, auto-save and backup files start no scan",
        (tester) async {
      final access = withTasks(text: shopping);
      await openShopping(tester, access);
      final before = lastGraph!.value;
      access.readCalls.clear();
      access.files = [
        ...access.files,
        const FolderFile(path: 'roam/.#t.org', uri: 'content://l1', modified: 5),
        const FolderFile(path: 'roam/#t.org#', uri: 'content://l2', modified: 5),
        const FolderFile(path: 'roam/t.org~', uri: 'content://l3', modified: 5),
      ];
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(access.readCalls, isEmpty);
      expect(identical(lastGraph!.value, before), isTrue);
      expect(rich('milk'), findsOneWidget);
    });
  });
}
