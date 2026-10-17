import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/search/search_screen.dart';

import '../node_view/node_screen_test.dart' show shareNodeWithAi;
import '../graph_view/graph_screen_test.dart'
    show MemoryNodeMemory, algorithmsHere, layoutHere;
import 'ai_visibility_test.dart' show graphOf, notes;

/// Keeps the settings in memory. With [loading], the load waits for it;
/// with [failSave], saving fails.
class MemoryAiSettingsStore implements AiSettingsStore {
  MemoryAiSettingsStore([this.settings = const AiSettings()]);

  AiSettings settings;
  int saves = 0;
  Completer<void>? loading;
  bool failSave = false;

  @override
  Future<AiSettings> load() async {
    await loading?.future;
    return settings;
  }

  @override
  Future<void> save(AiSettings settings) async {
    if (failSave) throw const FileSystemException('disk full');
    this.settings = settings;
    saves++;
  }
}

typedef Shared = List<(String, String?)>;

/// Scrolls the settings page until [finder] is built and on screen.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

/// API keys in memory.
class MemoryKeyStore implements ApiKeyStore {
  final keys = <String, String>{};

  @override
  Future<String?> read(String provider) async => keys[provider];

  @override
  Future<void> write(String provider, String key) async =>
      key.isEmpty ? keys.remove(provider) : keys[provider] = key;
}

