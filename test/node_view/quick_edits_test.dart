import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../folder/graph_updates_test.dart' show changeOutside;
import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../widget_test.dart';

/// A synthetic note with a checkbox list and TODO headings (AGENTS.md).
const tasks = ':PROPERTIES:\n:ID: t\n:END:\n#+title: Tasks\n'
    '#+STARTUP: showall\n'
    '- [ ] bread\n- [X] milk\n'
    '* TODO Write letter\n'
    '* Call back\n';

FakeFolderAccess withTasks({ChosenFolder saved = writableOrg}) =>
    FakeFolderAccess(
      saved: saved,
      files: [
        const FolderFile(path: 'roam', uri: 'content://r', isDirectory: true),
        const FolderFile(path: 'roam/t.org', uri: 'content://t', modified: 1),
      ],
      texts: {'roam/t.org': tasks},
    );

/// Opens the node view of the note above the graph view.
Future<void> openTasks(WidgetTester tester, FakeFolderAccess access) async {
  await start(tester, access);
  await tapText(tester, 'Show graph');
  await tester.pumpAndSettle();
  NodeScreen.open(
    tester.element(find.byType(GraphScreen)),
    graph: lastGraph!,
    id: 't',
    readNote: (path) async => access.texts['roam/$path'],
    nodeMemory: MemoryNodeMemory(),
    writer: lastWriter,
  );
  await tester.pumpAndSettle();
}

Finder rich(String text) => find.textContaining(text, findRichText: true);

String note(FakeFolderAccess access) => access.texts['roam/t.org']!;

void main() {
  group('quick edits in the node view (#150)', () {
    testWidgets('a tapped checkbox is saved at once, and Undo puts it back',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await tester.tap(rich('bread').last);
      await tester.pumpAndSettle();
      expect(note(access), contains('- [X] bread\n- [X] milk\n'));
      expect(find.text('Ticked "bread".'), findsOneWidget);
      // No diff screen came between.
      expect(find.text('Save'), findsNothing);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(note(access), tasks);
      expect(find.text('Undone.'), findsOneWidget);
    });

    testWidgets('a long press offers the states; the chosen one is saved',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await tester.longPress(rich('Write letter').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('todo-state--')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('todo-state-DONE')));
      await tester.pumpAndSettle();
      expect(note(access), contains('* DONE Write letter\n'));
      expect(find.text('"Write letter" is DONE now.'), findsOneWidget);
    });

    testWidgets('a slide offers the next state', (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await tester.drag(rich('Call back').last, const Offset(-400, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('todo-next-1')));
      await tester.pumpAndSettle();
      expect(note(access), contains('* TODO Call back\n'));
    });

    testWidgets('a note changed since it was shown is not saved, but read '
        'again', (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      final outside = tasks.replaceFirst('milk', 'butter');
      changeOutside(access, 'roam/t.org', outside);
      await tester.tap(rich('bread').last);
      await tester.pumpAndSettle();
      expect(note(access), outside);
      expect(find.textContaining('changed since the app showed it'),
          findsOneWidget);
      expect(rich('butter'), findsWidgets);
    });

    testWidgets('a folder with read access only asks for write access',
        (tester) async {
      final access = withTasks(saved: org);
      await openTasks(tester, access);
      await tester.tap(rich('bread').last);
      await tester.pumpAndSettle();
      expect(note(access), tasks);
      expect(access.pickCalls, 1);
    });
  });
}
