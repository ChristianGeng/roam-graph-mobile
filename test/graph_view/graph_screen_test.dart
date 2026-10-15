import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/graph_layout.dart';
import 'package:roam_graph_mobile/graph/graph_scope.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/graph_view/node_memory.dart';

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
  String? remembered,
}) async {
  final memory = MemoryNodeMemory(remembered);
  await tester.pumpWidget(MaterialApp(
    home: GraphScreen(
      graph: of ?? graph,
      nodeMemory: memory,
      computeLayout: layoutHere,
    ),
  ));
  await tester.pumpAndSettle();
  return memory;
}

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
    expect(find.text('HUB'), findsOneWidget);
    expect(find.text('hub.org'), findsOneWidget);
    expect(find.text('Links to 4 nodes, linked from 1 nodes in this view.'),
        findsOneWidget);
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
    expect(find.byType(BottomSheet), findsNothing);
    expect(memory.id, isNull);
  });

  testWidgets('the neighbourhood of an opened node', (tester) async {
    await show(tester, remembered: 'c');
    await tapMiddle(tester);
    await tester.tap(find.text('Show its neighbourhood'));
    await tester.pumpAndSettle();

    expect(find.text('Neighbourhood: 1 step'), findsOneWidget);
    // The title of the node it is around.
    expect(find.text('C'), findsOneWidget);
    // Still centred on c: hub and d are its neighbours.
    await tapMiddle(tester);
    expect(find.text('Links to 1 nodes, linked from 1 nodes in this view.'),
        findsOneWidget);
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
    await show(tester, remembered: 'b');
    await tester.tap(find.byTooltip('Layout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Force-directed'));
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(find.text('B'), findsOneWidget);

    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Layout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Circular (circo)'));
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('"Centre" returns to the centre node after panning',
      (tester) async {
    await show(tester, remembered: 'e');
    await tester.drag(find.byType(InteractiveViewer), const Offset(300, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Centre'));
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(find.text('E'), findsOneWidget);
  });

  testWidgets('a graph without nodes says so', (tester) async {
    await show(tester, of: graphOf([], []));
    expect(find.text('There are no nodes in roam/.'), findsOneWidget);
  });
}
