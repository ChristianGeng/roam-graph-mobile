import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/folder/folder_access.dart';
import 'package:roam_graph_mobile/folder/folder_screen.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../folder/graph_updates_test.dart' show changeOutside;
import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../widget_test.dart';

/// A synthetic note with a checkbox list and TODO headings (AGENTS.md).
const tasks = ':PROPERTIES:\n:ID: t\n:END:\n#+title: Tasks\n'
    '#+STARTUP: showall\n'
    'See [[id:o][Other note]].\n'
    '- [ ] bread\n- [X] milk\n'
    '* TODO Write letter\n'
    '* Call back\n';

const other = ':PROPERTIES:\n:ID: o\n:END:\n#+title: Other\nOther text.\n';

FakeFolderAccess withTasks({ChosenFolder saved = writableOrg}) =>
    FakeFolderAccess(
      saved: saved,
      files: [
        const FolderFile(path: 'roam', uri: 'content://r', isDirectory: true),
        const FolderFile(path: 'roam/t.org', uri: 'content://t', modified: 1),
        const FolderFile(path: 'roam/o.org', uri: 'content://o', modified: 1),
      ],
      texts: {'roam/t.org': tasks, 'roam/o.org': other},
    );

/// Opens the node view of the note above the graph view.
Future<void> openTasks(WidgetTester tester, FakeFolderAccess access,
    {ValueNotifier<String>? pane,
    EditHistory? history,
    void Function(BuildContext, String)? onShowInGraph}) async {
  await start(tester, access, history: history);
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(GraphScreen));
  if (pane != null) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<String>(
          valueListenable: pane,
          builder: (_, id, _) => NodeScreen(
            key: const ValueKey('node-pane'),
            graph: lastGraph!,
            id: id,
            readNote: (path) async => access.texts['roam/$path'],
            nodeMemory: MemoryNodeMemory(),
            writer: lastWriter,
          ),
        ),
      ),
    );
  } else {
    NodeScreen.open(
      context,
      graph: lastGraph!,
      id: 't',
      readNote: (path) async => access.texts['roam/$path'],
      nodeMemory: MemoryNodeMemory(),
      writer: lastWriter,
      onShowInGraph: onShowInGraph,
    );
  }
  await tester.pumpAndSettle();
}

Finder rich(String text) => find.textContaining(text, findRichText: true);

String note(FakeFolderAccess access) => access.texts['roam/t.org']!;

Finder get undo => find.byTooltip('Undo the last change');

Future<void> chooseDone(WidgetTester tester) async {
  await tester.longPress(rich('Write letter').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('todo-state-DONE')));
  await tester.pumpAndSettle();
}

/// Pauses a save after its fresh read and before replacing the file.
class DelayedHistory extends MemoryEditHistory {
  Completer<void>? pending;

