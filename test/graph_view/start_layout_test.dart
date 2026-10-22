import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/graph/graph_layout.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../ai/ai_visibility_test.dart' show graphOf, notes;
import 'graph_screen_test.dart' show MemoryNodeMemory, algorithmsHere;

/// A store whose file is read only when [finish] is called (#81).
class SlowViewSettingsStore extends MemoryViewSettingsStore {
  SlowViewSettingsStore(super.settings);

  final _loaded = Completer<void>();

  void finish() => _loaded.complete();

  @override
  Future<ViewSettings> load() async {
    await _loaded.future;
    return settings;
  }
}

/// Opens the graph view as at app start, and gives the layouts it asked
/// for, in order.
Future<List<LayoutKind>> openGraph(
    WidgetTester tester, MemoryViewSettingsStore store) async {
  final kinds = <LayoutKind>[];
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => ViewSettingsHost(store: store, child: child!),
    home: GraphScreen(
      graph: ValueNotifier<RoamGraph>(graphOf(notes)),
      readNote: (path) async => notes[path],
      nodeMemory: MemoryNodeMemory('plan'),
      computeLayout: (graph, kind, centre) async {
        kinds.add(kind);
        return layoutGraph(graph, kind, centre: centre);
      },
      computeAlgorithms: algorithmsHere,
    ),
  ));
  await tester.pumpAndSettle();
  return kinds;
}

void main() {
  /// Opens the graph view without waiting for it to settle: while the
  /// settings load, a progress circle turns.
  Future<List<LayoutKind>> openSlow(
      WidgetTester tester, MemoryViewSettingsStore store) async {
    final kinds = <LayoutKind>[];
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) =>
          ViewSettingsHost(store: store, child: child!),
      home: GraphScreen(
        graph: ValueNotifier<RoamGraph>(graphOf(notes)),
        readNote: (path) async => notes[path],
        nodeMemory: MemoryNodeMemory('plan'),
        computeLayout: (graph, kind, centre) async {
          kinds.add(kind);
          return layoutGraph(graph, kind, centre: centre);
        },
        computeAlgorithms: algorithmsHere,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return kinds;
  }

  testWidgets('the saved start layout applies, also when it loads late (#81)',
      (tester) async {
    final store =
        SlowViewSettingsStore(const ViewSettings(startLayout: StartLayout.circo));
    final kinds = await openSlow(tester, store);
    // Nothing drawn with the defaults while the file is read.
    expect(kinds, isEmpty);
    store.finish();
    await tester.pumpAndSettle();
    expect(kinds, [LayoutKind.circo]);
  });

  testWidgets('a layout chosen before the settings loaded wins (#81)',
      (tester) async {
    final store = SlowViewSettingsStore(const ViewSettings(
        sectionsOnOpen: SectionsOnOpen.expanded,
        startLayout: StartLayout.force,
        lastLayout: LayoutKind.force));
    final kinds = await openSlow(tester, store);
    await tester.tap(find.byTooltip('View'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(LayoutKind.circo.label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    store.finish();
    await tester.pumpAndSettle();
    // The choice, not the saved start layout.
    expect(kinds, [LayoutKind.circo]);
    // Saved on top of the file, which keeps its other settings.
    expect(store.settings.lastLayout, LayoutKind.circo);
    expect(store.settings.sectionsOnOpen, SectionsOnOpen.expanded);
    expect(store.settings.startLayout, StartLayout.force);
  });

  testWidgets('a file that cannot be read in time does not stop the graph',
      (tester) async {
    final store =
        SlowViewSettingsStore(const ViewSettings(startLayout: StartLayout.circo));
    final kinds = await openSlow(tester, store);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(kinds, [LayoutKind.force]);
  });

  testWidgets('by default the graph starts force-directed', (tester) async {
    expect(await openGraph(tester, MemoryViewSettingsStore()),
        [LayoutKind.force]);
  });

  testWidgets('"Circular" starts with circo', (tester) async {
    final store = MemoryViewSettingsStore(
        const ViewSettings(startLayout: StartLayout.circo));
    expect(await openGraph(tester, store), [LayoutKind.circo]);
  });

  testWidgets('"Last used": the layout chosen in the menu, after a restart',
      (tester) async {
    final store = MemoryViewSettingsStore(
        const ViewSettings(startLayout: StartLayout.lastUsed));
    expect(await openGraph(tester, store), [LayoutKind.force]);
    await tester.tap(find.byTooltip('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LayoutKind.circo.label));
    await tester.pumpAndSettle();
    expect(store.settings.lastLayout, LayoutKind.circo);
    // A restart: a new graph view with the same stored settings.
    expect(await openGraph(tester, store), [LayoutKind.circo]);
  });

  testWidgets('"Radial" starts radial, and "Last used" remembers it (#153)',
      (tester) async {
    final store = MemoryViewSettingsStore(
        const ViewSettings(startLayout: StartLayout.radial));
    expect(await openGraph(tester, store), [LayoutKind.radial]);

    final last = MemoryViewSettingsStore(
        const ViewSettings(startLayout: StartLayout.lastUsed));
    expect(await openGraph(tester, last), [LayoutKind.force]);
    await tester.tap(find.byTooltip('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LayoutKind.radial.label));
    await tester.pumpAndSettle();
    expect(last.settings.lastLayout, LayoutKind.radial);
    expect(await openGraph(tester, last), [LayoutKind.radial]);
    final back = ViewSettings.fromJson(last.settings.toJson());
    expect(back.layoutAtStart, LayoutKind.radial);
  });

  testWidgets('the menu switches only the open graph with other settings',
      (tester) async {
    final store = MemoryViewSettingsStore();
    await openGraph(tester, store);
    await tester.tap(find.byTooltip('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LayoutKind.circo.label));
    await tester.pumpAndSettle();
    expect(await openGraph(tester, store), [LayoutKind.force]);
  });

  test('stored values: unknown ones fall back to the default', () {
    final back = ViewSettings.fromJson(const ViewSettings(
            startLayout: StartLayout.lastUsed, lastLayout: LayoutKind.circo)
        .toJson());
    expect(back.startLayout, StartLayout.lastUsed);
    expect(back.layoutAtStart, LayoutKind.circo);
    final odd =
        ViewSettings.fromJson({'startLayout': 'spiral', 'lastLayout': 'x'});
    expect(odd.startLayout, StartLayout.force);
    expect(odd.lastLayout, LayoutKind.force);
    expect(odd.layoutAtStart, LayoutKind.force);
  });

  testWidgets('Settings offers the four choices', (tester) async {
    final store = MemoryViewSettingsStore();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => ViewSettingsHost(store: store, child: child!),
      home: const SettingsScreen(),
    ));
    await tester.pumpAndSettle();
    final circo = find.byKey(const ValueKey('start-layout-circo'));
    await tester.scrollUntilVisible(circo, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(circo);
    await tester.pumpAndSettle();
    expect(store.settings.startLayout, StartLayout.circo);
    final radial = find.byKey(const ValueKey('start-layout-radial'));
    await tester.scrollUntilVisible(radial, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(radial);
    await tester.pumpAndSettle();
    expect(store.settings.startLayout, StartLayout.radial);
  });
}
