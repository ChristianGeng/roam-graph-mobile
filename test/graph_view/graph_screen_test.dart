import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/graph_algorithms.dart';
import 'package:roam_graph_mobile/graph/graph_layout.dart';
import 'package:roam_graph_mobile/graph/graph_scope.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';
import 'package:roam_graph_mobile/graph_view/node_memory.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph/graph_scope_test.dart' show graphOf;

/// A [NodeMemory] in memory.
class MemoryNodeMemory implements NodeMemory {
  MemoryNodeMemory([this.id]);

  String? id;

  @override
  Future<String?> lastNode() async => id;

  @override
  Future<void> remember(String id) async => this.id = id;
}

/// A phone, held upright: one screen at a time (#16).
const phoneScreen = Size(412, 915);

/// The graph views' results on this isolate.
Future<AlgorithmResults> algorithmsHere(AlgorithmGraph graph) async =>
    computeAlgorithmResults(graph);

/// The layout on this isolate: tests cannot wait for another one.
Future<GraphLayout> layoutHere(DrawnGraph graph, LayoutKind kind) async =>
    layoutGraph(graph, kind);

/// hub links to six nodes; c links to d; lonely has no links.
final graph = graphOf(
  ['hub', 'a', 'b', 'c', 'd', 'e', 'f', 'lonely'],
  ['hub>a', 'hub>b', 'hub>c', 'hub>e', 'f>hub', 'a>b', 'c>d'],
);

Future<MemoryNodeMemory> show(
  WidgetTester tester, {
  RoamGraph? of,
  ValueNotifier<RoamGraph>? notifier,
  String? remembered,
  Size screen = phoneScreen,
  AlgorithmsFunction? computeAlgorithms,
  LayoutFunction? computeLayout,
}) async {
  // The default test screen, 800 x 600, is a tablet in landscape (#16).
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = screen;
  addTearDown(tester.view.reset);
  final memory = MemoryNodeMemory(remembered);
  await tester.pumpWidget(MaterialApp(
    // These tests were written for the circular layout, which was the start
    // layout before #71.
    builder: (context, child) => ViewSettingsHost(
      store: MemoryViewSettingsStore(
          const ViewSettings(startLayout: StartLayout.circo)),
      child: child!,
    ),
    home: GraphScreen(
      graph: notifier ?? ValueNotifier(of ?? graph),
      // Every note has the text "Text of <id>."
      readNote: (path) async => 'Text of ${path.replaceAll('.org', '')}.',
      nodeMemory: memory,
      computeLayout: computeLayout ?? layoutHere,
      computeAlgorithms: computeAlgorithms ?? algorithmsHere,
    ),
  ));
  await tester.pumpAndSettle();
  return memory;
}

/// The title of the node view, in its app bar.
Finder nodeTitle(String text) => find.descendant(
    of: find.byType(NodeScreen), matching: find.text(text));