  @override
  Future<DateTime> keep(String key, String text, DateTime time) async {
    await pending?.future;
    return super.keep(key, text, time);
  }
}

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

      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), tasks);
      expect(find.text('Undone.'), findsOneWidget);
      expect(undo, findsNothing);
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
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), tasks);
      expect(find.text('Undone.'), findsOneWidget);
      expect(undo, findsNothing);
    });

    testWidgets('two TODO changes undo newest first', (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await chooseDone(tester);
      final first = note(access);
      await tester.drag(rich('Call back').last, const Offset(-400, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('todo-next-1')));
      await tester.pumpAndSettle();
      expect(note(access), contains('* TODO Call back\n'));

      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), first);
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), tasks);
      expect(undo, findsNothing);
    });

    testWidgets('following a note link and returning ends the visit',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await chooseDone(tester);
      await tester.tapOnText(find.textRange.ofSubstring('Other note'));
      await tester.pumpAndSettle();
      expect(rich('Other text.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(rich('Write letter'), findsWidgets);
      expect(undo, findsNothing);
      expect(note(access), contains('* DONE Write letter\n'));
    });

    testWidgets('switching the pane ID and returning ends the visit',
        (tester) async {
      final access = withTasks();
      final pane = ValueNotifier('t');
      addTearDown(pane.dispose);
      await openTasks(tester, access, pane: pane);
      await chooseDone(tester);
      final state = tester.state(find.byType(NodeScreen));
      pane.value = 'o';
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(NodeScreen)), same(state));
      expect(rich('Other text.'), findsOneWidget);
      pane.value = 't';
      await tester.pumpAndSettle();
      expect(undo, findsNothing);
    });

    testWidgets('a pane switch with TalkBack dismisses the confirmation safely',
        (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(tester.binding.platformDispatcher
          .clearAccessibilityFeaturesTestValue);
      final access = withTasks();
      final pane = ValueNotifier('t');
      addTearDown(pane.dispose);
      await openTasks(tester, access, pane: pane);
      await chooseDone(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(undo, findsOneWidget);

      pane.value = 'o';
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SnackBar), findsNothing);
      expect(undo, findsNothing);
      expect(rich('Other text.'), findsOneWidget);
      pane.value = 't';
      await tester.pumpAndSettle();
      expect(undo, findsNothing);
      expect(note(access), contains('* DONE Write letter\n'));
    });

    testWidgets('a missing link target keeps this visit and its undo steps',
        (tester) async {
      final access = withTasks();
      final before = tasks.replaceFirst('Other note', 'Missing note')
          .replaceFirst('id:o', 'id:gone');
      access.texts = {...access.texts, 'roam/t.org': before};
      await openTasks(tester, access);
      await chooseDone(tester);
      await tester.tapOnText(find.textRange.ofSubstring('Missing note'));
      await tester.pumpAndSettle();
      expect(find.text('There is no node with the ID gone.'), findsOneWidget);
      expect(undo, findsOneWidget);
      expect(rich('Write letter'), findsWidgets);

      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), before);
      expect(undo, findsNothing);
    });

    testWidgets('a save finishing after a pane switch adds no undo step',
        (tester) async {
      final access = withTasks();
      final pane = ValueNotifier('t');
      final history = DelayedHistory();
      addTearDown(pane.dispose);
      await openTasks(tester, access, pane: pane, history: history);
      final pending = history.pending = Completer<void>();
      await tester.tap(rich('bread').last);
      await tester.pump();
      expect(note(access), tasks);
      pane.value = 'o';
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(note(access), contains('- [X] bread'));
      pane.value = 't';
      await tester.pumpAndSettle();
      expect(undo, findsNothing);
    });

    testWidgets('an undo finishing after a pane switch changes no visit steps',
        (tester) async {
      final access = withTasks();
      final pane = ValueNotifier('t');
      final history = DelayedHistory();
      addTearDown(pane.dispose);
      await openTasks(tester, access, pane: pane, history: history);
      await chooseDone(tester);
      final pending = history.pending = Completer<void>();
      await tester.tap(undo);
      await tester.pump();
      pane.value = 'o';
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(note(access), tasks);
      expect(undo, findsNothing);
      expect(find.text('Undone.'), findsNothing);
      pane.value = 't';
      await tester.pumpAndSettle();
      expect(undo, findsNothing);
    });

    for (final surface in [
      'Edit text',
      'Add to this node',
      'Title, tags and aliases',
      'Earlier versions',
    ]) {
      testWidgets('opening $surface and returning ends the visit',
          (tester) async {
        final access = withTasks();
        await openTasks(tester, access);
        await chooseDone(tester);
        final changed = note(access);
        await tester.tap(find.byTooltip('Edit').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(surface));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(undo, findsNothing);
        expect(note(access), changed);
      });
    }

    testWidgets('show in graph ends the visit', (tester) async {
      final access = withTasks();
      String? shown;
      await openTasks(tester, access,
          onShowInGraph: (_, id) => shown = id);
      await chooseDone(tester);
      await tester.tap(find.byTooltip('Show in graph').last);
      await tester.pumpAndSettle();
      expect(shown, 't');
      expect(undo, findsNothing);
    });

    testWidgets('an outside change clears undo on the next graph update',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await chooseDone(tester);
      final outside = note(access).replaceFirst('milk', 'butter');
      changeOutside(access, 'roam/t.org', outside);
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(undo, findsNothing);
      expect(note(access), outside);
      expect(rich('butter'), findsWidgets);
    });

    testWidgets('a graph update for another file keeps this undo chain',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await chooseDone(tester);
      changeOutside(access, 'roam/o.org', '$other\nMore outside text.\n');
      await tester.pump(changeCheckInterval);
      await tester.pumpAndSettle();
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), tasks);
      expect(access.texts['roam/o.org'], '$other\nMore outside text.\n');
    });

    testWidgets('undo refuses outside text before a graph update',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await chooseDone(tester);
      final outside = note(access).replaceFirst('milk', 'butter');
      changeOutside(access, 'roam/t.org', outside);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), outside);
      expect(undo, findsNothing);
      expect(find.textContaining('nothing was undone'), findsOneWidget);
    });

    testWidgets('a change during undo is protected by the hash check',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await chooseDone(tester);
      final outside = note(access).replaceFirst('milk', 'butter');
      access.beforeReplace = () {
        access.beforeReplace = null;
        changeOutside(access, 'roam/t.org', outside);
      };
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), outside);
      expect(undo, findsNothing);
      expect(find.textContaining('nothing was undone'), findsOneWidget);
    });

    testWidgets('confirmations close without taking away app-bar Undo',
        (tester) async {
      final access = withTasks();
      await openTasks(tester, access);
      await chooseDone(tester);
      final confirmation = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(confirmation.action, isNull);
      expect(confirmation.persist, isFalse);
      expect(confirmation.duration, const Duration(seconds: 2));
      expect(find.byType(SnackBarAction), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(undo, findsOneWidget);

      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(find.text('Undone.'), findsOneWidget);
      expect(find.byType(SnackBarAction), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
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
