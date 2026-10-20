import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/agent_tools.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/folder/folder_screen.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../widget_test.dart';

/// Opens the node view of b, which a links to, above the graph view.
Future<void> openB(WidgetTester tester, FakeFolderAccess access,
    {EditHistory? history}) async {
  await start(tester, access, history: history);
  await tapText(tester, 'Show graph');
  await tester.pumpAndSettle();
  NodeScreen.open(
    tester.element(find.byType(GraphScreen)),
    graph: lastGraph!,
    id: 'b',
    readNote: (path) async => access.texts['roam/$path'],
    nodeMemory: MemoryNodeMemory(),
    writer: lastWriter,
  );
  await tester.pumpAndSettle();
  expect(find.text('Backlinks: 1'), findsOneWidget);
}

/// [path] changed from outside, as Syncthing brings it from Emacs.
void changeOutside(FakeFolderAccess access, String path, String text) {
  access.texts = {...access.texts, path: text};
  access.files = [
    for (final f in access.files)
      f.path == path
          ? FolderFile(path: f.path, uri: f.uri, modified: f.modified + 1)
          : f,
  ];
}

const aWithoutLink = ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\nNo link.\n';

bool aLinksToB() =>
    lastGraph!.value.links.any((l) => l.source == 'a' && l.dest == 'b');