/// Taps the middle of the graph, where the centre node is.
Future<void> tapMiddle(WidgetTester tester) async {
  await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starts with the whole graph, on the node with most links',
      (tester) async {
    await show(tester);
    expect(find.text('Whole graph'), findsOneWidget);

    await tapMiddle(tester);
    expect(nodeTitle('HUB'), findsOneWidget);
    expect(find.textContaining('Text of hub.', findRichText: true),
        findsOneWidget);
    // f links to hub.
    expect(find.text('Backlinks: 1'), findsOneWidget);
  });

  testWidgets('starts on the node opened last', (tester) async {
    await show(tester, remembered: 'd');
    await tapMiddle(tester);
    expect(find.text('D'), findsOneWidget);
  });

  testWidgets('a node opened last that is gone is ignored', (tester) async {
    await show(tester, remembered: 'deleted');
    await tapMiddle(tester);
    expect(find.text('HUB'), findsOneWidget);
  });

  testWidgets('a tap on a node opens it and remembers it', (tester) async {
    final memory = await show(tester, remembered: 'c');
    memory.id = null;
    await tapMiddle(tester);
    expect(find.text('C'), findsOneWidget);
    expect(memory.id, 'c');
  });

  testWidgets('a tap beside the nodes opens nothing', (tester) async {
    final memory = await show(tester, remembered: 'c');
    memory.id = null;
    // The top left corner of the graph: the margin, never a node.
    await tester.tapAt(
        tester.getTopLeft(find.byType(InteractiveViewer)) + const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(NodeScreen), findsNothing);
    expect(memory.id, isNull);
  });

  testWidgets('"Show in graph" returns to the graph, centred on the node',
      (tester) async {
    final memory = await show(tester, remembered: 'hub');
    await tapMiddle(tester);
    // From hub to its backlink f, then back to the graph.
    await tester.tap(find.text('F'));
    await tester.pumpAndSettle();
    expect(nodeTitle('F'), findsOneWidget);
    expect(memory.id, 'f');
    await tester.tap(find.byTooltip('Show in graph'));
    await tester.pumpAndSettle();

    expect(find.byType(NodeScreen), findsNothing);
    expect(find.text('Whole graph'), findsOneWidget);
    await tapMiddle(tester);
    expect(nodeTitle('F'), findsOneWidget);
  });

  testWidgets('search, then "Show in graph", centres the graph on the node',
      (tester) async {
    await show(tester, remembered: 'hub');
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'd');
    await tester.pump();
    // d is one of the results: show it in the graph.
    final tile = find.ancestor(
        of: find.text('D'), matching: find.byType(ListTile));
    await tester.tap(
        find.descendant(of: tile, matching: find.byTooltip('Show in graph')));
    await tester.pumpAndSettle();

    expect(find.text('Whole graph'), findsOneWidget);
    await tapMiddle(tester);
    expect(nodeTitle('D'), findsOneWidget);
  });

  testWidgets('search from the node view, and on to the graph',
      (tester) async {
    await show(tester, remembered: 'hub');
    await tapMiddle(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'lonely');
    await tester.pump();
    await tester.tap(find.byTooltip('Show in graph').last);
    await tester.pumpAndSettle();

    expect(find.byType(NodeScreen), findsNothing);
    await tapMiddle(tester);
    expect(nodeTitle('LONELY'), findsOneWidget);
  });

  testWidgets('"Show in graph" draws a neighbourhood around the node',
      (tester) async {
    await show(tester, remembered: 'hub');
    await tester.tap(find.byTooltip('Show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neighbourhood: 1 step'));
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    await tester.tap(find.text('F'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show in graph'));
    await tester.pumpAndSettle();

    expect(find.text('Neighbourhood: 1 step'), findsOneWidget);
    // The title of the node it is around.
    expect(find.text('F'), findsOneWidget);
    await tapMiddle(tester);
    expect(nodeTitle('F'), findsOneWidget);
  });

  testWidgets('the menu shows other parts around the centre node',
      (tester) async {
    await show(tester, remembered: 'c');
    await tester.tap(find.byTooltip('Show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neighbourhood: 2 steps'));
    await tester.pumpAndSettle();
    expect(find.text('Neighbourhood: 2 steps'), findsOneWidget);

    await tester.tap(find.byTooltip('Show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connected part').last);
    await tester.pumpAndSettle();
    expect(find.text('Connected part'), findsOneWidget);
    await tapMiddle(tester);
    expect(find.text('C'), findsWidgets);
  });

  testWidgets('both layouts, each centred on the node', (tester) async {
    final kinds = <LayoutKind>[];
    // Large enough for every node; upright, so one screen at a time.
    await show(tester, remembered: 'b', screen: const Size(1200, 1600),
        computeLayout: (graph, kind) {
      kinds.add(kind);
      return layoutHere(graph, kind);
    });
    expect(kinds, [LayoutKind.circo]);

    // Where hub is in each layout, seen from b in the middle.
    final whole = DrawnGraph.of(graph, const WholeGraph());
    Offset hubFromB(LayoutKind kind) {
      final layout = layoutGraph(whole, kind);
      final b = layout.positions['b']!, hub = layout.positions['hub']!;
      return Offset(hub.x - b.x, hub.y - b.y);
    }

    final circo = hubFromB(LayoutKind.circo),
        force = hubFromB(LayoutKind.force);
    // Far enough apart that a tap at one cannot reach hub in the other.
    expect((circo - force).distance, greaterThan(3 * tapReach(1)));

    Future<void> tapAt(Offset at) async {
      await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)) + at);
      await tester.pumpAndSettle();
    }

    Future<void> choose(String label) async {
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await choose('Force-directed');
    // A new drawing, not only a new check mark.
    expect(kinds, [LayoutKind.circo, LayoutKind.force]);
    await tapMiddle(tester);
    expect(nodeTitle('B'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tapAt(force);
    expect(nodeTitle('HUB'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Opening hub made it the centre node, so the circular layout, drawn
    // again from the layouts kept, is centred on hub, and b is the other
    // way round.
    await choose('Circular (circo)');
    await tapMiddle(tester);
    expect(nodeTitle('HUB'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tapAt(-circo);
    expect(nodeTitle('B'), findsOneWidget);
  });

  group('the View menu: layouts and views (#143)', () {
    /// The checked items of the open menu, by their labels.
    Map<String, bool> checks(WidgetTester tester) => {
          for (final item in tester.widgetList<CheckedPopupMenuItem<Object>>(
              find.byWidgetPredicate((w) => w is CheckedPopupMenuItem<Object>)))
            (item.child! as Text).data!: item.checked,
        };

    testWidgets('both groups, with headings and the current item checked',
        (tester) async {
      await show(tester, remembered: 'hub');
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      expect(find.text('Layout'), findsOneWidget);
      expect(find.text('View'), findsOneWidget);
      // The tests start with the circular layout (see show).
      expect(checks(tester), {
        'Circular (circo)': true,
        'Force-directed': false,
        'Plain': true,
        'Communities': false,
        'Importance: PageRank': false,
        'Importance: number of links': false,
        'Shortest path': false,
      });
      expect(find.text('About the layouts'), findsOneWidget);
      expect(find.text('About the views'), findsOneWidget);
      // A heading is not a choice: tapping it keeps the menu open.
      await tester.tap(find.text('Layout'));
      await tester.pumpAndSettle();
      expect(find.text('Force-directed'), findsOneWidget);
      expect(checks(tester)['Circular (circo)'], isTrue);
    });

    testWidgets('the checks follow the choices', (tester) async {
      await show(tester, remembered: 'hub');
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Force-directed'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Communities'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      final now = checks(tester);
      expect(now['Force-directed'], isTrue);
      expect(now['Circular (circo)'], isFalse);
      expect(now['Communities'], isTrue);
      expect(now['Plain'], isFalse);
    });

    testWidgets('the More menu has no layouts any more', (tester) async {
      await show(tester, remembered: 'hub');
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      for (final label in ['Centre', 'Ask AI', 'Settings', 'Help']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final kind in LayoutKind.values) {
        expect(find.text(kind.label), findsNothing, reason: kind.label);
      }
      expect(find.text('About the layouts'), findsNothing);
    });
  });

  testWidgets('"Centre" returns to the centre node after panning',
      (tester) async {
    await show(tester, remembered: 'e');
    await tester.drag(find.byType(InteractiveViewer), const Offset(300, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Centre'));
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(find.text('E'), findsOneWidget);
  });

  test('a tap reaches the dot plus 16 pixels on the screen', () {
    expect(tapReach(1), 23);
    // Zoomed out, 16 screen pixels are many graph pixels...
    expect(tapReach(0.1), closeTo(167, 0.001));
    // ...zoomed in, few: 11 graph pixels are 44 on the screen.
    expect(tapReach(4), 11);
  });

  testWidgets('a new graph from the index is drawn', (tester) async {
    final notifier = ValueNotifier(graph);
    await show(tester, notifier: notifier, remembered: 'c');

    // Syncthing brought a note that links to c.
    notifier.value = graphOf(
      ['hub', 'a', 'b', 'c', 'd', 'e', 'f', 'lonely', 'new'],
      ['hub>a', 'hub>b', 'hub>c', 'hub>e', 'f>hub', 'a>b', 'c>d', 'new>c'],
    );
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(nodeTitle('C'), findsOneWidget);
    // From hub and from the new note.
    expect(find.text('Backlinks: 2'), findsOneWidget);
  });

  testWidgets('the same graph again keeps the view', (tester) async {
    final notifier = ValueNotifier(graph);
    await show(tester, notifier: notifier, remembered: 'c');
    await tester.drag(find.byType(InteractiveViewer), const Offset(300, 200));
    await tester.pumpAndSettle();

    // A scan that found nothing new gives an equal graph.
    notifier.value = graphOf(
      ['hub', 'a', 'b', 'c', 'd', 'e', 'f', 'lonely'],
      ['hub>a', 'hub>b', 'hub>c', 'hub>e', 'f>hub', 'a>b', 'c>d'],
    );
    await tester.pumpAndSettle();
    // Not centred again: the middle is still empty after the drag.
    await tapMiddle(tester);
    expect(find.byType(NodeScreen), findsNothing);
  });

  testWidgets('when the centre node is deleted, the graph moves to another',
      (tester) async {
    final notifier = ValueNotifier(graph);
    await show(tester, notifier: notifier, remembered: 'd');

    notifier.value = graphOf(
      ['hub', 'a', 'b', 'c'],
      ['hub>a', 'hub>b', 'hub>c'],
    );
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(find.text('HUB'), findsOneWidget);
  });

  group('graph views (#7)', () {
    /// Taps the node [id] of the whole graph in the circular layout, with
    /// the view centred on [centre] at scale 1.
    Future<void> tapNode(WidgetTester tester, String centre, String id) async {
      final layout =
          layoutGraph(DrawnGraph.of(graph, const WholeGraph()), LayoutKind.circo);
      final from = layout.positions[centre]!, to = layout.positions[id]!;
      await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)) +
          Offset(to.x - from.x, to.y - from.y));
      await tester.pumpAndSettle();
    }

    Future<void> chooseView(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    String? note(WidgetTester tester) {
      final finder = find.byKey(const ValueKey('view-note'));
      return finder.evaluate().isEmpty ? null : tester.widget<Text>(finder).data;
    }

    testWidgets('communities, as many as Louvain finds', (tester) async {
      await show(tester, remembered: 'hub');
      expect(note(tester), isNull);
      await chooseView(tester, 'Communities');
      final count = louvainCommunities(AlgorithmGraph.fromRoam(graph))
          .values
          .toSet()
          .length;
      expect(note(tester), startsWith('$count communities (Louvain).'));

      await chooseView(tester, 'Plain');
      expect(note(tester), isNull);
    });

    testWidgets('importance by PageRank and by links', (tester) async {
      await show(tester, remembered: 'hub');
      await chooseView(tester, 'Importance: PageRank');
      expect(note(tester), 'Larger nodes have a higher PageRank.');
      await chooseView(tester, 'Importance: number of links');
      expect(note(tester), 'Larger nodes have more links, to and from them.');
      // Taps still open nodes.
      await tapMiddle(tester);
      expect(nodeTitle('HUB'), findsOneWidget);
    });

    testWidgets('a shortest path from the selected node to a tapped one',
        (tester) async {
      // Large enough for every node; upright, so one screen at a time.
      await show(tester, remembered: 'hub', screen: const Size(1200, 1600));
      await chooseView(tester, 'Shortest path');
      expect(note(tester), 'Path from HUB: tap the node it leads to.');

      // hub -> c -> d.
      await tapNode(tester, 'hub', 'd');
      expect(note(tester), 'HUB to D: 2 links.');
      // The tap chose the target; it opened nothing.
      expect(find.byType(NodeScreen), findsNothing);

      // f links to hub, not the other way.
      await tapNode(tester, 'hub', 'f');
      expect(note(tester),
          'No path from HUB to F within 8 links, following links in their '
          'direction.');
    });
  });

  group('graph views, details (#7)', () {
    Future<void> chooseView(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    String? note(WidgetTester tester) {
      final finder = find.byKey(const ValueKey('view-note'));
      return finder.evaluate().isEmpty ? null : tester.widget<Text>(finder).data;
    }

    testWidgets('results computed elsewhere: "Computing…" until they arrive',
        (tester) async {
      final pending = Completer<AlgorithmResults>();
      await show(tester,
          remembered: 'hub', computeAlgorithms: (_) => pending.future);
      await chooseView(tester, 'Communities');
      expect(note(tester), 'Computing…');

      pending.complete(computeAlgorithmResults(AlgorithmGraph.fromRoam(graph)));
      await tester.pumpAndSettle();
      expect(note(tester), contains('communities (Louvain)'));
    });

    testWidgets('a path that leaves the drawn neighbourhood says so',
        (tester) async {
      // a -> c -> d -> b -> a: a's one-step neighbourhood draws a, c and b,
      // not d, on the way from a to b.
      final ring = graphOf(['a', 'b', 'c', 'd'], ['a>c', 'c>d', 'd>b', 'b>a']);
      await show(tester,
          of: ring, remembered: 'a', screen: const Size(1200, 1600));
      await tester.tap(find.byTooltip('Show'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Neighbourhood: 1 step'));
      await tester.pumpAndSettle();
      await chooseView(tester, 'Shortest path');

      final layout = layoutGraph(
          DrawnGraph.of(ring, const Neighbourhood('a', 1)), LayoutKind.circo);
      final a = layout.positions['a']!, b = layout.positions['b']!;
      final scale = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)) +
          Offset(b.x - a.x, b.y - a.y) * scale);
      await tester.pumpAndSettle();
      expect(
          note(tester),
          'A to B: 3 links. Part of it is outside this part of the graph; '
          'show the whole graph to see all of it.');
    });

    testWidgets('a new graph from the index gives a new path', (tester) async {
      // a -> b directly; then the index drops that link: a -> c -> b.
      final notifier =
          ValueNotifier(graphOf(['a', 'b', 'c'], ['a>b', 'a>c', 'c>b']));
      await show(tester,
          notifier: notifier, remembered: 'a', screen: const Size(1200, 1600));
      await chooseView(tester, 'Shortest path');
      final layout = layoutGraph(
          DrawnGraph.of(notifier.value, const WholeGraph()), LayoutKind.circo);
      final a = layout.positions['a']!, b = layout.positions['b']!;
      await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)) +
          Offset(b.x - a.x, b.y - a.y));
      await tester.pumpAndSettle();
      expect(note(tester), 'A to B: 1 link.');

      notifier.value = graphOf(['a', 'b', 'c'], ['a>c', 'c>b']);
      await tester.pumpAndSettle();
      expect(note(tester), 'A to B: 2 links.');
    });

    testWidgets('an enlarged dot opens on all of its area', (tester) async {
      await show(tester, remembered: 'hub');
      await chooseView(tester, 'Importance: number of links');
      // hub has the most links: three times the plain radius of 7. 30
      // pixels from its centre is on the dot, beyond the plain reach.
      await tester.tapAt(
          tester.getCenter(find.byType(InteractiveViewer)) +
              const Offset(30, 0));
      await tester.pumpAndSettle();
      expect(nodeTitle('HUB'), findsOneWidget);
    });
  });

  testWidgets('"Settings" in the More menu opens the settings (#63)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: GraphScreen(
        graph: ValueNotifier(graph),
        readNote: (path) async => '',
        nodeMemory: MemoryNodeMemory('hub'),
        computeLayout: layoutHere,
        computeAlgorithms: algorithmsHere,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Sections when a note opens'), findsOneWidget);
  });

  testWidgets('the bar fits a phone of 360 points', (tester) async {
    // A node selected adds "Open node"; nothing overflows.
    await show(tester, remembered: 'hub', screen: const Size(360, 780));
    expect(tester.takeException(), isNull);
    final bar = tester.getRect(find.byType(AppBar).first);
    for (final tooltip in ['Search', 'Open node', 'Show', 'View', 'More']) {
      final button = tester.getRect(find.byTooltip(tooltip).first);
      expect(bar.contains(button.center), isTrue, reason: tooltip);
    }
  });

  testWidgets('a graph without nodes says so', (tester) async {
    await show(tester, of: graphOf([], []));
    expect(find.text('There are no nodes in roam/.'), findsOneWidget);
  });
}
