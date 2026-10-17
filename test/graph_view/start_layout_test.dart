import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/graph/graph_layout.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../ai/ai_visibility_test.dart' show graphOf, notes;
import 'graph_screen_test.dart' show MemoryNodeMemory, algorithmsHere;

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
      computeLayout: (graph, kind) async {
        kinds.add(kind);
        return layoutGraph(graph, kind);
      },
      computeAlgorithms: algorithmsHere,
    ),
  ));
  await tester.pumpAndSettle();
  return kinds;
}

void main() {
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
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LayoutKind.circo.label));
    await tester.pumpAndSettle();
    expect(store.settings.lastLayout, LayoutKind.circo);
    // A restart: a new graph view with the same stored settings.
    expect(await openGraph(tester, store), [LayoutKind.circo]);
  });

  testWidgets('the menu switches only the open graph with other settings',
      (tester) async {
    final store = MemoryViewSettingsStore();
    await openGraph(tester, store);
    await tester.tap(find.byTooltip('More'));
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

  testWidgets('Settings offers the three choices', (tester) async {
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
  });
}
