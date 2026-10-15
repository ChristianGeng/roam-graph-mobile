import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/graph_layout.dart';
import 'package:roam_graph_mobile/graph/graph_scope.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
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
}) async {
  final memory = MemoryNodeMemory(remembered);
  await tester.pumpWidget(MaterialApp(
    home: GraphScreen(
      graph: notifier ?? ValueNotifier(of ?? graph),
      // Every note has the text "Text of <id>."
      readNote: (path) async => 'Text of ${path.replaceAll('.org', '')}.',
      nodeMemory: memory,
      computeLayout: layoutHere,
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
    await show(tester, remembered: 'b');
    await tester.tap(find.byTooltip('Layout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Force-directed'));
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(nodeTitle('B'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Layout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Circular (circo)'));
    await tester.pumpAndSettle();
    await tapMiddle(tester);
    expect(nodeTitle('B'), findsOneWidget);
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

  testWidgets('a graph without nodes says so', (tester) async {
    await show(tester, of: graphOf([], []));
    expect(find.text('There are no nodes in roam/.'), findsOneWidget);
  });
}
