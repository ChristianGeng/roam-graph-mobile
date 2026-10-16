import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/folding.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import 'node_screen_test.dart' show notes, open, orgText;

/// B with a #+STARTUP: line before its first heading.
Map<String, String> withStartup(String word) => {
      ...notes,
      'b.org': notes['b.org']!
          .replaceFirst('#+title: B\n', '#+title: B\n#+STARTUP: $word\n'),
    };

void main() {
  group('the state sections start in (#63)', () {
    OrgDocument doc(String text) => OrgDocument.parse(text);

    test("the setting, where the file has no #+STARTUP: folding word", () {
      final plain = doc(notes['b.org']!);
      expect(startupState(plain, SectionsOnOpen.collapsed),
          OrgVisibilityState.folded);
      expect(startupState(plain, SectionsOnOpen.headings),
          OrgVisibilityState.contents);
      expect(startupState(plain, SectionsOnOpen.expanded),
          OrgVisibilityState.subtree);
      // Other #+STARTUP: words leave the folding to the setting.
      expect(startupState(doc('#+STARTUP: hidestars\n* A\n'),
          SectionsOnOpen.collapsed), OrgVisibilityState.folded);
    });

    test("the file's #+STARTUP: wins, as in Emacs", () {
      expect(startupState(doc(withStartup('showall')['b.org']!),
          SectionsOnOpen.collapsed), OrgVisibilityState.subtree);
      expect(startupState(doc(withStartup('overview')['b.org']!),
          SectionsOnOpen.expanded), OrgVisibilityState.folded);
      expect(startupState(doc(withStartup('content')['b.org']!),
          SectionsOnOpen.expanded), OrgVisibilityState.contents);
    });

    test("a heading node's own section opens, its subheadings as set", () {
      expect(openRootState(OrgVisibilityState.folded),
          OrgVisibilityState.children);
      expect(openRootState(OrgVisibilityState.contents),
          OrgVisibilityState.children);
      expect(openRootState(OrgVisibilityState.subtree),
          OrgVisibilityState.subtree);
    });
  });

  group('the node view', () {
    testWidgets('Collapsed: the text before the first heading and the '
        'top-level headings', (tester) async {
      await open(tester, 'b', sections: SectionsOnOpen.collapsed);
      expect(orgText('Top text of B.'), findsOneWidget);
      expect(orgText('Part'), findsWidgets);
      expect(orgText('Other'), findsWidgets);
      expect(orgText('Part text.'), findsNothing);
      expect(orgText('Deeper'), findsNothing);
      expect(orgText('Other text'), findsNothing);
    });

    testWidgets('Headings: every heading, without its text', (tester) async {
      await open(tester, 'b', sections: SectionsOnOpen.headings);
      expect(orgText('Top text of B.'), findsOneWidget);
      expect(orgText('Deeper'), findsOneWidget);
      expect(orgText('Part text.'), findsNothing);
      expect(orgText('Deeper text.'), findsNothing);
      expect(orgText('Other text'), findsNothing);
    });

    testWidgets('Expanded: everything', (tester) async {
      await open(tester, 'b', sections: SectionsOnOpen.expanded);
      expect(orgText('Part text.'), findsOneWidget);
      expect(orgText('Deeper text.'), findsOneWidget);
      expect(orgText('Other text'), findsOneWidget);
    });

    testWidgets('#+STARTUP: showall in the file overrides Collapsed',
        (tester) async {
      await open(tester, 'b',
          texts: withStartup('showall'), sections: SectionsOnOpen.collapsed);
      expect(orgText('Part text.'), findsOneWidget);
      expect(orgText('Deeper text.'), findsOneWidget);
    });

    testWidgets('a heading node opens with its own text; its subheadings '
        'are folded', (tester) async {
      await open(tester, 'p', sections: SectionsOnOpen.collapsed);
      expect(orgText('Part text.'), findsOneWidget);
      expect(orgText('Deeper'), findsOneWidget);
      expect(orgText('Deeper text.'), findsNothing);
    });

    testWidgets('tapping a heading opens it', (tester) async {
      await open(tester, 'b', sections: SectionsOnOpen.collapsed);
      await tester.tap(orgText('Part').first);
      await tester.pumpAndSettle();
      expect(orgText('Part text.'), findsOneWidget);
    });
  });

  group('the settings', () {
    test('JSON: saved and read back; unknown values give the default', () {
      const headings = ViewSettings(sectionsOnOpen: SectionsOnOpen.headings);
      expect(ViewSettings.fromJson(headings.toJson()), headings);
      expect(ViewSettings.fromJson({'sectionsOnOpen': 'sideways'}),
          const ViewSettings());
      expect(ViewSettings.fromJson('nonsense'), const ViewSettings());
      expect(const ViewSettings().sectionsOnOpen, SectionsOnOpen.collapsed);
    });

    test('the file store keeps them; a broken file gives the defaults',
        () async {
      final dir = Directory.systemTemp.createTempSync('view-settings');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileViewSettingsStore(path: '${dir.path}/s.json');
      expect(await store.load(), const ViewSettings());
      const expanded = ViewSettings(sectionsOnOpen: SectionsOnOpen.expanded);
      await store.save(expanded);
      expect(await store.load(), expanded);
      File('${dir.path}/s.json').writeAsStringSync('{not json');
      expect(await store.load(), const ViewSettings());
    });

    testWidgets('quick choices: saved in order, and the latest is kept',
        (tester) async {
      final store = _GatedStore();
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) =>
            ViewSettingsHost(store: store, child: child!),
        home: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sections-headings')));
      await tester.tap(find.byKey(const ValueKey('sections-expanded')));
      await tester.pump();
      // The second save waits for the first.
      expect(store.started, [SectionsOnOpen.headings]);
      store.finish();
      await tester.pump();
      expect(store.started, [SectionsOnOpen.headings, SectionsOnOpen.expanded]);
      store.finish();
      await tester.pumpAndSettle();
      expect(store.saved, SectionsOnOpen.expanded);
      final group = tester.widget<RadioGroup<SectionsOnOpen>>(
          find.byType(RadioGroup<SectionsOnOpen>));
      expect(group.groupValue, SectionsOnOpen.expanded);
    });

    testWidgets('the settings page saves the choice', (tester) async {
      final store = MemoryViewSettingsStore();
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) =>
            ViewSettingsHost(store: store, child: child!),
        home: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sections-headings')));
      await tester.pumpAndSettle();
      expect(store.settings.sectionsOnOpen, SectionsOnOpen.headings);
      final tile = tester.widget<RadioGroup<SectionsOnOpen>>(
          find.byType(RadioGroup<SectionsOnOpen>));
      expect(tile.groupValue, SectionsOnOpen.headings);
    });
  });
}

/// A store whose saves finish only when [finish] is called, one at a time.
class _GatedStore implements ViewSettingsStore {
  final started = <SectionsOnOpen>[];
  final _pending = <Completer<void>>[];
  SectionsOnOpen? saved;

  void finish() => _pending.removeAt(0).complete();

  @override
  Future<ViewSettings> load() async => const ViewSettings();

  @override
  Future<void> save(ViewSettings settings) async {
    started.add(settings.sectionsOnOpen);
    final gate = Completer<void>();
    _pending.add(gate);
    await gate.future;
    saved = settings.sectionsOnOpen;
  }
}
