import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';

import 'ai_visibility_test.dart' show graphOf, notes;

/// A provider that answers with [replies], in order, and keeps what it
/// was sent.
class FakeServer {
  FakeServer(this.replies);

  final List<Object> replies;
  final requests = <({Uri url, Map<String, String> headers, Map body})>[];

  Future<HttpReply> post(
      Uri url, Map<String, String> headers, String body) async {
    requests.add((url: url, headers: headers, body: jsonDecode(body) as Map));
    final reply = replies.removeAt(0);
    if (reply is Exception) throw reply;
    if (reply is HttpReply) return reply;
    return HttpReply(200, jsonEncode(reply));
  }
}

const anthropic = ProviderConfig(
  name: 'Anthropic',
  api: ApiKind.anthropic,
  baseUrl: 'https://api.anthropic.com/',
  model: 'claude-sonnet-5-5',
  apiKey: 'sk-test',
);

const deepseek = ProviderConfig(
  name: 'DeepSeek',
  api: ApiKind.openAi,
  baseUrl: 'https://api.deepseek.com',
  model: 'deepseek-v4-pro',
  apiKey: 'ds-test',
);

Map<String, Object?> anthropicReply(List<Map<String, Object?>> content,
        {String stop = 'end_turn', int input = 100, int read = 0}) =>
    {
      'model': 'claude-sonnet-5-5',
      'content': content,
      'stop_reason': stop,
      'usage': {
        'input_tokens': input,
        'cache_read_input_tokens': read,
        'cache_creation_input_tokens': 10,
        'output_tokens': 20,
      },
    };

Map<String, Object?> openAiReply(Map<String, Object?> message,
        {String finish = 'stop', Map<String, Object?>? usage}) =>
    {
      'model': 'deepseek-v4-pro',
      'choices': [
        {'message': message, 'finish_reason': finish},
      ],
      'usage': usage ?? {'prompt_tokens': 50, 'completion_tokens': 5},
    };

/// [value] without `cache_control`, which marks where the provider
/// caches but is not part of what it caches.
Object? withoutCacheMarks(Object? value) => switch (value) {
      Map() => {
          for (final e in value.entries)
            if (e.key != 'cache_control') e.key: withoutCacheMarks(e.value),
        },
      List() => [for (final v in value) withoutCacheMarks(v)],
      _ => value,
    };

