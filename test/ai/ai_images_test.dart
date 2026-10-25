import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_images.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';

/// A 1×1 PNG.
const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==';

ImageConfig config(
        {ImageApi api = ImageApi.images,
        String path = '/images/generations',
        String model = 'openai/gpt-image-2',
        bool euOnly = false}) =>
    ImageConfig(
      ProviderConfig(
        name: 'Vercel AI Gateway',
        api: ApiKind.openAi,
        baseUrl: 'https://ai-gateway.vercel.sh/v1/',
        model: model,
        apiKey: 'v-key',
        euOnly: euOnly,
      ),
      api: api,
      imagesPath: path,
    );

void main() {
  late List<(Uri, Map<String, String>, Map<String, Object?>)> sent;
  HttpPost answer(Object reply, {int status = 200}) =>
      (url, headers, body) async {
        sent.add((url, headers, jsonDecode(body) as Map<String, Object?>));
        return HttpReply(status, jsonEncode(reply));
      };
  setUp(() => sent = []);

  test('the Images API: b64_json, at the provider\'s path', () async {
    final image = await makeImage(config(), 'A red fox',
        post: answer({
          'data': [
            {'b64_json': png},
          ],
        }));
    expect(image.extension, 'png');
    expect(image.bytes, base64.decode(png));
    final (url, headers, body) = sent.single;
    expect(url.toString(), 'https://ai-gateway.vercel.sh/v1/images/generations');
    expect(headers['authorization'], 'Bearer v-key');
    expect(body, {'model': 'openai/gpt-image-2', 'prompt': 'A red fox', 'n': 1});

    // OpenRouter's path, and a data: URL instead of b64_json.
    await makeImage(config(path: '/images'), 'x',
        post: answer({
          'data': [
            {'url': 'data:image/png;base64,$png'},
          ],
        }));
    expect(sent.last.$1.path, '/v1/images');
  });

  test('chat with image output, and "EU only"', () async {
    final image = await makeImage(
        config(
            api: ImageApi.chat,
            model: 'google/gemini-3.1-flash-image-preview',
            euOnly: true),
        'A red fox',
        post: answer({
          'choices': [
            {
              'message': {
                'content': 'Here it is.',
                'images': [
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/png;base64,$png'},
                  },
                ],
              },
            },
          ],
        }));
    expect(image.extension, 'png');
    final (url, _, body) = sent.single;
    expect(url.path, '/v1/chat/completions');
    expect(body['modalities'], ['image', 'text']);
    expect(body['messages'], [
      {'role': 'user', 'content': 'A red fox'},
    ]);
    expect(body['providerOptions'], isNotNull);
  });

  test('no image, no PNG/JPEG/WebP, or an error: said in plain words',
      () async {
    await expectLater(
        makeImage(config(), 'x', post: answer({'data': []})),
        throwsA(isA<AiError>().having(
            (e) => e.message, 'message', contains('sent no image'))));
    await expectLater(
        makeImage(config(), 'x',
            post: answer({
              'data': [
                {'b64_json': base64.encode(utf8.encode('<html>'))},
              ],
            })),
        throwsA(isA<AiError>().having(
            (e) => e.message, 'message', contains('no PNG, JPEG or WebP'))));
    await expectLater(
        makeImage(config(), 'x',
            post: answer({
              'error': {'message': 'quota'},
            }, status: 429)),
        throwsA(isA<AiError>()
            .having((e) => e.message, 'message', contains('quota'))));
    await expectLater(
        makeImage(config(model: ''), 'x', post: answer({})),
        throwsA(isA<AiError>().having(
            (e) => e.message, 'message', contains('Choose an image model'))));
    expect(sent, hasLength(3));
  });

  test('Qwen Image through DashScope: the link is downloaded (#112)',
      () async {
    final downloaded = <Uri>[];
    final image = await makeImage(
      ImageConfig(
        const ProviderConfig(
          name: 'Qwen (Alibaba Cloud)',
          api: ApiKind.openAi,
          baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
          model: 'qwen-image-2.0',
          apiKey: 'q-key',
        ),
        api: ImageApi.dashscope,
        imagesPath: '/api/v1/services/aigc/multimodal-generation/generation',
      ),
      'A red fox',
      post: answer({
        'output': {
          'choices': [
            {
              'message': {
                'content': [
                  {
                    'image':
                        'https://dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com/x.png?Expires=1',
                  },
                ],
              },
            },
          ],
        },
      }),
      download: (url, {headers = const {}}) async {
        downloaded.add(url);
        return base64.decode(png);
      },
    );
    expect(image.extension, 'png');
    final (url, headers, body) = sent.single;
    expect(url.toString(),
        'https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation');
    expect(headers['authorization'], 'Bearer q-key');
    expect((body['input'] as Map)['messages'], [
      {
        'role': 'user',
        'content': [
          {'text': 'A red fox'},
        ],
      },
    ]);
    expect(downloaded.single.host, endsWith('.aliyuncs.com'));
    // A link elsewhere is not followed.
    await expectLater(
        makeImage(
          ImageConfig(
            const ProviderConfig(
              name: 'Qwen',
              api: ApiKind.openAi,
              baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
              model: 'qwen-image-2.0',
              apiKey: 'q-key',
            ),
            api: ImageApi.dashscope,
            imagesPath: '/api/v1/x',
          ),
          'x',
          post: answer({
            'output': {
              'choices': [
                {
                  'message': {
                    'content': [
                      {'image': 'https://evil.example/x.png'},
                    ],
                  },
                },
              ],
            },
          }),
          download: (url, {headers = const {}}) async => base64.decode(png),
        ),
        throwsA(isA<AiError>().having(
            (e) => e.message, 'message', contains('does not download'))));
  });

  group('Mistral\'s image tool, through an agent (#126, #163)', () {
    ImageConfig mistral(
            {String baseUrl = 'https://api.mistral.ai/v1',
            String model = 'mistral-medium-latest'}) =>
        ImageConfig(
          ProviderConfig(
            name: 'Mistral',
            api: ApiKind.openAi,
            baseUrl: baseUrl,
            model: model,
            apiKey: 'm-key',
          ),
          api: ImageApi.mistral,
          imagesPath: '/conversations',
        );
    Map<String, Object?> chunks(List<Object?> content,
            {bool messages = true}) =>
        {
          'choices': [
            messages
                ? {
                    'messages': [
                      {'role': 'tool', 'content': 'image_generation'},
                      {'role': 'assistant', 'content': content},
                    ],
                  }
                : {
                    'message': {'role': 'assistant', 'content': content},
                  },
          ],
        };
    // Mistral's API: `POST /agents` makes the agent, `POST /conversations`
    // answers with [reply] (#163).
    HttpPost api(Object reply, {String agentId = 'ag-1'}) =>
        (url, headers, body) async {
          sent.add((url, headers, jsonDecode(body) as Map<String, Object?>));
          if (url.path.endsWith('/agents')) {
            return HttpReply(200, jsonEncode({'id': agentId, 'object': 'agent'}));
          }
          return HttpReply(200, jsonEncode(reply));
        };
    Map<String, Object?> conversation() =>
        sent.where((s) => s.$1.path.endsWith('/conversations')).last.$3;
    late List<(Uri, Map<String, String>)> downloads;
    ImageDownload bytes(List<int> data) => (url, {headers = const {}}) async {
          downloads.add((url, headers));
          return Uint8List.fromList(data);
        };
    setUp(() => downloads = []);

    Map<String, Object?> outputs(List<Object?> content) => {
          'conversation_id': 'c-1',
          'outputs': [
            {'type': 'tool.execution', 'name': 'image_generation'},
            {'type': 'message.output', 'role': 'assistant', 'content': content},
          ],
        };

    test('the requests: an agent with the image tool, then a conversation',
        () async {
      final agents = MemoryImageAgents();
      await makeImage(mistral(), 'A red fox',
          post: api(outputs([
            {'type': 'text', 'text': 'Here it is.'},
            {
              'type': 'tool_file',
              'tool': 'image_generation',
              'file_id': 'f-1',
              'file_name': 'image_generated_0',
              'file_type': 'png',
            },
          ])),
          download: bytes(base64.decode(png)),
          agents: agents);
      expect(sent, hasLength(2));
      final (agentUrl, agentHeaders, agent) = sent.first;
      expect(agentUrl.toString(), 'https://api.mistral.ai/v1/agents');
      expect(agentHeaders['authorization'], 'Bearer m-key');
      expect(agent, {
        'model': 'mistral-medium-latest',
        'name': 'Roam Graph images',
        'description': contains('Create image'),
        'instructions': mistralAgentInstructions,
        'tools': [
          {'type': 'image_generation'},
        ],
      });
      final (url, headers, body) = sent.last;
      expect(url.toString(), 'https://api.mistral.ai/v1/conversations');
      expect(headers['authorization'], 'Bearer m-key');
      expect(body, {'agent_id': 'ag-1', 'inputs': 'A red fox', 'store': false});
      expect(agents.ids, {'mistral-medium-latest': 'ag-1'});
      final (fileUrl, fileHeaders) = downloads.single;
      expect(fileUrl.toString(), 'https://api.mistral.ai/v1/files/f-1/content');
      expect(fileHeaders, {'authorization': 'Bearer m-key'});
    });

    // The answer as Mistral sent it in October 2026: the link in the tool's
    // entry and as Markdown in the text, no tool_file chunk.
    const storage = 'https://mistralaiblackforestprod.blob.core.windows.net/'
        'images/blackforest/1e61/image.jpg?se=2026&sig=abc%3D';
    Map<String, Object?> realAnswer({bool toolEntry = true}) => {
          'object': 'conversation.response',
          'conversation_id': 'conv-1',
          'outputs': [
            if (toolEntry)
              {
                'object': 'entry',
                'type': 'tool.execution',
                'name': 'image_generation',
                'function': 'generate_image',
                'arguments': '{"prompt": "A red circle"}',
                'info': {'result': jsonEncode({'url': storage})},
              },
            {
              'object': 'entry',
              'type': 'message.output',
              'role': 'assistant',
              'content': 'Here is your image.\n\n![Red circle]($storage)',
            },
          ],
          'guardrails': null,
        };

    test("Mistral's real answer: the link in the tool entry, no key sent",
        () async {
      final image = await makeImage(mistral(), 'A red circle',
          post: api(realAnswer()),
          download: bytes(base64.decode(png)),
          agents: MemoryImageAgents());
      expect(image.extension, 'png');
      final (url, headers) = downloads.single;
      expect(url.toString(), storage);
      expect(headers, isEmpty);
    });

    test('a Markdown link in the text is enough, with or without "!"',
        () async {
      await makeImage(mistral(), 'A red circle',
          post: api(realAnswer(toolEntry: false)),
          download: bytes(base64.decode(png)),
          agents: MemoryImageAgents());
      expect(downloads.single.$1.toString(), storage);
      downloads.clear();
      await makeImage(mistral(), 'A red circle',
          post: api({
            'outputs': [
              {
                'type': 'message.output',
                'role': 'assistant',
                'content': 'Here it is: [Red circle]($storage)',
              },
            ],
          }),
          download: bytes(base64.decode(png)),
          agents: MemoryImageAgents());
      expect(downloads.single.$1.toString(), storage);
    });

    test('Markdown in text chunks; an unrelated link before the image',
        () async {
      await makeImage(mistral(), 'A red circle',
          post: api({
            'outputs': [
              {
                'type': 'message.output',
                'role': 'assistant',
                'content': [
                  {
                    'type': 'text',
                    'text': 'See [the docs](https://docs.mistral.ai/x). '
                        'Here it is: ![Red circle]($storage)',
                  },
                ],
              },
            ],
          }),
          download: bytes(base64.decode(png)),
          agents: MemoryImageAgents());
      expect(downloads.single.$1.toString(), storage);
    });

    test('a link to another storage account is refused, not downloaded',
        () async {
      const other = 'https://mistralaiother.blob.core.windows.net/x.png';
      await expectLater(
          makeImage(mistral(), 'A red circle',
              post: api({
                'outputs': [
                  {
                    'type': 'tool.execution',
                    'name': 'image_generation',
                    'info': {'result': jsonEncode({'url': other})},
                  },
                ],
              }),
              download: bytes(base64.decode(png)),
              agents: MemoryImageAgents()),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', contains('does not download'))));
      expect(downloads, isEmpty);
    });

    test('only Mistral storage hosts are downloaded', () {
      expect(isMistralImageUrl(Uri.parse(storage)), isTrue);
      expect(isMistralImageUrl(Uri.parse('https://files.mistral.ai/x.png')),
          isTrue);
      expect(
          isMistralImageUrl(
              Uri.parse('https://evil.blob.core.windows.net/x.png')),
          isFalse);
      // Anyone can name a storage account: only the one seen is allowed.
      expect(
          isMistralImageUrl(Uri.parse(
              'https://mistralaiother.blob.core.windows.net/x.png')),
          isFalse);
      expect(
          isMistralImageUrl(Uri.parse(
              'http://mistralaiblackforestprod.blob.core.windows.net/x')),
          isFalse);
    });

    test('the agent is made once and used again; one per image model',
        () async {
      final agents = MemoryImageAgents();
      final reply = outputs([
        {'type': 'tool_file', 'tool': 'image_generation', 'file_id': 'f-1'},
      ]);
      for (final prompt in ['A red fox', 'A blue bird']) {
        await makeImage(mistral(), prompt,
            post: api(reply),
            download: bytes(base64.decode(png)),
            agents: agents);
      }
      expect(sent.map((s) => s.$1.path), [
        '/v1/agents',
        '/v1/conversations',
        '/v1/conversations',
      ]);
      expect(conversation(),
          {'agent_id': 'ag-1', 'inputs': 'A blue bird', 'store': false});
      // Another image model in settings: a new agent for it.
      sent.clear();
      await makeImage(mistral(model: 'mistral-large-latest'), 'x',
          post: api(reply, agentId: 'ag-2'),
          download: bytes(base64.decode(png)),
          agents: agents);
      expect(sent.first.$3['model'], 'mistral-large-latest');
      expect(conversation()['agent_id'], 'ag-2');
      expect(agents.ids, {
        'mistral-medium-latest': 'ag-1',
        'mistral-large-latest': 'ag-2',
      });
    });

    test('an agent Mistral no longer knows is made again, once', () async {
      final agents = MemoryImageAgents()..ids['mistral-medium-latest'] = 'ag-old';
      final image = outputs([
        {'type': 'tool_file', 'tool': 'image_generation', 'file_id': 'f-1'},
      ]);
      for (final (status, message) in [
        (404, 'Agent not found'),
        (422, 'Agent ag-old does not exist'),
      ]) {
        sent.clear();
        agents.ids['mistral-medium-latest'] = 'ag-old';
        await makeImage(mistral(), 'x',
            post: (url, headers, body) async {
              sent.add(
                  (url, headers, jsonDecode(body) as Map<String, Object?>));
              final json = jsonDecode(body) as Map;
              if (url.path.endsWith('/agents')) {
                return HttpReply(200, jsonEncode({'id': 'ag-new'}));
              }
              return json['agent_id'] == 'ag-old'
                  ? HttpReply(status, jsonEncode({'message': message}))
                  : HttpReply(200, jsonEncode(image));
            },
            download: bytes(base64.decode(png)),
            agents: agents);
        expect(sent.map((s) => (s.$1.path, s.$3['agent_id'])), [
          ('/v1/conversations', 'ag-old'),
          ('/v1/agents', null),
          ('/v1/conversations', 'ag-new'),
        ]);
        expect(agents.ids['mistral-medium-latest'], 'ag-new');
      }

      // Not known again after it was made: said, not made a second time.
      sent.clear();
      agents.ids['mistral-medium-latest'] = 'ag-old';
      await expectLater(
          makeImage(mistral(), 'x',
              post: (url, headers, body) async {
                sent.add(
                    (url, headers, jsonDecode(body) as Map<String, Object?>));
                if (url.path.endsWith('/agents')) {
                  return HttpReply(200, jsonEncode({'id': 'ag-new'}));
                }
                return HttpReply(404, jsonEncode({'message': 'Agent not found'}));
              },
              download: bytes(base64.decode(png)),
              agents: agents),
          throwsA(isA<AiError>().having((e) => e.status, 'status', 404)));
      expect(sent.where((s) => s.$1.path.endsWith('/agents')), hasLength(1));

      // Another refusal is not taken for a missing agent.
      sent.clear();
      agents.ids['mistral-medium-latest'] = 'ag-old';
      await expectLater(
          makeImage(mistral(), 'x',
              post: (url, headers, body) async {
                sent.add(
                    (url, headers, jsonDecode(body) as Map<String, Object?>));
                return HttpReply(
                    401, jsonEncode({'message': 'Unauthorized'}));
              },
              download: bytes(base64.decode(png)),
              agents: agents),
          throwsA(isA<AiError>().having((e) => e.status, 'status', 401)));
      expect(sent, hasLength(1));
      expect(agents.ids['mistral-medium-latest'], 'ag-old');
    });

    test('an answer without an agent ID: said plainly', () async {
      await expectLater(
          makeImage(mistral(), 'x',
              post: (url, headers, body) async =>
                  HttpReply(200, jsonEncode({'object': 'agent'})),
              download: bytes(base64.decode(png))),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', contains('no agent ID'))));
    });

    test('text that only repeats the prompt: the tool did not run',
        () async {
      for (final said in ['A red fox', ' "a red  fox." ']) {
        await expectLater(
            makeImage(mistral(), 'A red fox',
                post: api(outputs([
                  {'type': 'text', 'text': said},
                ])),
                download: bytes(base64.decode(png))),
            throwsA(isA<AiError>().having((e) => e.message, 'message',
                allOf(startsWith('Mistral did not run its image tool.'),
                    isNot(contains('only text'))))));
      }
    });

    test('no image, only text: the text is said, and no same-model advice',
        () async {
      await expectLater(
          makeImage(mistral(), 'x',
              post: api(outputs([
                {'type': 'text', 'text': 'I cannot generate images.'},
              ])),
              download: bytes(base64.decode(png))),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              allOf(contains('only text: "I cannot generate images."'),
                  isNot(contains('try mistral-medium-latest'))))));
    });

    test('a tool message is not quoted as what Mistral said', () async {
      await expectLater(
          makeImage(mistral(), 'x',
              post: api(chunks([
                {'type': 'text', 'text': 'No picture today.'},
              ])),
              download: bytes(base64.decode(png))),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              allOf(contains('"No picture today."'),
                  isNot(contains('image_generation'))))));
    });

    test('a link in choices[].messages[] or choices[].message, downloaded',
        () async {
      for (final inMessages in [true, false]) {
        downloads.clear();
        final image = await makeImage(mistral(), 'x',
            post: api(chunks([
              {
                'type': 'image_url',
                // Also as a plain string, as Mistral's cookbook shows it.
                'image_url': inMessages
                    ? 'https://files.mistral.ai/generated/a.png'
                    : {'url': 'https://files.mistral.ai/generated/a.png'},
              },
            ], messages: inMessages)),
            download: bytes(base64.decode(png)));
        expect(image.extension, 'png');
        final (url, headers) = downloads.single;
        expect(url.toString(), 'https://files.mistral.ai/generated/a.png');
        expect(headers, {'authorization': 'Bearer m-key'});
      }
    });

    test('a tool_file: fetched from the Files API, with the key', () async {
      final image = await makeImage(mistral(), 'x',
          post: api(chunks([
            {
              'type': 'tool_file',
              'tool': 'image_generation',
              'file_id': 'f-1',
              'file_type': 'png',
            },
          ])),
          download: bytes(base64.decode(png)));
      expect(image.extension, 'png');
      final (url, headers) = downloads.single;
      expect(url.toString(), 'https://api.mistral.ai/v1/files/f-1/content');
      expect(headers, {'authorization': 'Bearer m-key'});
      // A file ID from another host than api.mistral.ai is not fetched.
      await expectLater(
          makeImage(mistral(baseUrl: 'https://proxy.example/v1'), 'x',
              post: api(chunks([
                {'type': 'tool_file', 'file_id': 'f-1'},
              ])),
              download: bytes(base64.decode(png))),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              contains('only from api.mistral.ai'))));
      expect(downloads, hasLength(1));
    });

    test('a link to another host is not followed, nor sent the key',
        () async {
      for (final link in [
        'https://evil.example/a.png',
        'http://files.mistral.ai/a.png',
        'https://files.mistral.ai.evil.example/a.png',
      ]) {
        await expectLater(
            makeImage(mistral(), 'x',
                post: api(chunks([
                  {'type': 'image_url', 'image_url': link},
                ])),
                download: bytes(base64.decode(png))),
            throwsA(isA<AiError>().having(
                (e) => e.message, 'message', contains('does not download'))));
      }
      expect(downloads, isEmpty);
    });

    test('no image, no image bytes, a failed download: said plainly',
        () async {
      await expectLater(
          makeImage(mistral(), 'x',
              post: api(chunks([
                {'type': 'text', 'text': 'I cannot draw.'},
              ])),
              download: bytes(base64.decode(png))),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', contains('Mistral sent no image'))));
      await expectLater(
          makeImage(mistral(), 'x',
              post: api(chunks([
                {
                  'type': 'image_url',
                  'image_url': 'https://files.mistral.ai/generated/a.png',
                },
              ])),
              download: bytes(utf8.encode('<html>not an image</html>'))),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', contains('no PNG, JPEG or WebP'))));
      await expectLater(
          makeImage(mistral(), 'x',
              post: api(chunks([
                {
                  'type': 'image_url',
                  'image_url': 'https://files.mistral.ai/generated/a.png',
                },
              ])),
              download: (url, {headers = const {}}) async => throw const AiError(
                  'The image could not be downloaded (HTTP 403).')),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              'Mistral made an image, but the image could not be downloaded '
                  '(HTTP 403).')));
    });
  });

  test('"EU only" and a model without an EU route: said plainly', () async {
    await expectLater(
        makeImage(config(euOnly: true), 'x',
            post: answer({
              'error': {
                'message': 'No provider for openai/gpt-image-2 supports the '
                    'requested inference region.',
              },
            }, status: 400)),
        throwsA(isA<NoEuRouteError>().having((e) => e.message, 'message',
            contains('has no EU route, and "EU only" is on'))));
  });

  test('image kinds by their first bytes', () {
    expect(imageExtension(base64.decode(png)), 'png');
    expect(imageExtension(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'jpg');
    expect(
        imageExtension(Uint8List.fromList(
            [...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBP')])),
        'webp');
    expect(imageExtension(Uint8List.fromList(ascii.encode('GIF89a'))), isNull);
  });
}
