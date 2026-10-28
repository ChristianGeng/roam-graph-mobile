import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../widget_test.dart';

/// Opens the node view of [id] above the graph view.
Future<void> openNode(WidgetTester tester, FakeFolderAccess access, String id,
    {EditHistory? history}) async {
  await start(tester, access, history: history);
  await tester.pumpAndSettle();
  NodeScreen.open(
    tester.element(find.byType(GraphScreen)),
    graph: lastGraph!,
    id: id,
    readNote: (path) async => access.texts['roam/$path'],
    nodeMemory: MemoryNodeMemory(),
    writer: lastWriter,
  );
  await tester.pumpAndSettle();
}

/// Types [query] in the list of notes and taps [choice].
Future<void> choose(WidgetTester tester, String query, Finder choice) async {
  await tester.enterText(find.byKey(const ValueKey('picker-search')), query);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

const bAfterHead = ':PROPERTIES:\n:ID: b\n:ROAM_REFS: https://example.com\n'
    ':END:\n#+title: B\n#+filetags: :x:\n';

void main() {
  group('add links from the note view (#135)', () {
    testWidgets('"+" next to Links: to this note\'s "See also:" line',
        (tester) async {
      final history = MemoryEditHistory();
      final access = withNotes(saved: writableOrg);
      await openNode(tester, access, 'b', history: history);
      final before = access.texts['roam/b.org']!;
      expect(find.text('No links'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-link')));
      await tester.pumpAndSettle();
      // b itself is not offered.
      expect(find.widgetWithText(ListTile, 'B'), findsNothing);
      await choose(tester, 'A', find.widgetWithText(ListTile, 'A'));
      expect(find.text('+See also: [[id:a][A]]'), findsOneWidget);
      expect(access.replaced, isEmpty);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(access.texts['roam/b.org'],
          startsWith('${bAfterHead}See also: [[id:a][A]]\n* Heading\n'));
      expect(find.text('Linked "B" to "A".'), findsOneWidget);
      expect(find.text('Links: 1'), findsOneWidget);
      expect(
          (await history.versions('content://tree/org\nb.org')).single.text,
          before);
    });

    testWidgets('a note linked already is said so, and nothing changes',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      await openNode(tester, access, 'a');
      await tester.tap(find.byKey(const ValueKey('add-link')));
      await tester.pumpAndSettle();
      await choose(tester, 'B', find.widgetWithText(ListTile, 'B'));
      expect(find.text('"A" links to "B" already. Nothing was changed.'),
          findsOneWidget);
      expect(access.replaced, isEmpty);
    });

    testWidgets('"+" next to Backlinks: the other note gets the link',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      await openNode(tester, access, 'a');
      expect(find.text('No backlinks'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-backlink')));
      await tester.pumpAndSettle();
      await choose(tester, 'B', find.widgetWithText(ListTile, 'B'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(access.texts['roam/b.org'],
          startsWith('${bAfterHead}See also: [[id:a][A]]\n* Heading\n'));
      expect(find.text('Backlinks: 1'), findsOneWidget);
    });

    testWidgets('a new note from the list, then the link to it',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      await openNode(tester, access, 'b');
      await tester.tap(find.byKey(const ValueKey('add-link')));
      await tester.pumpAndSettle();
      // "A" is a title already: no new note offered for it.
      await tester.enterText(find.byKey(const ValueKey('picker-search')), 'A');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('picker-new')), findsNothing);
      await choose(tester, 'New idea', find.text('New note "New idea"'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final (_, name) = access.created.single;
      expect(name, matches(RegExp(r'^\d{14}-new_idea\.org$')));
      final text = access.texts['roam/$name']!;
      final id = RegExp(r':ID:\s+(\S+)').firstMatch(text)!.group(1)!;
      expect(text, contains('#+title: New idea\n'));
      expect(access.texts['roam/b.org'],
          contains('See also: [[id:$id][New idea]]\n'));
      expect(lastGraph!.value.nodes[id]?.title, 'New idea');
      // The new note does not open.
      expect(find.text('Links: 1'), findsOneWidget);
    });

    testWidgets('cancelling the diff writes nothing; the new note stays',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      await openNode(tester, access, 'b');
      final before = access.texts['roam/b.org'];
      await tester.tap(find.byKey(const ValueKey('add-link')));
      await tester.pumpAndSettle();
      await choose(tester, 'Hub', find.text('New note "Hub"'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(access.replaced, isEmpty);
      expect(access.texts['roam/b.org'], before);
      final (_, name) = access.created.single;
      expect(find.text('The new note roam/$name stays, without this link to '
          'it.'), findsOneWidget);
    });

    testWidgets('a folder with read access only offers to choose it again',
        (tester) async {
      final access = withNotes(saved: org);
      await openNode(tester, access, 'b');
      await tester.tap(find.byKey(const ValueKey('add-link')));
      await tester.pumpAndSettle();
      await choose(tester, 'A', find.widgetWithText(ListTile, 'A'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(access.replaced, isEmpty);
      expect(access.pickCalls, 1);
    });
  });

  group('"Insert link" in "Edit text" (#135)', () {
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

    testWidgets('at the cursor, with the title', (tester) async {
      final access = withNotes(saved: writableOrg);
      final text = await openEditor(tester, access);
      text.value = const TextEditingValue(
          text: 'See  here.\n', selection: TextSelection.collapsed(offset: 4));
      await tester.pump();
      await tester.tap(find.byTooltip('Insert link'));
      await tester.pumpAndSettle();
      await choose(tester, 'A', find.widgetWithText(ListTile, 'A'));
      expect(text.text, 'See [[id:a][A]] here.\n');
      expect(access.replaced, isEmpty);
    });

    testWidgets('over a selection, which becomes the description',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      final text = await openEditor(tester, access);
      text.value = const TextEditingValue(
          text: 'See the first note.\n',
          selection: TextSelection(baseOffset: 4, extentOffset: 18));
      await tester.pump();
      await tester.tap(find.byTooltip('Insert link'));
      await tester.pumpAndSettle();
      await choose(tester, 'A', find.widgetWithText(ListTile, 'A'));
      expect(text.text, 'See [[id:a][the first note]].\n');
    });
  });
}
