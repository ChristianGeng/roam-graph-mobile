import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/delete_dialog.dart';
import 'package:roam_graph_mobile/edit/edit_screen.dart';
import 'package:roam_graph_mobile/edit/recent_changes_screen.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/search/search_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../graph_view/graph_screen_test.dart'
    show MemoryNodeMemory, layoutHere, algorithmsHere, phoneScreen;
import 'delete_fixtures.dart';

Future<void> showPage(
  WidgetTester tester,
  Widget page, {
  Size screen = phoneScreen,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = screen;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pumpAndSettle();
}

Future<void> confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('confirm-delete')));
  await tester.pumpAndSettle();
}

void main() {
  late DeleteFixture f;
  setUp(() => f = DeleteFixture());
  tearDown(() => f.graph.dispose());

  Widget graphPage() => ViewSettingsHost(
    store: MemoryViewSettingsStore(
      const ViewSettings(startLayout: StartLayout.circo),
    ),
    child: GraphScreen(
      graph: f.graph,
      readNote: (path) async => f.store.files[path],
      writer: f.writer,
      nodeMemory: MemoryNodeMemory('a'),
      computeLayout: layoutHere,
      computeAlgorithms: algorithmsHere,
    ),
  );

  Future<void> openNode(WidgetTester tester) async {
    await showPage(tester, graphPage());
    await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete note…'));
    await tester.pumpAndSettle();
  }

  testWidgets('phone note menus have distinct icons and actions', (
    tester,
  ) async {
    await showPage(tester, graphPage());
    await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byTooltip('Edit'),
        matching: find.byIcon(Icons.more_vert),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byTooltip('More for this note'),
        matching: find.byIcon(Icons.more_horiz),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('More for this note'));
    await tester.pumpAndSettle();
    expect(find.text('New node from here'), findsOneWidget);
    expect(find.text('Delete note…'), findsNothing);
  });

  testWidgets(
    'note menu confirms the file, child count and backlinks, then Undo',
    (tester) async {
      await openNode(tester);
      expect(find.text("Delete 'Alpha'?"), findsOneWidget);
      expect(find.text('The file a.org will be deleted'), findsOneWidget);
      expect(
        find.text('2 heading nodes in this file will also be deleted.'),
        findsOneWidget,
      );
      expect(find.text('2 notes link to it'), findsOneWidget);
      expect(f.store.files, deleteNotes);
      await confirm(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(NodeScreen), findsNothing);
      expect(f.store.files.containsKey('a.org'), isFalse);
      expect(find.text("Deleted 'Alpha'"), findsOneWidget);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, isTrue);
      await tester.pump(const Duration(seconds: 20));
      expect(find.text("Deleted 'Alpha'"), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(f.store.files, deleteNotes);
      expect(find.text('Undone.'), findsOneWidget);
    },
  );

  testWidgets(
    'Cancel writes nothing and Leave the links preserves other notes',
    (tester) async {
      await openNode(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(f.store.writes, 0);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete note…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave the links'));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(f.store.files['b.org'], deleteNotes['b.org']);
      expect(f.store.files['l.org'], deleteNotes['l.org']);
    },
  );

  testWidgets('a changed target is refused while its confirmation is open', (
    tester,
  ) async {
    await openNode(tester);
    f.store.files['a.org'] = '${deleteNotes['a.org']}Newer.\n';
    await confirm(tester);
    expect(find.textContaining('changed since it was read'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(f.store.files['a.org'], endsWith('Newer.\n'));
    expect(f.log.entries, isEmpty);
  });

  testWidgets('Undo names a linking note left unchanged', (tester) async {
    await openNode(tester);
    await confirm(tester);
    final outside = '${f.store.files['b.org']}Newer.\n';
    f.store.files['b.org'] = outside;
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Undone. Left unchanged: Beta.'), findsOneWidget);
    expect(f.store.files['b.org'], outside);
    expect(f.store.files['a.org'], deleteNotes['a.org']);
  });

  testWidgets(
    'the next action dismisses Undo; Recent changes can still restore',
    (tester) async {
      await openNode(tester);
      await confirm(tester);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text("Deleted 'Alpha'"), findsNothing);
      await tester.tap(find.text('Recent changes'));
      await tester.pumpAndSettle();
      expect(find.byType(RecentChangesScreen), findsOneWidget);
      await tester.tap(find.text("Delete 'Alpha'"));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recent-undo-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-undo')));
      await tester.pumpAndSettle();
      expect(f.store.files, deleteNotes);
    },
  );

  testWidgets('a keyboard action also dismisses the persistent message', (
    tester,
  ) async {
    await openNode(tester);
    await confirm(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text("Deleted 'Alpha'"), findsNothing);
    expect(recentMessages(await f.log.read()), hasLength(1));
  });

  for (final secondary in [false, true]) {
    testWidgets(
      'graph ${secondary ? 'right click' : 'long press'} opens a menu first',
      (tester) async {
        await showPage(tester, graphPage());
        final at = tester.getCenter(find.byType(InteractiveViewer));
        if (secondary) {
          await tester.tapAt(at, buttons: kSecondaryMouseButton);
        } else {
          await tester.longPressAt(at);
        }
        await tester.pumpAndSettle();
        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Edit'), findsOneWidget);
        expect(find.text('Delete…'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(f.store.writes, 0);
        await tester.tap(find.text('Delete…'));
        await tester.pumpAndSettle();
        expect(find.text("Delete 'Alpha'?"), findsOneWidget);
        expect(f.store.writes, 0);
        await confirm(tester);
        expect(f.store.files.containsKey('a.org'), isFalse);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(f.store.files, deleteNotes);
      },
    );
  }

  testWidgets('graph Edit opens the text editor without deleting', (
    tester,
  ) async {
    await showPage(tester, graphPage());
    await tester.longPressAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(EditScreen), findsOneWidget);
    expect(f.store.writes, 0);
  });

  testWidgets('graph Edit ends a pane quick-edit visit even when cancelled', (
    tester,
  ) async {
    f.store.files['a.org'] = deleteNotes['a.org']!.replaceFirst(
      'See ',
      '- [ ] bread\nSee ',
    );
    f.store.notify?.call();
    await showPage(tester, graphPage(), screen: const Size(1200, 800));
    await tester.tap(find.textContaining('bread', findRichText: true).last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Undo the last change'), findsOneWidget);
    await tester.longPressAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Undo the last change'), findsNothing);
  });

  testWidgets(
    'tablet deletion returns to a surviving note without popping graph',
    (tester) async {
      await showPage(tester, graphPage(), screen: const Size(1200, 800));
      expect(find.byType(NodeScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete note…'));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(find.byType(GraphScreen), findsOneWidget);
      expect(find.text('This node no longer exists.'), findsNothing);
      expect(find.text("Deleted 'Alpha'"), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search deletes two selected notes in one history group and Undo',
    (tester) async {
      await showPage(
        tester,
        SearchScreen(
          graph: f.graph,
          readNote: (path) async => f.store.files[path],
          writer: f.writer,
          nodeMemory: MemoryNodeMemory(),
        ),
      );
      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 notes?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Alpha'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Beta'),
        ),
        findsOneWidget,
      );
      await confirm(tester);
      expect(f.store.files.keys, ['l.org']);
      expect(recentMessages(await f.log.read()), hasLength(1));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(f.store.files, deleteNotes);
      expect(find.byTooltip('Delete…'), findsNothing);
    },
  );

  testWidgets('batch dialog lists ten titles and the remaining count', (
    tester,
  ) async {
    final many = DeleteFixture({
      for (var i = 0; i < 12; i++)
        '$i.org': ':PROPERTIES:\n:ID: n$i\n:END:\n#+title: Note $i\n',
    });
    addTearDown(many.graph.dispose);
    await showPage(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => confirmDeleteNotes(
              context,
              graph: many.graph.value,
              nodes: [
                for (var i = 0; i < 12; i++) many.graph.value.nodes['n$i']!,
              ],
              writer: many.writer,
            ),
            child: const Text('Start'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('and 2 more'), findsOneWidget);
    expect(find.text('Note 10'), findsNothing);
    expect(find.text('Note 11'), findsNothing);
  });
}
