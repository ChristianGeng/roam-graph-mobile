import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_models.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';

import 'ai_settings_test.dart'
    show MemoryAiSettingsStore, MemoryKeyStore, scrollTo;

/// Answers GETs with [replies] in order, and keeps the requests.
class FakeGet {
  FakeGet(this.replies);

  final List<Object> replies;
  final requests = <(Uri, Map<String, String>)>[];

  Future<HttpReply> call(Uri url, Map<String, String> headers) async {
    requests.add((url, headers));
    final reply = replies.removeAt(0);
    if (reply is Exception) throw reply;
    if (reply is HttpReply) return reply;
    return HttpReply(200, jsonEncode(reply));
  }
}

/// A list in Vercel AI Gateway's shape, with OpenRouter-style metadata on
/// one model.
const vercelList = {
  'object': 'list',
  'data': [
    {
      'id': 'anthropic/claude-sonnet-5.5',
      'name': 'Claude Sonnet 5.5',
      'tags': ['tool-use', 'reasoning'],
      'pricing': {'input': '0.000003', 'output': '0.000015'},
      'regions': ['eu', 'us'],
    },
    {
      'id': 'openai/gpt-6-astra',
      'tags': ['tool-use'],
      'pricing': {'input': '0.000005', 'output': '0.00002'},
    },
    {'id': 'vendor/image-maker', 'tags': ['image-generation']},
  ],
};

