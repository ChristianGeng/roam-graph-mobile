import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart' show OrgHeadlineWidget;
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/heading_actions.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../widget_test.dart';

/// A synthetic note (AGENTS.md): plain headings, a heading node, and a
/// heading with a heading node below it.
const outline = ':PROPERTIES:\n:ID: t\n:END:\n#+title: Outline\n'
    '#+STARTUP: showall\n'
    '* TODO First\nText one.\n'
    '* Second\n** Child\n'
    '* Node heading\n:PROPERTIES:\n:ID: h\n:END:\nBody.\n'
    '* Parent\n** Kid node\n:PROPERTIES:\n:ID: k\n:END:\n';

/// Links to both heading nodes, so the deletion counts them.
const other = ':PROPERTIES:\n:ID: o\n:END:\n#+title: Other\n'
    'See [[id:h][the node]] and [[id:k][the kid]].\n';

FakeFolderAccess withOutline([String text = outline]) => FakeFolderAccess(
      saved: writableOrg,
      files: [
        const FolderFile(path: 'roam', uri: 'content://r', isDirectory: true),
        const FolderFile(path: 'roam/t.org', uri: 'content://t', modified: 1),
        const FolderFile(path: 'roam/o.org', uri: 'content://o', modified: 1),
      ],
      texts: {'roam/t.org': text, 'roam/o.org': other},
    );

Future<void> openOutline(WidgetTester tester, FakeFolderAccess access,
    {ViewSettings settings = const ViewSettings()}) async {
  await start(tester, access,
      viewSettings: MemoryViewSettingsStore(settings));
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

/// [text] in a heading, not in a snack bar that names it.
Finder rich(String text) => find.descendant(
    of: find.byType(OrgHeadlineWidget),
    matching: find.textContaining(text, findRichText: true));
String note(FakeFolderAccess access) => access.texts['roam/t.org']!;
Finder get undo => find.byTooltip('Undo the last change');
Finder item(HeadingAction action) => find.byKey(ValueKey('heading-${action.name}'));

Future<void> menu(WidgetTester tester, String heading) async {
  await tester.longPress(rich(heading).last);
  await tester.pumpAndSettle();
}

Future<void> act(WidgetTester tester, String heading, HeadingAction action) async {
  await menu(tester, heading);
  await tester.tap(item(action));
  await tester.pumpAndSettle();
}

/// A drag across the middle of [heading]'s line, past the threshold.
Future<void> swipe(WidgetTester tester, String heading,
    {required bool right}) async {
  final y = tester.getCenter(rich(heading).last).dy;
  await tester.dragFrom(Offset(400, y), Offset(right ? 350 : -350, 0));
  await tester.pumpAndSettle();
}

/// Confirms the deletion; it reads and writes files outside the fake
/// clock, so the test lets real time pass until the dialog closes and the
/// record of the change is written (a later test waits for it otherwise).
Future<void> confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('confirm-delete')));
  for (var i = 0; i < 100 && find.byType(Dialog).evaluate().isNotEmpty; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(() => const FileAgentLog().read());
  await tester.pumpAndSettle();
}

Future<void> keys(WidgetTester tester, LogicalKeyboardKey key,
    {bool alt = false, bool shift = false, bool control = false}) async {
  final held = [
    if (control) LogicalKeyboardKey.controlLeft,
    if (alt) LogicalKeyboardKey.altLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
  ];
  for (final k in held) {
    await tester.sendKeyDownEvent(k);
  }
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  for (final k in held.reversed) {
    await tester.sendKeyUpEvent(k);
  }
  await tester.pumpAndSettle();
}

