import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/search/search_screen.dart';

import '../graph_view/graph_screen_test.dart'
    show MemoryNodeMemory, algorithmsHere, layoutHere;
import 'ai_visibility_test.dart' show graphOf, notes;

/// Keeps the settings in memory.
class MemoryAiSettingsStore implements AiSettingsStore {
  MemoryAiSettingsStore([this.settings = const AiSettings()]);

  AiSettings settings;
  int saves = 0;

  @override
  Future<AiSettings> load() async => settings;

  @override
  Future<void> save(AiSettings settings) async {
    this.settings = settings;
    saves++;
  }
}

typedef Shared = List<(String, String?)>;

Future<void> pumpIn(WidgetTester tester, Widget home,
    {AiSettingsStore? store}) async {
  await tester.pumpWidget(AiSettingsHost(
    store: store ?? MemoryAiSettingsStore(),
    child: MaterialApp(home: home),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final graph = graphOf(notes);

  group('settings', () {
    test('read from JSON; missing or wrong values keep the defaults', () {
      expect(AiSettings.fromJson(null).hiddenTags, ['private']);
      expect(AiSettings.fromJson({'hiddenTags': 3}).hiddenTags, ['private']);
      expect(
          AiSettings.fromJson({
            'hiddenTags': ['a', 1, '', 'b'],
          }).hiddenTags,
          ['a', 'b']);
      // No tags at all is a choice: nothing hidden.
      expect(AiSettings.fromJson({'hiddenTags': []}).hiddenTags, isEmpty);
    });

    test('the file store saves and loads; a broken file gives defaults',
        () async {
      final dir = Directory.systemTemp.createTempSync('ai-settings');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileAiSettingsStore(path: '${dir.path}/ai-settings.json');
      expect((await store.load()).hiddenTags, ['private']);
      await store.save(const AiSettings(hiddenTags: ['secret', 'x']));
      expect((await store.load()).hiddenTags, ['secret', 'x']);
      File('${dir.path}/ai-settings.json').writeAsStringSync('{broken');
      expect((await store.load()).hiddenTags, ['private']);
    });

    testWidgets('the settings page changes and saves the hidden tags',
        (tester) async {
      final store = MemoryAiSettingsStore();
      await pumpIn(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Column(children: [
              Text('tags: ${AiSettingsScope.of(context).hiddenTags}'),
              TextButton(
                onPressed: () => AiSettingsScreen.open(context),
                child: const Text('open'),
              ),
            ]),
          ),
        ),
        store: store,
      );
      expect(find.text('tags: [private]'), findsOneWidget);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('private'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('hidden-tags')), 'private, secret :diary:');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.hiddenTags, ['private', 'secret', 'diary']);
      expect(store.saves, 1);
      expect(find.text('tags: [private, secret, diary]'), findsOneWidget);
    });
  });

  group('sharing respects the hidden tags', () {
    testWidgets('a hidden node is not shared from the node view',
        (tester) async {
      final shared = <String>[];
      await pumpIn(
        tester,
        NodeScreen(
          graph: ValueNotifier(graph),
          id: 'diary',
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory(),
          shareText: (text, {subject}) async => shared.add(text),
        ),
      );
      await tester.tap(find.byTooltip('Share with AI'));
      await tester.pump();
      expect(shared, isEmpty);
      expect(find.textContaining('hidden from AI by its tag :private:'),
          findsOneWidget);
    });

    testWidgets('a visible node is shared without its hidden parts',
        (tester) async {
      final shared = <String>[];
      await pumpIn(
        tester,
        NodeScreen(
          graph: ValueNotifier(graph),
          id: 'ideas',
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory(),
          shareText: (text, {subject}) async => shared.add(text),
        ),
      );
      await tester.tap(find.byTooltip('Share with AI'));
      await tester.pump();
      expect(shared.single, contains('Open text.'));
      expect(shared.single, isNot(contains('Salary')));
    });

    testWidgets('the settings decide: with no hidden tags, all is shared',
        (tester) async {
      final shared = <String>[];
      await pumpIn(
        tester,
        NodeScreen(
          graph: ValueNotifier(graph),
          id: 'diary',
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory(),
          shareText: (text, {subject}) async => shared.add(text),
        ),
        store: MemoryAiSettingsStore(const AiSettings(hiddenTags: [])),
      );
      await tester.tap(find.byTooltip('Share with AI'));
      await tester.pump();
      expect(shared.single, contains('## My diary'));
    });

    testWidgets('a selection in search leaves hidden nodes out',
        (tester) async {
      final shared = <String>[];
      await pumpIn(
        tester,
        SearchScreen(
          graph: ValueNotifier(graph),
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory(),
          shareText: (text, {subject}) async => shared.add(text),
        ),
      );
      await tester.longPress(find.text('My diary'));
      await tester.pump();
      await tester.tap(find.text('Plan'));
      await tester.pump();
      await tester.tap(find.byTooltip('Share with AI'));
      await tester.pump();
      expect(shared.single, startsWith('# A note from my org-roam graph'));
      expect(shared.single, contains('## Plan'));
      expect(shared.single, isNot(contains('## My diary')));
      expect(find.text('1 selected note is hidden from AI by its tags and '
          'was left out.'), findsOneWidget);
    });

    testWidgets('only hidden nodes selected: nothing is shared',
        (tester) async {
      final shared = <String>[];
      await pumpIn(
        tester,
        SearchScreen(
          graph: ValueNotifier(graph),
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory(),
          shareText: (text, {subject}) async => shared.add(text),
        ),
      );
      await tester.longPress(find.text('My diary'));
      await tester.pump();
      await tester.tap(find.byTooltip('Share with AI'));
      await tester.pump();
      expect(shared, isEmpty);
      expect(find.textContaining('hidden from AI'), findsOneWidget);
    });

    testWidgets('the graph share leaves hidden nodes out; More opens the '
        'settings', (tester) async {
      final shared = <String>[];
      await pumpIn(
        tester,
        GraphScreen(
          graph: ValueNotifier<RoamGraph>(graph),
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory('plan'),
          computeLayout: layoutHere,
          computeAlgorithms: algorithmsHere,
          shareText: (text, {subject}) async => shared.add(text),
        ),
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share graph with AI'));
      await tester.pumpAndSettle();
      expect(shared.single, contains('2 notes are hidden from AI'));
      expect(shared.single, isNot(contains('My diary')));

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI settings'));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsScreen), findsOneWidget);
    });
  });
}