void main() {
  setUp(clearModelCache);

  group('reading model lists', () {
    test('a plain OpenAI list: IDs only, sorted', () {
      final models = readModelList({
        'object': 'list',
        'data': [
          {'id': 'b', 'object': 'model'},
          {'id': 'a', 'object': 'model'},
          {'object': 'model'},
        ],
      }, api: ApiKind.openAi);
      expect([for (final m in models) m.id], ['a', 'b']);
      expect(models.first.tools, isNull);
      expect(models.first.inputPrice, isNull);
    });

    test('OpenRouter, Mistral, Vercel and Hugging Face metadata', () {
      final router = readModelList({
        'data': [
          {
            'id': 'x/with-tools',
            'name': 'With tools',
            'supported_parameters': ['tools', 'temperature'],
            'pricing': {'prompt': '0.000002', 'completion': '0.00001'},
          },
          {'id': 'x/no-tools', 'supported_parameters': ['temperature']},
        ],
      }, api: ApiKind.openAi);
      expect(router.first.tools, isFalse);
      expect(router.last.tools, isTrue);
      expect(router.last.name, 'With tools');
      expect(router.last.inputPrice, closeTo(2, 1e-9));
      expect(router.last.outputPrice, closeTo(10, 1e-9));

      final mistral = readModelList({
        'data': [
          {'id': 'mistral-large-4', 'capabilities': {'function_calling': true}},
        ],
      }, api: ApiKind.openAi);
      expect(mistral.single.tools, isTrue);

      final vercel = readModelList(vercelList, api: ApiKind.openAi);
      expect(vercel.first.inEu, isTrue);
      expect(vercel[1].inEu, isNull);
      expect(vercel.last.tools, isFalse);
      expect(vercel.first.outputPrice, closeTo(15, 1e-9));

      final hf = readModelList({
        'data': [
          {
            'id': 'org/model',
            'providers': [
              {'provider': 'a', 'supports_tools': false},
              {'provider': 'b', 'supports_tools': true},
            ],
          },
        ],
      }, api: ApiKind.openAi);
      expect(hf.single.tools, isTrue);
    });

    test("Anthropic's list: names, and tools for all", () {
      final models = readModelList({
        'data': [
          {'id': 'claude-opus-5-5', 'display_name': 'Claude Opus 5.5', 'type': 'model'},
        ],
        'has_more': false,
      }, api: ApiKind.anthropic);
      expect(models.single.name, 'Claude Opus 5.5');
      expect(models.single.tools, isTrue);
    });

    test('Vercel with "EU only": the routes the owner checked', () {
      // anthropic/claude-sonnet-5.5 works with "EU only"; Mistral Large 4
      // and DeepSeek V4 Pro fail ("no provider supports the requested
      // inference region"), checked on 2026-10-17.
      final models = readModelList({
        'data': [
          {'id': 'anthropic/claude-sonnet-5.5', 'regions': ['eu', 'us']},
          {'id': 'mistral/mistral-large-4', 'regions': ['us']},
          {'id': 'deepseek/deepseek-v4-pro'},
        ],
      }, api: ApiKind.openAi);
      expect([for (final m in models) (m.id, m.inEu)], [
        ('anthropic/claude-sonnet-5.5', true),
        ('deepseek/deepseek-v4-pro', null),
        ('mistral/mistral-large-4', false),
      ]);
    });

    test('an unreadable list says so', () {
      expect(() => readModelList({'models': []}, api: ApiKind.openAi),
          throwsA(isA<AiError>()));
    });
  });

  group('fetching', () {
    test('OpenAI-compatible: GET <base>/models with the key; kept for the '
        'session', () async {
      final get = FakeGet([vercelList, vercelList]);
      Future<List<ModelInfo>> fetch({bool refresh = false}) => fetchModels(
          provider: 'Vercel AI Gateway',
          api: ApiKind.openAi,
          baseUrl: 'https://ai-gateway.vercel.sh/v1/',
          apiKey: 'v-key',
          get: get.call,
          refresh: refresh);
      expect(await fetch(), hasLength(3));
      final (url, headers) = get.requests.single;
      expect(url.toString(), 'https://ai-gateway.vercel.sh/v1/models');
      expect(headers['authorization'], 'Bearer v-key');
      await fetch();
      expect(get.requests, hasLength(1));
      await fetch(refresh: true);
      expect(get.requests, hasLength(2));
    });

    test('Anthropic: GET <base>/v1/models with its headers', () async {
      final get = FakeGet([
        {
          'data': [
            {'id': 'claude-sonnet-5-5'},
          ],
        },
      ]);
      await fetchModels(
          provider: 'Anthropic',
          api: ApiKind.anthropic,
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'sk',
          get: get.call);
      final (url, headers) = get.requests.single;
      expect(url.toString(), 'https://api.anthropic.com/v1/models?limit=1000');
      expect(headers['x-api-key'], 'sk');
      expect(headers['anthropic-version'], '2023-06-01');
    });

    test('errors say what to do', () async {
      Future<String> error(Object reply, {String key = 'k', String base = 'https://x.example/v1'}) async {
        try {
          await fetchModels(
              provider: 'Mistral',
              api: ApiKind.openAi,
              baseUrl: base,
              apiKey: key,
              get: FakeGet([reply]).call);
        } on AiError catch (e) {
          return e.message;
        }
        fail('no error');
      }

      expect(await error(const HttpReply(401, ''), key: ''),
          'Mistral needs the API key for its model list. Enter the key first.');
      expect(await error(const HttpReply(401, '')),
          'Mistral refused the API key (HTTP 401).');
      expect(await error(const HttpReply(404, '')), contains('Type the model'));
      expect(await error(const SocketException('offline')),
          'No connection to x.example: offline.');
      expect(await error(const HttpReply(200, 'oops')),
          contains('cannot read'));
      expect(await error(const HttpReply(200, '{}'), base: 'http://x.example'),
          contains('only over HTTPS'));
    });
  });

  testWidgets('choosing a model for Vercel fills the field', (tester) async {
    final store = MemoryAiSettingsStore(const AiSettings(provider: 'vercel'));
    final keys = MemoryKeyStore()..keys['vercel'] = 'v-key';
    final get = FakeGet([vercelList]);
    await tester.pumpWidget(AiSettingsHost(
      store: store,
      keys: keys,
      child: MaterialApp(home: AiSettingsScreen(get: get.call)),
    ));
    await tester.pumpAndSettle();
    final choose = find.byKey(const ValueKey('choose-default-vercel'));
    await scrollTo(tester, choose);
    await tester.tap(choose);
    await tester.pumpAndSettle();

    // Only models with tools; "EU only" is on: GPT-6 has no EU route listed.
    expect(find.text('2 of 3 models'), findsOneWidget);
    expect(find.text('vendor/image-maker'), findsNothing);
    expect(find.textContaining('\$3.0 in, \$15 out per million tokens'),
        findsOneWidget);
    // GPT-6 lists no regions, so it has no EU route.
    expect(tester.widget<ListTile>(find.byKey(
        const ValueKey('model-openai/gpt-6-astra'))).enabled, isFalse);
    expect(find.textContaining('no EU route'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('model-all')));
    await tester.pumpAndSettle();
    expect(find.text('3 of 3 models'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('model-search')), 'sonnet');
    await tester.pumpAndSettle();
    await tester.tap(find.text('anthropic/claude-sonnet-5.5'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('default-model-vercel')));
    expect(field.controller!.text, 'anthropic/claude-sonnet-5.5');
    expect(get.requests.single.$2['authorization'], 'Bearer v-key');
  });
}