void main() {
  final graph = graphOf(notes);
  RoamTools tools() => RoamTools(graph,
      readNote: (path) async => notes[path],
      visibility: const AiVisibility({'private'}));

  group('Anthropic Messages API', () {
    test('runs the tools the model asks for, until it answers', () async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'thinking', 'thinking': 'Look it up.', 'signature': 'sig'},
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'org_roam_find',
            'input': {'search': 'Plan'},
          },
        ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'It is [[id:plan][Plan]].'},
        ], read: 900),
      ]);
      final session =
          ChatSession(tools: tools(), config: anthropic, post: server.post);
      await session.send('Where is my plan?', context: 'I am at Ideas.');

      expect(server.requests, hasLength(2));
      final first = server.requests.first;
      expect(first.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(first.headers['x-api-key'], 'sk-test');
      expect(first.headers['anthropic-version'], '2023-06-01');
      expect(first.body['model'], 'claude-sonnet-5-5');
      expect(first.body['max_tokens'], 8192);
      expect((first.body['tools'] as List).length, aiTools.length);
      // The node the chat came from is in the first message, not the
      // system prompt, so the system prompt never changes.
      expect(first.body['system'][0]['text'], systemPrompt);
      expect(first.body['messages'][0]['content'][0]['text'],
          'I am at Ideas.\n\nWhere is my plan?');

      final second = server.requests.last.body['messages'] as List;
      // The answer goes back as it came, thinking and signature included.
      expect(second[1]['content'][0]['signature'], 'sig');
      final result = second[2]['content'][0] as Map;
      expect(result['type'], 'tool_result');
      expect(result['tool_use_id'], 'toolu_1');
      expect(result['content'], contains('plan | Plan | plan.org'));

      final answer = session.transcript.last as AssistantMessage;
      expect(answer.text, 'It is [[id:plan][Plan]].');
      expect(session.usage.input, 110 + 1010);
      expect(session.usage.cached, 900);
      expect(session.usage.output, 40);
    });

    test('every request starts with the bytes of the one before (caching)',
        () async {
      final server = FakeServer([
        for (var i = 0; i < 3; i++)
          anthropicReply([
            {
              'type': 'tool_use',
              'id': 'toolu_$i',
              'name': 'org_roam_backlinks',
              'input': {'node_id': 'plan'},
            },
          ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': 'Again.'},
        ]),
      ]);
      final session =
          ChatSession(tools: tools(), config: anthropic, post: server.post);
      await session.send('Backlinks of Plan, three times.');
      await session.send('And again.');
      final bodies = [for (final r in server.requests) r.body];
      expect(bodies, hasLength(5));
      for (var i = 1; i < bodies.length; i++) {
        final before = withoutCacheMarks(bodies[i - 1]) as Map;
        final now = withoutCacheMarks(bodies[i]) as Map;
        // Same system prompt and tools, to the byte.
        expect(jsonEncode(now['system']), jsonEncode(before['system']));
        expect(jsonEncode(now['tools']), jsonEncode(before['tools']));
        // The conversation only grows: the earlier messages are unchanged.
        final earlier = before['messages'] as List;
        final messages = now['messages'] as List;
        for (var m = 0; m < earlier.length - 1; m++) {
          expect(jsonEncode(messages[m]), jsonEncode(earlier[m]),
              reason: 'request $i, message $m');
        }
      }
      // Two cache marks: the system prompt and the end of the conversation.
      for (final body in bodies) {
        expect(body['system'][0]['cache_control'], {'type': 'ephemeral'});
        final marks = RegExp('cache_control')
            .allMatches(jsonEncode(body['messages']))
            .length;
        expect(marks, 1);
        final last = (body['messages'] as List).last['content'] as List;
        expect(last.last['cache_control'], {'type': 'ephemeral'});
      }
    });

    test('an answer cut at the token limit says what to do', () async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Half an answ'},
        ], stop: 'max_tokens'),
      ]);
      final session =
          ChatSession(tools: tools(), config: anthropic, post: server.post);
      await expectLater(
          session.send('Tell me all.'),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              contains('Raise "Most tokens per answer"'))));
      expect(session.transcript.whereType<AssistantMessage>(), isEmpty);
    });
  });

  group('OpenAI-compatible Chat Completions', () {
    test('tool calls, tool messages, and DeepSeek\'s reasoning', () async {
      final server = FakeServer([
        openAiReply({
          'role': 'assistant',
          'content': null,
          'reasoning_content': 'Find it first.',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'org_roam_bfs',
                'arguments': '{"node_id": "plan", "depth": 1}',
              },
            },
          ],
        }, finish: 'tool_calls', usage: {
          'prompt_tokens': 1000,
          'completion_tokens': 30,
          'prompt_cache_hit_tokens': 800,
        }),
        openAiReply({'role': 'assistant', 'content': 'Plan links to Ideas.'},
            usage: {
              'prompt_tokens': 1200,
              'completion_tokens': 8,
              'prompt_tokens_details': {'cached_tokens': 1000},
            }),
      ]);
      final session =
          ChatSession(tools: tools(), config: deepseek, post: server.post);
      await session.send('What does Plan link to?');

      final first = server.requests.first;
      expect(first.url.toString(), 'https://api.deepseek.com/chat/completions');
      expect(first.headers['authorization'], 'Bearer ds-test');
      final messages = first.body['messages'] as List;
      expect(messages.first, {'role': 'system', 'content': systemPrompt});
      expect(first.body['tools'][0]['type'], 'function');
      expect(first.body['tools'][0]['function']['name'], 'org_roam_find');
      expect(first.body.containsKey('providerOptions'), isFalse);

      final second = server.requests.last.body['messages'] as List;
      expect(second[2]['tool_calls'][0]['id'], 'call_1');
      expect(second[2]['reasoning_content'], 'Find it first.');
      expect(second[3]['role'], 'tool');
      expect(second[3]['tool_call_id'], 'call_1');
      expect(second[3]['content'], contains('1 | ideas | Ideas'));
      // The hidden diary is not in any tool result.
      expect(jsonEncode(second), isNot(contains('My diary')));

      expect(session.usage.input, 2200);
      expect(session.usage.cached, 1800);
      expect(session.usage.output, 38);
    });

    test('Vercel\'s "EU only" asks for the EU region', () async {
      final server = FakeServer([
        openAiReply({'role': 'assistant', 'content': 'Hi.'}),
      ]);
      const vercel = ProviderConfig(
        name: 'Vercel AI Gateway',
        api: ApiKind.openAi,
        baseUrl: 'https://ai-gateway.vercel.sh/v1',
        model: 'anthropic/claude-sonnet-5-5',
        apiKey: 'v',
        euOnly: true,
      );
      await ChatSession(tools: tools(), config: vercel, post: server.post)
          .send('Hi');
      expect(server.requests.single.body['providerOptions'], {
        'gateway': {
          'inferenceRegion': {'scope': 'zone', 'geoRegion': 'eu'},
        },
      });
    });

    test('arguments that are not JSON get an error, not a crash', () async {
      final server = FakeServer([
        openAiReply({
          'role': 'assistant',
          'tool_calls': [
            {
              'id': 'c',
              'type': 'function',
              'function': {'name': 'org_roam_find', 'arguments': '{search:'},
            },
          ],
        }, finish: 'tool_calls'),
        openAiReply({'role': 'assistant', 'content': 'Sorry.'}),
      ]);
      await ChatSession(tools: tools(), config: deepseek, post: server.post)
          .send('Find');
      final messages = server.requests.last.body['messages'] as List;
      expect(messages[2]['tool_calls'][0]['function']['arguments'], '{search:');
      expect(messages[3]['content'],
          'Error: the arguments are not valid JSON: {search:');
    });
  });

  group('limits and errors', () {
    Map<String, Object?> call(int i, [String tool = 'org_roam_orphans']) =>
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 'toolu_$i',
            'name': tool,
            'input': <String, Object?>{},
          },
        ], stop: 'tool_use');

    test('runs the most tool rounds allowed, then no more', () async {
      final server = FakeServer([
        call(1),
        call(2),
        call(3),
      ]);
      final session = ChatSession(
          tools: tools(), config: anthropic, post: server.post, maxToolRounds: 2);
      await session.send('Orphans?');
      expect(server.requests, hasLength(3));
      final results = session.transcript.whereType<ToolResults>().toList();
      // Both allowed rounds ran; the last says it was the last.
      expect(results, hasLength(2));
      expect(results.first.results.single.content, startsWith('Orphans'));
      expect(results.last.results.single.content, startsWith('Orphans'));
      expect(results.last.results.single.content,
          endsWith('answer now, with what you have.)'));
      expect((session.transcript.last as AssistantMessage).text,
          '(Stopped after 2 tool rounds.)');
      // Every tool call before it has its result, as the APIs require.
      expect(session.transcript.last is AssistantMessage, isTrue);
      expect((session.transcript.last as AssistantMessage).toolCalls, isEmpty);
    });

    test('a retry does not give the message new tool rounds', () async {
      final server = FakeServer([
        call(1),
        const SocketException('offline'),
        call(2),
      ]);
      final session = ChatSession(
          tools: tools(), config: anthropic, post: server.post, maxToolRounds: 1);
      await expectLater(session.send('Orphans?'), throwsA(isA<AiError>()));
      await session.resume();
      expect(session.transcript.whereType<ToolResults>(), hasLength(1));
      expect((session.transcript.last as AssistantMessage).text,
          '(Stopped after 1 tool rounds.)');
    });

    test('a tool that fails gives the model an error, not a broken chat',
        () async {
      final server = FakeServer([
        call(1, 'org_roam_read_node'),
        anthropicReply([
          {'type': 'text', 'text': 'Could not read it.'},
        ]),
      ]);
      final failing = RoamTools(graph,
          readNote: (_) async => throw const FileSystemException('gone'));
      final session =
          ChatSession(tools: failing, config: anthropic, post: server.post);
      await session.send('Read plan');
      final result = session.transcript.whereType<ToolResults>().single;
      expect(result.results.single.content, startsWith('Error:'));
      expect((session.transcript.last as AssistantMessage).text,
          'Could not read it.');
    });

    test('a cut answer is dropped, so "Send again" asks again', () async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Half'},
        ], stop: 'max_tokens'),
        anthropicReply([
          {'type': 'text', 'text': 'Whole.'},
        ]),
      ]);
      final session =
          ChatSession(tools: tools(), config: anthropic, post: server.post);
      await expectLater(session.send('Tell me all.'), throwsA(isA<AiError>()));
      expect(session.waiting, isTrue);
      await session.resume();
      expect(session.transcript.whereType<AssistantMessage>().single.text,
          'Whole.');
    });

    test('keys only over HTTPS; redirects are not followed', () async {
      final server = FakeServer([
        const HttpReply(301, ''),
        openAiReply({'role': 'assistant', 'content': 'Local.'}),
      ]);
      const plain = ProviderConfig(
        name: 'Custom',
        api: ApiKind.openAi,
        baseUrl: 'http://192.168.1.5:11434/v1',
        model: 'llama',
        apiKey: 'secret',
        keyRequired: false,
      );
      await expectLater(
          ChatSession(tools: tools(), config: plain, post: server.post)
              .send('Hi'),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', startsWith('The app sends an API '
                  'key only over HTTPS.'))));
      expect(server.requests, isEmpty);
      await expectLater(
          ChatSession(tools: tools(), config: anthropic, post: server.post)
              .send('Hi'),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', contains('redirect (HTTP 301)'))));
      // Without a key, a local server over HTTP is fine.
      const local = ProviderConfig(
        name: 'Custom',
        api: ApiKind.openAi,
        baseUrl: 'http://192.168.1.5:11434/v1',
        model: 'llama',
        apiKey: '',
        keyRequired: false,
      );
      await ChatSession(tools: tools(), config: local, post: server.post)
          .send('Hi');
      expect(server.requests.last.headers.containsKey('authorization'),
          isFalse);
    });

    test('a cancelled chat runs and sends nothing more', () async {
      final server = FakeServer([call(1, 'org_roam_read_node')]);
      late ChatSession session;
      var read = 0;
      final counting = RoamTools(graph, readNote: (path) async {
        read++;
        return notes[path];
      });
      session = ChatSession(
          tools: counting,
          config: anthropic,
          post: (url, headers, body) {
            final reply = server.post(url, headers, body);
            session.cancel();
            return reply;
          });
      await session.send('Read plan');
      expect(server.requests, hasLength(1));
      expect(read, 0);
    });

    test('no key, no model: nothing is sent', () async {
      final server = FakeServer([]);
      final noKey = ChatSession(
        tools: tools(),
        config: const ProviderConfig(
            name: 'Mistral',
            api: ApiKind.openAi,
            baseUrl: 'https://api.mistral.ai/v1',
            model: 'mistral-large-4',
            apiKey: ''),
        post: server.post,
      );
      await expectLater(noKey.send('Hi'),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              'No API key for Mistral. Enter it in AI settings.')));
      final noModel = ChatSession(
          tools: tools(),
          config: anthropic.withModel(''),
          post: server.post);
      await expectLater(noModel.send('Hi'),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', startsWith('No model is set'))));
      expect(server.requests, isEmpty);
    });

    test('HTTP errors and network errors say what to do', () async {
      Future<String> errorOf(Object reply) async {
        final session = ChatSession(
            tools: tools(), config: anthropic, post: FakeServer([reply]).post);
        try {
          await session.send('Hi');
        } on AiError catch (e) {
          return e.message;
        }
        fail('no error');
      }

      expect(
          await errorOf(const HttpReply(401,
              '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')),
          'Anthropic refused the API key (HTTP 401). Check it in AI '
          'settings. invalid x-api-key');
      expect(await errorOf(const HttpReply(429, '{"error":{"message":"slow down"}}')),
          startsWith('Too many requests, or no credit left at Anthropic'));
      expect(
          await errorOf(const HttpReply(
              400, '{"message":"This model does not support tools"}')),
          startsWith('The model "claude-sonnet-5-5" may not support tools'));
      expect(await errorOf(const HttpReply(404, 'Not Found')),
          contains('Check the base URL and the model'));
      expect(await errorOf(const HttpReply(500, '<html>oops</html>')),
          'Anthropic answered with an error (HTTP 500). <html>oops</html>');
      expect(await errorOf(const SocketException('Failed host lookup')),
          'No connection to api.anthropic.com: Failed host lookup. Check '
          'the network.');
      expect(await errorOf(const HttpReply(200, 'not json')),
          'Anthropic sent an answer the app cannot read.');
    });

    test('after an error, resume sends the conversation again', () async {
      final server = FakeServer([
        const SocketException('offline'),
        anthropicReply([
          {'type': 'text', 'text': 'Back.'},
        ]),
      ]);
      final session =
          ChatSession(tools: tools(), config: anthropic, post: server.post);
      await expectLater(session.send('Hi'), throwsA(isA<AiError>()));
      expect(session.waiting, isTrue);
      await session.resume();
      expect((session.transcript.last as AssistantMessage).text, 'Back.');
      expect(session.transcript.whereType<UserMessage>(), hasLength(1));
    });

    test('the model can be switched for the rest of a chat', () async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'A'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': 'B'},
        ]),
      ]);
      final session =
          ChatSession(tools: tools(), config: anthropic, post: server.post);
      await session.send('One');
      session.model = 'claude-opus-5-5';
      await session.send('Two');
      expect([for (final r in server.requests) r.body['model']],
          ['claude-sonnet-5-5', 'claude-opus-5-5']);
    });
  });

  test('presets: known APIs, HTTPS, and no small model as a default', () {
    expect(providerPresets.map((p) => p.id).toSet().length,
        providerPresets.length);
    for (final p in providerPresets) {
      if (p.baseUrl.isNotEmpty) expect(p.baseUrl, startsWith('https://'));
      expect('${p.defaultModel} ${p.strongModel}'.toLowerCase(),
          isNot(contains('haiku')));
      expect(p.note, isNotEmpty);
    }
    expect(presetById('anthropic').defaultModel, 'claude-sonnet-5-5');
    expect(presetById('anthropic').strongModel, 'claude-opus-5-5');
    expect(presetById('nothing').id, 'anthropic');
    expect(
        [for (final p in providerPresets) if (p.dataStaysInEu || p.euSwitch) p.id],
        ['bedrock-eu', 'mistral', 'scaleway', 'vercel']);
  });
}