void main() {
  // A deletion records its change in the app's folder; here a temporary
  // one, so the record ends within the test.
  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('heading-actions');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    support.deleteSync(recursive: true);
  });

  group('the heading menu (#217)', () {
    testWidgets('offers the actions in order, and greys out a refused one',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await menu(tester, 'Second');
      final ys = [
        for (final action in HeadingAction.values)
          tester.getTopLeft(item(action)).dy,
      ];
      expect(ys, [...ys]..sort());
      expect(find.text('TODO state…'), findsOneWidget);
      // A heading of level 1 cannot be promoted; the reason shows.
      expect(tester.widget<PopupMenuItem<HeadingAction>>(
              item(HeadingAction.promote)).enabled,
          isFalse);
      expect(find.textContaining('level 1'), findsWidgets);
      expect(tester.widget<PopupMenuItem<HeadingAction>>(
              item(HeadingAction.demote)).enabled,
          isTrue);
      await tester.tap(item(HeadingAction.promote), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(note(access), outline);
    });

    testWidgets('Demote and Promote move the subtree, with Undo in the bar',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await act(tester, 'Second', HeadingAction.demote);
      expect(note(access), contains('** Second\n*** Child\n'));
      expect(find.text('Demoted the heading.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('snack-undo')));
      await tester.pumpAndSettle();
      expect(note(access), outline);

      await act(tester, 'Child', HeadingAction.promote);
      expect(note(access), contains('* Second\n* Child\n'));
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), outline);
    });

    testWidgets('Move up and Move down swap with the sibling',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await act(tester, 'Second', HeadingAction.moveUp);
      expect(note(access),
          contains('* Second\n** Child\n* TODO First\nText one.\n* Node'));
      await act(tester, 'Second', HeadingAction.moveDown);
      expect(note(access), outline);
      // The first heading has none above it.
      await menu(tester, 'First');
      expect(tester.widget<PopupMenuItem<HeadingAction>>(
              item(HeadingAction.moveUp)).enabled,
          isFalse);
    });

    testWidgets('TODO state… and Delete heading', (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await act(tester, 'Second', HeadingAction.todo);
      await tester.tap(find.byKey(const ValueKey('todo-state-DONE')));
      await tester.pumpAndSettle();
      expect(note(access), contains('* DONE Second\n'));
      await act(tester, 'Second', HeadingAction.delete);
      expect(note(access), isNot(contains('Second')));
      expect(note(access), contains('Text one.\n* Node heading\n'));
    });

    testWidgets('a right click opens the same menu with the shortcuts',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await openOutline(tester, withOutline());
        await tester.tap(rich('Second').last,
            kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        for (final action in HeadingAction.values) {
          expect(item(action), findsOneWidget);
          expect(find.text(action.shortcut), findsOneWidget);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('swipes on headings (#217)', () {
    testWidgets('a swipe to the right goes through the TODO states',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await swipe(tester, 'Second', right: true);
      expect(note(access), contains('* TODO Second\n'));
      await swipe(tester, 'Second', right: true);
      expect(note(access), contains('* DONE Second\n'));
      await swipe(tester, 'Second', right: true);
      expect(note(access), outline);
    });

    testWidgets('a short drag does nothing', (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      final y = tester.getCenter(rich('Second').last).dy;
      await tester.dragFrom(Offset(400, y), const Offset(-100, 0));
      await tester.pumpAndSettle();
      expect(note(access), outline);
    });

    testWidgets('a swipe to the left deletes a plain heading; Undo',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await swipe(tester, 'Second', right: false);
      expect(note(access), isNot(contains('Second')));
      expect(note(access), isNot(contains('Child')));
      expect(find.text('Deleted the heading.'), findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(note(access), outline);
    });

    testWidgets('a heading node asks first, with its links',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await swipe(tester, 'Node heading', right: false);
      expect(find.text("Delete 'Node heading'?"), findsOneWidget);
      expect(find.text('1 note links to it'), findsOneWidget);
      expect(note(access), outline);
      await confirm(tester);
      expect(note(access), isNot(contains('Node heading')));
      expect(note(access), contains('** Child\n* Parent\n'));
    });

    testWidgets('a heading with a node below it asks first, and names it',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await swipe(tester, 'Parent', right: false);
      expect(find.text("Delete the heading 'Parent'?"), findsOneWidget);
      expect(find.text('Kid node'), findsWidgets);
      expect(find.text('1 note links to it'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(note(access), outline);

      await swipe(tester, 'Parent', right: false);
      await confirm(tester);
      expect(note(access), outline.substring(0, outline.indexOf('* Parent')));
    });

    testWidgets('with the setting off, a swipe does nothing', (tester) async {
      final access = withOutline();
      await openOutline(tester, access,
          settings: const ViewSettings(swipeHeadings: false));
      await swipe(tester, 'Second', right: false);
      await swipe(tester, 'Second', right: true);
      expect(note(access), outline);
    });
  });

  group('the setting "Swipe actions on headings" (#217)', () {
    test('old saved settings get the platform default', () {
      final old = ViewSettings.fromJson({'theme': 'dark'});
      expect(old.swipeHeadings, isTrue);
      expect(old.toJson().containsKey('swipeHeadings'), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        expect(old.swipeHeadings, isFalse);
        expect(const ViewSettings().swipeHeadings, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('a chosen value is kept', () {
      final off = ViewSettings.fromJson(
          const ViewSettings(swipeHeadings: false).toJson());
      expect(off.swipeHeadings, isFalse);
      expect(off, const ViewSettings(swipeHeadings: false));
      expect(const ViewSettings().copyWith(swipeHeadings: true).swipeHeadings,
          isTrue);
    });
  });

  group('the desktop shortcuts (#217)', () {
    testWidgets('each key acts on the clicked heading', (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      const left = LogicalKeyboardKey.arrowLeft,
          right = LogicalKeyboardKey.arrowRight;

      await tester.tap(rich('Second').last);
      await tester.pumpAndSettle();
      await keys(tester, right, alt: true, shift: true);
      expect(note(access), contains('** Second\n*** Child\n'));
      await keys(tester, left, alt: true, shift: true);
      expect(note(access), outline);

      await keys(tester, LogicalKeyboardKey.arrowUp, alt: true);
      expect(note(access), contains('* Second\n** Child\n* TODO First'));
      await keys(tester, LogicalKeyboardKey.arrowDown, alt: true);
      expect(note(access), outline);

      await keys(tester, right, shift: true);
      expect(note(access), contains('* TODO Second\n'));
      await keys(tester, left, shift: true);
      expect(note(access), outline);
      await keys(tester, left, shift: true);
      expect(note(access), contains('* DONE Second\n'));

      await keys(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(note(access), outline);

      await keys(tester, LogicalKeyboardKey.delete);
      expect(note(access), isNot(contains('Second')));
      await keys(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(note(access), outline);
    });

    testWidgets('a refused key says why', (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await tester.tap(rich('Second').last);
      await tester.pumpAndSettle();
      await keys(tester, LogicalKeyboardKey.arrowLeft, alt: true, shift: true);
      expect(note(access), outline);
      expect(find.textContaining('level 1'), findsOneWidget);
    });

    testWidgets('no shortcut while a text field has the focus',
        (tester) async {
      final access = withOutline();
      await openOutline(tester, access);
      await tester.tap(rich('Second').last);
      await tester.pumpAndSettle();
      await keys(tester, LogicalKeyboardKey.keyF, control: true);
      expect(find.byType(TextField), findsOneWidget);
      await keys(tester, LogicalKeyboardKey.delete);
      await keys(tester, LogicalKeyboardKey.arrowRight, shift: true);
      expect(note(access), outline);
    });
  });
}
