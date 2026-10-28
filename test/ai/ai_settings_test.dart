import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_images.dart';
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

/// Opens the sub-page of a row of the AI settings page: `chat`, `images`,
/// `agent`, `web`, `notes` or `privacy` (#194).
Future<void> openRow(WidgetTester tester, String row) async {
  await tester.tap(find.byKey(ValueKey('ai-$row')));
  await tester.pumpAndSettle();
}

/// Goes back from a sub-page to the AI settings page.
Future<void> backToAi(WidgetTester tester) async {
  await tester.pageBack();
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
      // The line under "Privacy" names the tags.
      expect(find.text('private'), findsOneWidget);
      await openRow(tester, 'privacy');

      await tester.enterText(
          find.byKey(const ValueKey('hidden-tags')), 'private, secret :diary:');
      await backToAi(tester);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.hiddenTags, ['private', 'secret', 'diary']);
      expect(store.saves, 1);
      expect(find.text('tags: [private, secret, diary]'), findsOneWidget);
    });
  });

  testWidgets('"Hidden from AI" saves the tags chosen with the tag field '
      '(#140)', (tester) async {
    final store = MemoryAiSettingsStore();
    final tagged = graphOf({
      'a.org': ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n'
          '#+filetags: :diary:work:\n',
      'b.org': ':PROPERTIES:\n:ID: b\n:END:\n#+title: B\n'
          '#+filetags: :work:\n',
    });
    await pumpIn(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => AiSettingsScreen.open(context, graph: tagged),
          child: const Text('open'),
        ),
      ),
      store: store,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await openRow(tester, 'privacy');
    expect(find.text('work (2)'), findsOneWidget);
    await tester.tap(find.text('diary (1)'));
    await tester.pump();
    // A tag no note has yet can be typed.
    await tester.enterText(find.byKey(const ValueKey('hidden-tags')), 'secret');
    await tester.pump();
    expect(find.text('New tag: secret'), findsOneWidget);
    await backToAi(tester);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(store.settings.hiddenTags, ['private', 'diary', 'secret']);
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
      await openRow(tester, 'privacy');
      await tester.tap(find.byTooltip('Remove private'));
      await tester.pump();
      await backToAi(tester);
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

    testWidgets("the graph's More menu opens the AI settings",
        (tester) async {
      await pumpIn(
        tester,
        GraphScreen(
          graph: ValueNotifier<RoamGraph>(graph),
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory('plan'),
          computeLayout: layoutHere,
          computeAlgorithms: algorithmsHere,
        ),
      );
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

  test('"Language of new notes": English by default, saved (#172)', () {
    expect(const AiSettings().newNoteLanguage, 'en');
    final settings = const AiSettings().copyWith(newNoteLanguage: 'de');
    final back = AiSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
    expect(back.newNoteLanguage, 'de');
    expect(AiSettings.fromJson(const {}).newNoteLanguage, 'en');
    expect(AiSettings.fromJson({'newNoteLanguage': 'Deutsch'}).newNoteLanguage,
        'en');
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

  test('Mistral image agents: kept in the settings by provider and model '
      '(#163)', () {
    final settings = const AiSettings().copyWith(imageAgents: {
      AiSettings.imageAgentKey('mistral', 'mistral-medium-latest'): 'ag-1',
    });
    final back = AiSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
    expect(back.imageAgents, {'mistral mistral-medium-latest': 'ag-1'});
    expect(const AiSettings().imageAgents, isEmpty);
    expect(
        AiSettings.fromJson({
          'imageAgents': {'a': 3, 'b': '', 'c': 'ag-2'},
        }).imageAgents,
        {'c': 'ag-2'});
    expect(AiSettings.fromJson({'imageAgents': 'x'}).imageAgents, isEmpty);
  });

  testWidgets('"Create image" keeps the Mistral agent in the saved settings '
      '(#163)', (tester) async {
    final store = MemoryAiSettingsStore();
    ImageAgents? agents;
    await pumpIn(tester, Builder(builder: (context) {
      agents = AiSettingsScope.imageAgentsOf(context, 'mistral');
      return const SizedBox();
    }), store: store);
    expect(agents!.read('mistral-medium-latest'), isNull);
    await agents!.write('mistral-medium-latest', 'ag-1');
    expect(agents!.read('mistral-medium-latest'), 'ag-1');
    expect(agents!.read('mistral-large-latest'), isNull);
    expect(store.settings.imageAgents,
        {'mistral mistral-medium-latest': 'ag-1'});
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
      // Off by default: the default model has no EU route.
      expect(vercel.euOnly, isFalse);
      expect(vercel.model, 'deepseek/deepseek-v4-pro');
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
      await openRow(tester, 'chat');
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
      await backToAi(tester);
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
      await openRow(tester, 'chat');
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
      await backToAi(tester);
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
      await openRow(tester, 'chat');
      expect(find.text('sk-old'), findsNothing);
      final remove = find.text('Remove the saved key');
      await scrollTo(tester, remove);
      expect(
          find.text('A key is saved. Type a new one to replace it.',
              skipOffstage: false),
          findsOneWidget);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await backToAi(tester);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(keys.keys, isEmpty);
    });
  });

  test('saved Qwen settings from before images get Qwen Image (#120)', () {
    final qwen = presetById('qwen');
    final old = ProviderSettings.fromJson(
        {'imageModel': '', 'imageApi': 'images', 'defaultModel': 'qwen3.8-max'},
        qwen);
    expect(old.imageModel, 'qwen-image-2.0');
    expect(old.imageApi, ImageApi.dashscope);
    final chosen = ProviderSettings.fromJson(
        {'imageModel': 'qwen-image-2.0-pro', 'imageApi': 'chat'}, qwen);
    expect(chosen.imageModel, 'qwen-image-2.0-pro');
    expect(chosen.imageApi, ImageApi.dashscope);
    // Elsewhere DashScope is never taken from a file.
    final vercel = ProviderSettings.fromJson(
        {'imageApi': 'dashscope'}, presetById('vercel'));
    expect(vercel.imageApi, ImageApi.images);
  });

  test('empty saved chat models take the preset's models', () {
    final openRouter = presetById('openrouter');
    expect(openRouter.defaultModel, isNotEmpty);
    // Saved before OpenRouter had default models (#190).
    final old = ProviderSettings.fromJson(
        {'defaultModel': '', 'strongModel': ' ', 'baseUrl': ''}, openRouter);
    expect(old.defaultModel, openRouter.defaultModel);
    expect(old.strongModel, openRouter.strongModel);
    final chosen = ProviderSettings.fromJson(
        {'defaultModel': 'synthetic/model-a', 'strongModel': 'synthetic/b'},
        openRouter);
    expect(chosen.defaultModel, 'synthetic/model-a');
    expect(chosen.strongModel, 'synthetic/b');
  });

  test('Mistral makes images with its image tool (#126)', () {
    final mistral = presetById('mistral');
    expect(mistral.makesImages, isTrue);
    expect(mistral.imageModel, 'mistral-medium-latest');
    expect(mistral.imageApi, ImageApi.mistral);
    expect(ImageApi.mistral.label, 'Mistral image tool');
    // Saved before Mistral made images: an empty image model, the Images
    // API; now Mistral's defaults.
    final old = ProviderSettings.fromJson({
      'defaultModel': 'mistral-large-4',
      'imageModel': '',
      'imageApi': 'images',
    }, mistral);
    expect(old.defaultModel, 'mistral-large-4');
    expect(old.imageModel, 'mistral-medium-latest');
    expect(old.imageApi, ImageApi.mistral);
    final chosen = ProviderSettings.fromJson(
        {'imageModel': 'mistral-small-latest', 'imageApi': 'chat'}, mistral);
    expect(chosen.imageModel, 'mistral-small-latest');
    expect(chosen.imageApi, ImageApi.mistral);
    // Elsewhere the image tool is never taken from a file.
    final vercel = ProviderSettings.fromJson(
        {'imageApi': 'mistral'}, presetById('vercel'));
    expect(vercel.imageApi, ImageApi.images);
  });

  group('"Images with:" (#127)', () {
    test('saved and read back; before #127 or unknown: the chat\'s', () {
      expect(const AiSettings().imageProvider, '');
      expect(AiSettings.fromJson({'provider': 'anthropic'}).imageProvider, '');
      final read = AiSettings.fromJson(
          const AiSettings(provider: 'anthropic', imageProvider: 'mistral')
              .toJson());
      expect(read.provider, 'anthropic');
      expect(read.imageProvider, 'mistral');
      // A provider that makes no images, or none at all.
      expect(AiSettings.fromJson({'imageProvider': 'anthropic'}).imageProvider,
          '');
      expect(AiSettings.fromJson({'imageProvider': 'nope'}).imageProvider, '');
      expect(AiSettings.fromJson({'imageProvider': 3}).imageProvider, '');
    });

    test('its own key, image model and "EU only"; the chat is unchanged',
        () async {
      final keys = MemoryKeyStore()
        ..keys.addAll({'anthropic': 'a-key', 'vercel': 'v-key'});
      final settings = AiSettings(
        provider: 'anthropic',
        imageProvider: 'vercel',
        providers: {
          'vercel': ProviderSettings.fromJson(
              {'euOnly': true, 'imageModel': 'bfl/flux-2-pro'},
              presetById('vercel')),
        },
      );
      expect(imagePreset(settings).id, 'vercel');
      final image = (await imageConfig(settings, keys))!;
      expect(image.provider.name, 'Vercel AI Gateway');
      expect(image.provider.baseUrl, 'https://ai-gateway.vercel.sh/v1');
      expect(image.provider.apiKey, 'v-key');
      expect(image.provider.model, 'bfl/flux-2-pro');
      expect(image.provider.euOnly, isTrue);
      expect(image.api, ImageApi.images);
      final chat = await providerConfig(settings, keys);
      expect(chat.name, 'Anthropic');
      expect(chat.apiKey, 'a-key');
      expect(chat.model, presetById('anthropic').defaultModel);
      expect(chat.euOnly, isFalse);
      // "Same as the chat": the chat's provider, which makes no images.
      expect(await imageConfig(settings.copyWith(imageProvider: ''), keys),
          isNull);
    });

    test('an image provider without a key: said, with its name', () async {
      final settings =
          const AiSettings(provider: 'anthropic', imageProvider: 'mistral');
      final keys = MemoryKeyStore()..keys['anthropic'] = 'a-key';
      final config = (await imageConfig(settings, keys))!;
      await expectLater(
          makeImage(config, 'x',
              post: (url, headers, body) async => fail('nothing is sent')),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              'Enter the API key for Mistral in AI settings.')));
    });

    test('Vercel with "EU only": the default image model has an EU route',
        () async {
      final keys = MemoryKeyStore()..keys['vercel'] = 'v-key';
      final vercel = presetById('vercel');
      expect(vercel.euImageModel, 'google/gemini-2.5-flash-image');
      AiSettings withEu(bool on) => AiSettings(provider: 'vercel', providers: {
            'vercel': ProviderSettings.fromJson({'euOnly': on}, vercel),
          });
      final eu = (await imageConfig(withEu(true), keys))!;
      expect(eu.provider.model, 'google/gemini-2.5-flash-image');
      expect(eu.api, ImageApi.chat);
      final anywhere = (await imageConfig(withEu(false), keys))!;
      expect(anywhere.provider.model, 'openai/gpt-image-2');
      expect(anywhere.api, ImageApi.images);
    });

    test('where the image is made: in the EU, outside it, or not known',
        () async {
      final keys = MemoryKeyStore();
      Future<String> region(String id, {bool euOnly = false}) async {
        final settings = AiSettings(provider: id, providers: {
          id: ProviderSettings.fromJson({'euOnly': euOnly}, presetById(id)),
        });
        return imageRegion(
            presetById(id), (await imageConfig(settings, keys))!);
      }

      expect(await region('mistral'), 'in the EU');
      expect(await region('vercel', euOnly: true), 'in the EU');
      expect(await region('vercel'), 'outside the EU');
      expect(await region('qwen'), 'outside the EU');
      expect(await region('openrouter'), 'region not known');
    });

    testWidgets('chosen in AI settings, with its own key; the chat stays',
        (tester) async {
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
      await openRow(tester, 'images');
      final choice = find.byKey(const ValueKey('image-provider-'));
      await scrollTo(tester, choice);
      expect(find.text('Same as the chat (Anthropic)'), findsOneWidget);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mistral').last);
      await tester.pumpAndSettle();
      final model = find.byKey(const ValueKey('image-model-mistral'));
      await scrollTo(tester, model);
      expect(tester.widget<TextField>(model).controller!.text,
          'mistral-medium-latest');
      final key = find.byKey(const ValueKey('api-key-mistral'));
      await scrollTo(tester, key);
      await tester.enterText(key, 'mi-key');
      await backToAi(tester);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.provider, 'anthropic');
      expect(store.settings.imageProvider, 'mistral');
      expect(keys.keys, {'mistral': 'mi-key'});
      expect(jsonEncode(store.settings.toJson()), isNot(contains('mi-key')));
    });
  });

  group('"Infographics with:" (#183)', () {
    test('saved and read back; before #183 or unknown: as "Images with:"',
        () {
      expect(const AiSettings().infographicProvider, '');
      expect(AiSettings.fromJson({'imageProvider': 'mistral'})
          .infographicProvider, '');
      final read = AiSettings.fromJson(const AiSettings(
              provider: 'anthropic',
              imageProvider: 'mistral',
              infographicProvider: 'vercel')
          .toJson());
      expect(read.imageProvider, 'mistral');
      expect(read.infographicProvider, 'vercel');
      for (final bad in ['anthropic', 'nope', 3]) {
        expect(AiSettings.fromJson({'infographicProvider': bad})
            .infographicProvider, '', reason: '$bad');
      }
      // The infographic model of a provider: its own, saved; before #183
      // the preset's image model.
      final vercel = presetById('vercel');
      final saved = ProviderSettings.fromJson(
          {
            ...ProviderSettings.of(vercel).toJson(),
            'imageModel': 'bfl/flux-2-pro',
            'infographicModel': 'google/gemini-2.5-flash-image',
            'infographicApi': 'chat',
          },
          vercel);
      expect(saved.imageModel, 'bfl/flux-2-pro');
      expect(saved.infographicModel, 'google/gemini-2.5-flash-image');
      expect(saved.infographicApi, ImageApi.chat);
      final old = ProviderSettings.fromJson(
          {'imageModel': 'bfl/flux-2-pro'}, vercel);
      expect(old.infographicModel, vercel.imageModel);
      expect(old.infographicApi, vercel.imageApi);
    });

    test('an infographic uses its provider, key and model; an illustration '
        'and the chat are unchanged', () async {
      final keys = MemoryKeyStore()
        ..keys.addAll({'anthropic': 'a-key', 'mistral': 'm-key',
          'vercel': 'v-key'});
      final settings = AiSettings(
        provider: 'anthropic',
        imageProvider: 'mistral',
        infographicProvider: 'vercel',
        providers: {
          'vercel': ProviderSettings.fromJson({
            'imageModel': 'bfl/flux-2-pro',
            'infographicModel': 'google/gemini-3-pro-image',
            'infographicApi': 'chat',
          }, presetById('vercel')),
        },
      );
      expect(imagePreset(settings).id, 'mistral');
      expect(imagePreset(settings, ImageKind.illustration).id, 'mistral');
      expect(imagePreset(settings, ImageKind.infographic).id, 'vercel');
      final image = (await imageConfig(settings, keys))!;
      expect(image.provider.apiKey, 'm-key');
      expect(image.provider.model, 'mistral-medium-latest');
      final info =
          (await imageConfig(settings, keys, kind: ImageKind.infographic))!;
      expect(info.provider.name, 'Vercel AI Gateway');
      expect(info.provider.apiKey, 'v-key');
      expect(info.provider.model, 'google/gemini-3-pro-image');
      expect(info.api, ImageApi.chat);
      expect((await providerConfig(settings, keys)).apiKey, 'a-key');
      // Empty: an infographic as an illustration, with "Images with:".
      final same = settings.copyWith(infographicProvider: '');
      expect(imagePreset(same, ImageKind.infographic).id, 'mistral');
      expect(
          (await imageConfig(same, keys, kind: ImageKind.infographic))!
              .provider
              .model,
          'mistral-medium-latest');
      // The same provider under both: each its own model, one key.
      final both = AiSettings(
        provider: 'anthropic',
        imageProvider: 'vercel',
        infographicProvider: 'vercel',
        providers: settings.providers,
      );
      expect((await imageConfig(both, keys))!.provider.model,
          'bfl/flux-2-pro');
      final bothInfo =
          (await imageConfig(both, keys, kind: ImageKind.infographic))!;
      expect(bothInfo.provider.model, 'google/gemini-3-pro-image');
      expect(bothInfo.provider.apiKey, 'v-key');
    });

    testWidgets('chosen in AI settings, with its own key and model; '
        '"Images with:" stays', (tester) async {
      final store = MemoryAiSettingsStore(
          const AiSettings(provider: 'anthropic', imageProvider: 'mistral'));
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
      await openRow(tester, 'images');
      final choice = find.byKey(const ValueKey('infographic-provider-'));
      await scrollTo(tester, choice);
      expect(find.text('Same as "Images with:" (Mistral)'), findsOneWidget);
      expect(
          find.text('For pictures with text and numbers. GPT Image and '
              'Gemini Image set text well; FLUX (Mistral) does not.'),
          findsOneWidget);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vercel AI Gateway').last);
      await tester.pumpAndSettle();
      final model = find.byKey(const ValueKey('infographic-model-vercel'));
      await scrollTo(tester, model);
      expect(tester.widget<TextField>(model).controller!.text,
          'openai/gpt-image-2');
      await tester.enterText(model, 'google/gemini-3-pro-image');
      final key = find.byKey(const ValueKey('api-key-vercel'));
      await scrollTo(tester, key);
      await tester.enterText(key, 've-key');
      await backToAi(tester);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.settings.provider, 'anthropic');
      expect(store.settings.imageProvider, 'mistral');
      expect(store.settings.infographicProvider, 'vercel');
      final vercel = store.settings.providerSettings('vercel');
      expect(vercel.infographicModel, 'google/gemini-3-pro-image');
      expect(vercel.imageModel, 'openai/gpt-image-2');
      expect(keys.keys, {'vercel': 've-key'});
      expect(jsonEncode(store.settings.toJson()), isNot(contains('ve-key')));
    });
  });

  group('the sub-pages (#194)', () {
    Future<void> openAiPage(WidgetTester tester,
        {AiSettingsStore? store, ApiKeyStore? keys}) async {
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
    }

    testWidgets('six rows in this order, with the defaults under them',
        (tester) async {
      await openAiPage(tester);
      const rows = [
        ('chat', 'Chat', 'Anthropic · claude-sonnet-5-5'),
        ('images', 'Images', 'Anthropic'),
        ('agent', 'Agent and limits', 'Agent'),
        ('web', 'Web access', 'Off'),
        ('notes', 'Notes', 'English (en)'),
        ('privacy', 'Privacy', 'private'),
      ];
      double? above;
      for (final (key, title, subtitle) in rows) {
        final row = find.byKey(ValueKey('ai-$key'));
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(title)),
            findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(subtitle)),
            findsOneWidget);
        final top = tester.getTopLeft(row).dy;
        expect(top, greaterThan(above ?? -1));
        above = top;
      }
      // Nothing is changed yet.
      expect(find.byKey(const ValueKey('ai-unsaved')), findsNothing);
    });

    testWidgets('the lines under the rows show the saved choices',
        (tester) async {
      await openAiPage(
        tester,
        store: MemoryAiSettingsStore(const AiSettings(
          provider: 'mistral',
          infographicProvider: 'vercel',
          editMode: AiEditMode.review,
          webAccess: true,
          maxWebSearches: 7,
          newNoteLanguage: 'de',
          hiddenTags: ['private', 'diary'],
        )),
      );
      Finder under(String key, String text) => find.descendant(
          of: find.byKey(ValueKey('ai-$key')), matching: find.text(text));
      expect(under('chat', 'Mistral · mistral-large-4'), findsOneWidget);
      expect(under('images', 'Mistral · Vercel AI Gateway (infographics)'),
          findsOneWidget);
      expect(under('agent', 'Review'), findsOneWidget);
      expect(under('web', 'On, at most 7 searches'), findsOneWidget);
      expect(under('notes', 'German (de)'), findsOneWidget);
      expect(under('privacy', 'private, diary'), findsOneWidget);
    });

    testWidgets('a page without tags says so', (tester) async {
      await openAiPage(tester,
          store: MemoryAiSettingsStore(const AiSettings(hiddenTags: [])));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('ai-privacy')),
              matching: find.text('No tags')),
          findsOneWidget);
    });

    testWidgets('each sub-page shows its fields', (tester) async {
      await openAiPage(tester);
      const pages = {
        'chat': [
          'provider-anthropic',
          'base-url-anthropic',
          'default-model-anthropic',
          'strong-model-anthropic',
          'api-key-anthropic',
        ],
        'images': ['image-provider-', 'infographic-provider-'],
        'agent': [
          'max-tool-rounds',
          'max-output-tokens',
          'edit-mode',
          'max-agent-changes',
          'max-images',
          'max-change-set-files',
        ],
        'web': ['web-access', 'max-web-searches'],
        'notes': ['new-note-language'],
        'privacy': ['hidden-tags'],
      };
      for (final MapEntry(key: row, value: keys) in pages.entries) {
        await openRow(tester, row);
        for (final key in keys) {
          // The fields are listed from the top of the page down.
          await scrollTo(tester, find.byKey(ValueKey(key)));
          expect(find.byKey(ValueKey(key)), findsOneWidget,
              reason: '$row: $key');
        }
        await backToAi(tester);
      }
    });

    testWidgets('a change in a sub-page is saved with the check mark and '
        'read back', (tester) async {
      final store = MemoryAiSettingsStore();
      await openAiPage(tester, store: store);
      await openRow(tester, 'agent');
      final changes = find.byKey(const ValueKey('max-agent-changes'));
      await scrollTo(tester, changes);
      await tester.enterText(changes, '12');
      await backToAi(tester);
      await openRow(tester, 'notes');
      await tester.tap(find.byKey(const ValueKey('new-note-language-de')));
      await tester.pump();
      await backToAi(tester);
      await openRow(tester, 'web');
      await tester.tap(find.byKey(const ValueKey('web-access')));
      await tester.pump();
      await backToAi(tester);

      // The page says so, and shows the new choices.
      expect(find.byKey(const ValueKey('ai-unsaved')), findsOneWidget);
      expect(find.text('German (de)'), findsOneWidget);
      expect(find.text('On, at most 5 searches'), findsOneWidget);
      expect(store.saves, 0);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(store.saves, 1);
      expect(store.settings.maxAgentChanges, 12);
      expect(store.settings.newNoteLanguage, 'de');
      expect(store.settings.webAccess, isTrue);
      expect(find.byType(AiSettingsScreen), findsNothing);

      // Opened again, the sub-page shows what was saved.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('German (de)'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-unsaved')), findsNothing);
      await openRow(tester, 'agent');
      final saved = tester.widget<TextField>(
          find.byKey(const ValueKey('max-agent-changes')));
      expect(saved.controller!.text, '12');
    });

    testWidgets('a key typed in a sub-page is stored only on Save',
        (tester) async {
      final keys = MemoryKeyStore();
      await openAiPage(tester, keys: keys);
      await openRow(tester, 'chat');
      final key = find.byKey(const ValueKey('api-key-anthropic'));
      await scrollTo(tester, key);
      await tester.enterText(key, 'sk-new');
      await backToAi(tester);
      expect(keys.keys, isEmpty);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(keys.keys, {'anthropic': 'sk-new'});
    });

    testWidgets('leaving with unsaved changes asks; Discard keeps the old '
        'values', (tester) async {
      final store = MemoryAiSettingsStore();
      final keys = MemoryKeyStore();
      await openAiPage(tester, store: store, keys: keys);
      await openRow(tester, 'chat');
      final key = find.byKey(const ValueKey('api-key-anthropic'));
      await scrollTo(tester, key);
      await tester.enterText(key, 'sk-new');
      await backToAi(tester);
      await openRow(tester, 'agent');
      final rounds = find.byKey(const ValueKey('max-tool-rounds'));
      await scrollTo(tester, rounds);
      await tester.enterText(rounds, '3');
      await backToAi(tester);

      // Keep editing: the page stays, the changes stay.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-unsaved')), findsOneWidget);

      // Discard: the page closes and nothing is saved.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsScreen), findsNothing);
      expect(store.saves, 0);
      expect(store.settings.maxToolRounds, 10);
      expect(keys.keys, isEmpty);
    });

    testWidgets('leaving without changes does not ask', (tester) async {
      await openAiPage(tester);
      await openRow(tester, 'web');
      await backToAi(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(AiSettingsScreen), findsNothing);
    });

    testWidgets("the chat provider's image model is on Chat when Images uses "
        'another provider, else on Images', (tester) async {
      final model = find.byKey(const ValueKey('image-model-vercel'));
      await openAiPage(
        tester,
        store: MemoryAiSettingsStore(
            const AiSettings(provider: 'vercel', imageProvider: 'mistral')),
      );
      await openRow(tester, 'chat');
      await scrollTo(tester, model);
      expect(model, findsOneWidget);
      await backToAi(tester);
      await openRow(tester, 'images');
      expect(model, findsNothing);
      expect(find.byKey(const ValueKey('image-model-mistral')),
          findsOneWidget);
    });

    testWidgets("the chat provider's image model is on Images when Images "
        'is the same as the chat', (tester) async {
      final model = find.byKey(const ValueKey('image-model-vercel'));
      await openAiPage(tester,
          store: MemoryAiSettingsStore(const AiSettings(provider: 'vercel')));
      await openRow(tester, 'images');
      await scrollTo(tester, model);
      expect(model, findsOneWidget);
      await backToAi(tester);
      await openRow(tester, 'chat');
      await scrollTo(tester, find.byKey(const ValueKey('api-key-vercel')));
      expect(model, findsNothing);
    });

    testWidgets('a provider switch is a change too', (tester) async {
      await openAiPage(tester);
      await openRow(tester, 'chat');
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('provider-mistral')), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const ValueKey('provider-mistral')));
      await tester.pumpAndSettle();
      await backToAi(tester);
      expect(find.byKey(const ValueKey('ai-unsaved')), findsOneWidget);
      expect(find.text('Mistral · mistral-large-4'), findsOneWidget);
    });
  });
}
