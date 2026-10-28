import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../ai/ai_settings_test.dart' show MemoryAiSettingsStore, MemoryKeyStore;

/// Shows the Settings page with synthetic settings in memory.
Future<MemoryViewSettingsStore> pumpSettings(
  WidgetTester tester, {
  ViewSettings settings = const ViewSettings(),
  AiSettings ai = const AiSettings(),
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = MemoryViewSettingsStore(settings);
  await tester.pumpWidget(AiSettingsHost(
    store: MemoryAiSettingsStore(ai),
    keys: MemoryKeyStore(),
    child: MaterialApp(
      builder: (context, child) => ViewSettingsHost(store: store, child: child!),
      home: const SettingsScreen(),
    ),
  ));
  await tester.pumpAndSettle();
  return store;
}

double top(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(ValueKey(key))).dy;

void main() {
  group('the Settings main page (#189)', () {
    testWidgets('has AI, View, then the Note files heading and its row',
        (tester) async {
      await pumpSettings(tester);
      final ai = top(tester, 'settings-ai');
      final view = top(tester, 'settings-view');
      final heading = top(tester, 'settings-note-files');
      final images = top(tester, 'settings-image-folder');
      expect(ai, lessThan(view));
      expect(view, lessThan(heading));
      expect(heading, lessThan(images));
      expect(find.text('Note files'), findsOneWidget);
      // The radio groups moved to the View page.
      expect(find.byKey(const ValueKey('theme-dark')), findsNothing);
      expect(find.byKey(const ValueKey('sections-headings')), findsNothing);
      expect(find.byKey(const ValueKey('start-layout-circo')), findsNothing);
      expect(find.byKey(const ValueKey('settings-graph-width')), findsNothing);
    });

    testWidgets('the AI row names the chat provider and model',
        (tester) async {
      await pumpSettings(tester, ai: const AiSettings(provider: 'mistral'));
      expect(find.text('Mistral · mistral-large-4'), findsOneWidget);
    });

    testWidgets('the View row names the theme and the layout at start',
        (tester) async {
      await pumpSettings(
        tester,
        settings: const ViewSettings(
            theme: AppTheme.dark, startLayout: StartLayout.radial),
      );
      expect(find.text('Dark · Radial'), findsOneWidget);
    });

    testWidgets('the View row follows a change made on the View page',
        (tester) async {
      await pumpSettings(tester);
      expect(find.text('System · Force-directed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('theme-light')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Light · Force-directed'), findsOneWidget);
    });

    testWidgets('the image folder row shows its folder', (tester) async {
      await pumpSettings(tester,
          settings: const ViewSettings(imageFolder: 'pictures/new'));
      expect(find.textContaining('roam/pictures/new/'), findsOneWidget);
    });

    testWidgets('"Emacs command" is shown on the desktop, between View and '
        'the images', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpSettings(tester);
        final heading = top(tester, 'settings-note-files');
        final emacs = top(tester, 'settings-emacs');
        final images = top(tester, 'settings-image-folder');
        expect(heading, lessThan(emacs));
        expect(emacs, lessThan(images));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('"Emacs command" is not shown on Android', (tester) async {
      await pumpSettings(tester);
      expect(find.byKey(const ValueKey('settings-emacs')), findsNothing);
      expect(find.text('Emacs command'), findsNothing);
    });

    testWidgets('AI opens the AI settings page', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.byKey(const ValueKey('settings-ai')));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsScreen), findsOneWidget);
    });

    testWidgets('View opens the View page', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.byKey(const ValueKey('settings-view')));
      await tester.pumpAndSettle();
      expect(find.byType(ViewSettingsScreen), findsOneWidget);
    });
  });

  group('the View page (#189)', () {
    Future<MemoryViewSettingsStore> pumpView(WidgetTester tester,
        {ViewSettings settings = const ViewSettings()}) async {
      final store = await pumpSettings(tester, settings: settings);
      await tester.tap(find.byKey(const ValueKey('settings-view')));
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('has the four parts in order', (tester) async {
      await pumpView(tester);
      final theme = top(tester, 'theme-system');
      final sections = top(tester, 'sections-collapsed');
      final layout = top(tester, 'start-layout-force');
      final width = top(tester, 'settings-graph-width');
      expect(theme, lessThan(sections));
      expect(sections, lessThan(layout));
      expect(layout, lessThan(width));
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Sections when a note opens'), findsOneWidget);
      expect(find.text('Graph layout at start'), findsOneWidget);
      expect(find.text('Graph width on the tablet'), findsOneWidget);
    });

    testWidgets('saves the theme', (tester) async {
      final store = await pumpView(tester);
      await tester.tap(find.byKey(const ValueKey('theme-dark')));
      await tester.pumpAndSettle();
      expect(store.settings.theme, AppTheme.dark);
    });

    testWidgets('saves the sections when a note opens', (tester) async {
      final store = await pumpView(tester);
      await tester.tap(find.byKey(const ValueKey('sections-headings')));
      await tester.pumpAndSettle();
      expect(store.settings.sectionsOnOpen, SectionsOnOpen.headings);
    });

    testWidgets('saves the graph layout at start', (tester) async {
      final store = await pumpView(tester);
      await tester.tap(find.byKey(const ValueKey('start-layout-radial')));
      await tester.pumpAndSettle();
      expect(store.settings.startLayout, StartLayout.radial);
    });

    testWidgets('shows the graph width and resets it', (tester) async {
      final store = await pumpView(tester,
          settings: const ViewSettings(graphShare: 0.7));
      expect(find.textContaining('Graph 70 %, note 30 %'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-graph-width-reset')));
      await tester.pumpAndSettle();
      expect(store.settings.graphShare, ViewSettings.defaultGraphShare);
      expect(find.textContaining('Graph 40 %, note 60 %'), findsOneWidget);
    });
  });
}
