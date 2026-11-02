import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../graph/graph_scope_test.dart' show graphOf;
import 'graph_screen_test.dart'
    show MemoryNodeMemory, algorithmsHere, graph, layoutHere;

void main() {
  late StreamController<String> emacs;
  late MemoryNodeMemory memory;
  late ValueNotifier<RoamGraph> notifier;

  setUp(() {
    emacs = StreamController<String>.broadcast();
    memory = MemoryNodeMemory('hub');
    notifier = ValueNotifier(graph);
  });
  tearDown(() => emacs.close());

  /// The default test screen, 800 x 600: graph and note side by side.
  Future<void> show(
    WidgetTester tester, {
    ViewSettings settings = const ViewSettings(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ViewSettingsHost(
          store: MemoryViewSettingsStore(settings),
          child: child!,
        ),
        home: GraphScreen(
          graph: notifier,
          readNote: (path) async => 'Text of ${path.replaceAll('.org', '')}.',
          nodeMemory: memory,
          computeLayout: layoutHere,
          computeAlgorithms: algorithmsHere,
          followRequests: emacs.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fromEmacs(WidgetTester tester, String id) async {
    emacs.add(id);
    await tester.pumpAndSettle();
  }

  testWidgets('the node at point in Emacs is shown beside the graph (#117)', (
    tester,
  ) async {
    await show(tester);
    expect(find.textContaining('Text of hub.'), findsOneWidget);
    await fromEmacs(tester, 'c');
    expect(find.textContaining('Text of c.'), findsOneWidget);
    expect(memory.id, 'c');
  });

  testWidgets('an unknown ID is shown once the index has it', (tester) async {
    await show(tester);
    await fromEmacs(tester, 'new');
    expect(find.textContaining('Text of hub.'), findsOneWidget);
    expect(memory.id, 'hub');
    notifier.value = graphOf(
      ['hub', 'a', 'b', 'c', 'd', 'e', 'f', 'lonely', 'new'],
      ['hub>a', 'hub>b', 'hub>c', 'hub>e', 'f>hub', 'a>b', 'c>d', 'new>hub'],
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Text of new.'), findsOneWidget);
    expect(memory.id, 'new');
  });

  testWidgets('with following off, nothing changes', (tester) async {
    await show(tester, settings: const ViewSettings(followEmacs: false));
    await fromEmacs(tester, 'c');
    expect(find.textContaining('Text of hub.'), findsOneWidget);
    expect(memory.id, 'hub');
  });

  testWidgets('a page open on top of the graph is not taken away', (
    tester,
  ) async {
    await show(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Another page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await fromEmacs(tester, 'c');
    expect(find.text('Another page'), findsOneWidget);
    expect(memory.id, 'hub');
  });

  test('the setting is kept, and on by default', () {
    expect(const ViewSettings().followEmacs, isTrue);
    final off = const ViewSettings().copyWith(followEmacs: false);
    expect(ViewSettings.fromJson(off.toJson()).followEmacs, isFalse);
    expect(ViewSettings.fromJson({'followEmacs': 'no'}).followEmacs, isTrue);
  });
}