void main() {
  group('a link removed in the app leaves the graph at once (#133)', () {
    testWidgets('with "Edit text"', (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      // From b's backlink to a, and edit a there.
      await tester.tap(find.byKey(const ValueKey('backlink-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit text'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('edit-text')), 'B [[id:gone]]\n');
      await tester.pump();
      await tester.tap(find.byTooltip('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(access.texts['roam/a.org'], endsWith('#+title: A\nB [[id:gone]]\n'));

      expect(aLinksToB(), isFalse);
      // Back on b's page, opened before the edit.
      Navigator.of(tester.element(find.byType(NodeScreen).last)).pop();
      await tester.pumpAndSettle();
      expect(find.text('No backlinks'), findsOneWidget);
      expect(find.byKey(const ValueKey('backlink-0')), findsNothing);
    });

    testWidgets("with the agent's edit_node_text", (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      final agent = AgentWriter(
        writer: lastWriter!,
        visibleGraph: () => lastGraph!.value,
        hiddenIds: () => const {},
        visibility: AiVisibility.none,
        folder: () => 'content://tree/org',
        limit: 30,
        log: MemoryAgentLog(),
      );
      final done = agent.run(const ToolCall('c', 'edit_node_text',
          {'id': 'a', 'old': '[[id:b]]', 'new': 'B'}));
      await tester.pumpAndSettle();
      expect(await done, 'Changed the text of "A".');
      await tester.pumpAndSettle();

      expect(access.texts['roam/a.org'], endsWith('#+title: A\nB [[id:gone]]\n'));
      expect(aLinksToB(), isFalse);
      expect(find.text('No backlinks'), findsOneWidget);
    });
  });

  group('changes from outside show while the app is open (#133)', () {
    testWidgets('a changed file is read within 30 seconds, and only it',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      access.readCalls.clear();
      changeOutside(access, 'roam/a.org', aWithoutLink);
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();

      expect(access.readCalls.first, ['roam/a.org']);
      expect(aLinksToB(), isFalse);
      expect(find.text('No backlinks'), findsOneWidget);
    });

    testWidgets('nothing changed: nothing is read', (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      access.readCalls.clear();
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(access.readCalls, isEmpty);
    });

    testWidgets('no check while an editor has text not saved',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      await tester.tap(find.byKey(const ValueKey('backlink-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit text'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('edit-text')), 'Mine.\n');
      await tester.pump();
      access.readCalls.clear();
      changeOutside(access, 'roam/a.org', aWithoutLink);
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(access.readCalls, isEmpty);
      expect(aLinksToB(), isTrue);

      // Without unsaved text, the next check reads it.
      await tester.enterText(
          find.byKey(const ValueKey('edit-text')), '[[id:b]] [[id:gone]]\n');
      await tester.pump();
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(aLinksToB(), isFalse);
    });

    testWidgets('no check in the background', (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      access.readCalls.clear();
      changeOutside(access, 'roam/a.org', aWithoutLink);
      await tester.pump(changeCheckInterval * 3);
      await tester.pumpAndSettle();
      expect(access.readCalls, isEmpty);
      expect(aLinksToB(), isTrue);

      // Back in the foreground, the folder is read again.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(aLinksToB(), isFalse);
    });
  });

  group('trash icons in the node view (#133)', () {
    Future<void> confirm(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
    }

    testWidgets('on a link of this note: it becomes its text',
        (tester) async {
      final history = MemoryEditHistory();
      final access = withNotes(saved: writableOrg);
      await openB(tester, access, history: history);
      final before = access.texts['roam/a.org']!;
      await tester.tap(find.byKey(const ValueKey('backlink-0')));
      await tester.pumpAndSettle();
      // a links to b and to a note that does not exist.
      expect(find.text('Links: 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('remove-link-0')));
      await tester.pumpAndSettle();
      expect(find.text('Remove the link to B from A'), findsOneWidget);
      expect(access.replaced, isEmpty);
      await confirm(tester);

      expect(access.texts['roam/a.org'], endsWith('#+title: A\nb [[id:gone]]\n'));
      expect(find.text('Removed the link to B from A; its text stays.'),
          findsOneWidget);
      expect(find.text('Links: 1'), findsOneWidget);
      expect((await history.versions('content://tree/org\na.org')).single.text,
          before);
      expect(aLinksToB(), isFalse);
      Navigator.of(tester.element(find.byType(NodeScreen).last)).pop();
      await tester.pumpAndSettle();
      expect(find.text('No backlinks'), findsOneWidget);
    });

    testWidgets('on a backlink: the link goes from the other note',
        (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      await tester.tap(find.byTooltip('Remove this link from A'));
      await confirm(tester);
      expect(access.texts['roam/a.org'], endsWith('#+title: A\nb [[id:gone]]\n'));
      expect(find.text('No backlinks'), findsOneWidget);
      expect(aLinksToB(), isFalse);
    });

    testWidgets('"Cancel" in the diff writes nothing', (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      await tester.tap(find.byTooltip('Remove this link from A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(access.replaced, isEmpty);
      expect(find.text('Backlinks: 1'), findsOneWidget);
    });

    testWidgets('a folder with read access only offers to choose it again',
        (tester) async {
      final access = withNotes(saved: org);
      await openB(tester, access);
      await tester.tap(find.byTooltip('Remove this link from A'));
      await confirm(tester);
      expect(access.replaced, isEmpty);
      expect(access.pickCalls, 1);
    });

    testWidgets('a note changed meanwhile is not overwritten', (tester) async {
      final access = withNotes(saved: writableOrg);
      await openB(tester, access);
      await tester.tap(find.byTooltip('Remove this link from A'));
      await tester.pumpAndSettle();
      access.texts = {
        ...access.texts,
        'roam/a.org': '${access.texts['roam/a.org']}From the laptop.\n',
      };
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(access.replaced, isEmpty);
      expect(find.textContaining('changed on the laptop or through Syncthing'),
          findsOneWidget);
    });

    testWidgets('on an image: the link goes with its lines, the file stays',
        (tester) async {
      final access = withNotes(saved: writableOrg)
        ..files = [
          ...someFiles(),
          const FolderFile(path: 'roam/img/p.png', uri: 'content://p'),
        ]
        ..texts = {
          ...someTexts,
          'roam/a.org': ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n'
              'Before.\n# image prompt: a fox\n#+caption: A fox\n'
              '[[file:img/p.png]]\nAfter.\n',
        };
      await start(tester, access);
      await tapText(tester, 'Show graph');
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove this image from the note'));
      await confirm(tester);

      expect(access.texts['roam/a.org'],
          ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\nBefore.\nAfter.\n');
      expect(access.deleted, isEmpty);
      expect(access.files.map((f) => f.path), contains('roam/img/p.png'));
      expect(
          find.text('Removed the image from A. The file img/p.png stays in '
              'the folder.'),
          findsOneWidget);
      expect(find.byTooltip('Remove this image from the note'), findsNothing);
    });
  });
}
