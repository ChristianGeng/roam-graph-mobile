import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/graph_view/two_panes.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../ai/ai_visibility_test.dart' show graphOf, notes;
import 'graph_screen_test.dart'
    show MemoryNodeMemory, algorithmsHere, layoutHere;

/// The graph's width on screen.
double graphWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('pane-divider'))).width > 0
        ? tester.getTopLeft(find.byKey(const ValueKey('pane-divider'))).dx
        : 0;

Future<MemoryViewSettingsStore> pumpTablet(WidgetTester tester,
    {ViewSettings settings = const ViewSettings(),
    Size size = const Size(1000, 700)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = MemoryViewSettingsStore(settings);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => ViewSettingsHost(store: store, child: child!),
    home: GraphScreen(
      graph: ValueNotifier<RoamGraph>(graphOf(notes)),
      readNote: (path) async => notes[path],
      nodeMemory: MemoryNodeMemory('plan'),
      computeLayout: layoutHere,
      computeAlgorithms: algorithmsHere,
    ),
  ));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('the default: graph 40 %, note 60 %', (tester) async {
    await pumpTablet(tester);
    expect(graphWidth(tester), 400);
  });

  testWidgets('dragging changes the share, within the minimums',
      (tester) async {
    final store = await pumpTablet(tester);
    final divider = find.byKey(const ValueKey('pane-divider'));
    await tester.drag(divider, const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(graphWidth(tester), closeTo(500, 1));
    expect(store.settings.graphShare, closeTo(0.5, 0.002));
    // The note keeps 320: the graph is at most 1000 - 320 - 24.
    await tester.drag(divider, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(graphWidth(tester), closeTo(656, 1));
    // The graph keeps 240 unless dragged far enough to fold.
    await tester.drag(divider, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(graphWidth(tester), closeTo(240, 1));
    expect(store.settings.graphCollapsed, isFalse);
  });

  testWidgets('folding and unfolding restore the share', (tester) async {
    final store = await pumpTablet(tester,
        settings: const ViewSettings(graphShare: 0.3));
    expect(graphWidth(tester), closeTo(300, 1));
    await tester.tap(find.byTooltip('Fold graph'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-strip')), findsOneWidget);
    expect(graphWidth(tester), TwoPanes.strip);
    expect(store.settings.graphCollapsed, isTrue);
    expect(store.settings.graphShare, 0.3);
    await tester.tap(find.byTooltip('Show graph'));
    await tester.pumpAndSettle();
    expect(graphWidth(tester), closeTo(300, 1));
    expect(store.settings.graphCollapsed, isFalse);
  });

  testWidgets('dragging all the way left folds the graph', (tester) async {
    final store = await pumpTablet(tester);
    await tester.drag(
        find.byKey(const ValueKey('pane-divider')), const Offset(-380, 0));
    await tester.pumpAndSettle();
    expect(store.settings.graphCollapsed, isTrue);
    expect(store.settings.graphShare, 0.4);
    expect(find.byKey(const ValueKey('graph-strip')), findsOneWidget);
  });

  testWidgets('the saved layout comes back; a double tap resets it',
      (tester) async {
    final store = await pumpTablet(tester,
        settings: const ViewSettings(graphShare: 0.55));
    expect(graphWidth(tester), closeTo(550, 1));
    final divider = find.byKey(const ValueKey('pane-divider'));
    await tester.tap(divider);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(divider);
    await tester.pumpAndSettle();
    expect(store.settings.graphShare, ViewSettings.defaultGraphShare);
    expect(graphWidth(tester), 400);
  });

  testWidgets('on a phone there is no divider', (tester) async {
    await pumpTablet(tester, size: const Size(400, 800));
    expect(find.byKey(const ValueKey('pane-divider')), findsNothing);
    await pumpTablet(tester, size: const Size(800, 1000));
    expect(find.byKey(const ValueKey('pane-divider')), findsNothing);
  });

  testWidgets('Settings shows the width and resets it', (tester) async {
    final store = MemoryViewSettingsStore(
        const ViewSettings(graphShare: 0.7, graphCollapsed: true));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => ViewSettingsHost(store: store, child: child!),
      home: const SettingsScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('folded away'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-graph-width-reset')));
    await tester.pumpAndSettle();
    expect(store.settings.graphShare, ViewSettings.defaultGraphShare);
    expect(store.settings.graphCollapsed, isFalse);
    expect(find.text('Graph 40 %, note 60 %. Drag the divider between them '
        'to change it.'), findsOneWidget);
  });
}