Future<void> pumpIn(WidgetTester tester, Widget home,
    {AiSettingsStore? store, ApiKeyStore? keys}) async {
  await tester.pumpWidget(AiSettingsHost(
    store: store ?? MemoryAiSettingsStore(),
    keys: keys ?? MemoryKeyStore(),
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

  group('the saved settings are loaded first (#61 review)', () {
    testWidgets('a share waits for the saved tags', (tester) async {
      final store = MemoryAiSettingsStore(const AiSettings(hiddenTags: []))
        ..loading = Completer();
      final shared = <String>[];
      await tester.pumpWidget(AiSettingsHost(
        store: store,
        child: MaterialApp(
          home: NodeScreen(
            graph: ValueNotifier(graph),
            id: 'diary',
            readNote: (path) async => notes[path],
            nodeMemory: MemoryNodeMemory(),
            shareText: (text, {subject}) async => shared.add(text),
          ),
        ),
      ));
      await tester.pump();
      await shareNodeWithAi(tester);
      await tester.pump();
      // The defaults would hide the note, the saved settings do not: the
      // share waits for them.
      expect(shared, isEmpty);
      expect(find.textContaining('hidden from AI'), findsNothing);
      store.loading!.complete();
      await tester.pumpAndSettle();
      expect(shared.single, contains('## My diary'));
    });

    testWidgets('the page shows the saved tags, not the defaults first',
        (tester) async {
      final store =
          MemoryAiSettingsStore(const AiSettings(hiddenTags: ['secret']))
            ..loading = Completer();
      await pumpIn(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => AiSettingsScreen.open(context),
            child: const Text('open'),
          ),
        ),
        store: store,
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('hidden-tags')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      store.loading!.complete();
      await tester.pumpAndSettle();
      expect(find.text('secret'), findsOneWidget);
    });

    testWidgets('a failed save keeps the tags in use', (tester) async {
      final store = MemoryAiSettingsStore()..failSave = true;
      late BuildContext inside;
      await pumpIn(
        tester,
        Builder(builder: (context) {
          inside = context;
          return TextButton(
            onPressed: () => AiSettingsScreen.open(context),
            child: Text('tags: ${AiSettingsScope.of(context).hiddenTags}'),
          );
        }),
        store: store,
      );
      await tester.tap(find.text('tags: [private]'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('hidden-tags')), '');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save the settings'), findsOneWidget);
      expect((await AiSettingsScope.current(inside)).hiddenTags, ['private']);
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
      await shareNodeWithAi(tester);
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
      await shareNodeWithAi(tester);
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
      await shareNodeWithAi(tester);
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
      // The AI settings are under Settings (#63's page).
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('settings-ai')), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-ai')));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsScreen), findsOneWidget);
    });
  });

  test('how the AI may change notes: agent by default, saved (#82)', () {
    expect(const AiSettings().editMode, AiEditMode.agent);
    expect(const AiSettings().maxAgentChanges, 30);
    const settings =
        AiSettings(editMode: AiEditMode.review, maxAgentChanges: 5);
    final back = AiSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
    expect(back.editMode, AiEditMode.review);
    expect(back.maxAgentChanges, 5);
    expect(AiSettings.fromJson({'editMode': 'gone'}).editMode, AiEditMode.agent);
  });

  group('providers (#59)', () {
    test('saved provider values come back; unknown ones keep defaults', () {
      final settings = AiSettings(
        provider: 'mistral',
        providers: {
          'mistral': ProviderSettings.of(presetById('mistral')),
          'custom': const ProviderSettings(
              api: ApiKind.anthropic,
              baseUrl: 'http://192.168.1.5:11434',
              defaultModel: 'local',
              strongModel: ''),
        },
        maxToolRounds: 4,
        maxOutputTokens: 2000,
      );
      final back = AiSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
      expect(back.provider, 'mistral');
      expect(back.providerSettings().defaultModel, 'mistral-large-4');
      expect(back.providerSettings('custom').api, ApiKind.anthropic);
      expect(back.providerSettings('custom').baseUrl, 'http://192.168.1.5:11434');
      expect(back.maxToolRounds, 4);
      expect(back.maxOutputTokens, 2000);
      // Only Custom can change the API; a preset keeps its own.
      final odd = AiSettings.fromJson({
        'provider': 'gone',
        'providers': {
          'mistral': {'api': 'anthropic'},
        },
        'maxToolRounds': -1,
      });
      expect(odd.provider, 'anthropic');
      expect(odd.providerSettings('mistral').api, ApiKind.openAi);
      expect(odd.maxToolRounds, 10);
    });

    test('the config takes the key, and the strong model on request',
        () async {
      final keys = MemoryKeyStore()..keys['anthropic'] = 'sk';
      const settings = AiSettings();
      final normal = await providerConfig(settings, keys);
      expect(normal.model, 'claude-sonnet-5-5');
      expect(normal.apiKey, 'sk');
      expect(normal.maxOutputTokens, 8192);
      expect((await providerConfig(settings, keys, strong: true)).model,
          'claude-opus-5-5');
      final mistral = await providerConfig(
          settings.copyWith(provider: 'mistral'), keys, strong: true);
      // No strong model: the default.
      expect(mistral.model, 'mistral-large-4');
      expect(mistral.apiKey, '');
      final vercel =
          await providerConfig(settings.copyWith(provider: 'vercel'), keys);
      expect(vercel.euOnly, isTrue);
    });

    testWidgets('"Reset to the defaults" brings back the preset\'s models',
        (tester) async {
      final store = MemoryAiSettingsStore();
      await pumpIn(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => AiSettingsScreen.open(context),
            child: const Text('open'),
          ),
        ),
        store: store,
        keys: MemoryKeyStore(),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final reset = find.byKey(const ValueKey('reset-models-anthropic'),
          skipOffstage: false);
      // As the preset: nothing to reset.
      expect(reset, findsNothing);
      final model = find.byKey(const ValueKey('default-model-anthropic'));
      await scrollTo(tester, model);
      await tester.enterText(model, 'gemini-x');
      await tester.enterText(
          find.byKey(const ValueKey('strong-model-anthropic')), '');
      await tester.pump();
      await scrollTo(tester, reset);
      await tester.tap(reset);
      await tester.pump();
      expect(reset, findsNothing);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.providerSettings('anthropic').defaultModel,
          'claude-sonnet-5-5');
      expect(store.settings.providerSettings('anthropic').strongModel,
          'claude-opus-5-5');
    });

    testWidgets('choosing a provider, its note, its key', (tester) async {
      final store = MemoryAiSettingsStore();
      final keys = MemoryKeyStore();
      await pumpIn(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => AiSettingsScreen.open(context),
            child: const Text('open'),
          ),
        ),
        store: store,
        keys: keys,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // The providers are grouped; the first group is above the note.
      expect(find.text('Data stays in the EU', skipOffstage: false),
          findsOneWidget);
      await scrollTo(tester, find.byKey(const ValueKey('provider-note')));
      expect(find.textContaining('Safe default (Sonnet 5.5)'), findsOneWidget);

      // Mistral is above the note: scroll back up.
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('provider-mistral')), -200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('provider-mistral')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const ValueKey('provider-note')));
      expect(find.textContaining('Best value in the EU'), findsOneWidget);
      final key = find.byKey(const ValueKey('api-key-mistral'));
      await scrollTo(tester, key);
      await tester.enterText(key, 'mi-key');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.provider, 'mistral');
      expect(keys.keys, {'mistral': 'mi-key'});
      // The key is not in the settings file.
      expect(jsonEncode(store.settings.toJson()), isNot(contains('mi-key')));
    });

    testWidgets('a saved key is not shown, and can be removed',
        (tester) async {
      final keys = MemoryKeyStore()..keys['anthropic'] = 'sk-old';
      await pumpIn(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => AiSettingsScreen.open(context),
            child: const Text('open'),
          ),
        ),
        keys: keys,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('sk-old'), findsNothing);
      final remove = find.text('Remove the saved key');
      await scrollTo(tester, remove);
      expect(find.text('A key is saved. Type a new one to replace it.'),
          findsOneWidget);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(keys.keys, isEmpty);
    });
  });
}
