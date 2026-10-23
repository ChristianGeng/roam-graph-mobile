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

  group('Mistral\'s image tool (#126)', () {
    ImageConfig mistral({String baseUrl = 'https://api.mistral.ai/v1'}) =>
        ImageConfig(
          ProviderConfig(
            name: 'Mistral',
            api: ApiKind.openAi,
            baseUrl: baseUrl,
            model: 'mistral-medium-latest',
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

    test('the request: the Conversations API with the image_generation tool',
        () async {
      await makeImage(mistral(), 'A red fox',
          post: answer(outputs([
            {'type': 'text', 'text': 'Here it is.'},
            {
              'type': 'tool_file',
              'tool': 'image_generation',
              'file_id': 'f-1',
              'file_name': 'image_generated_0',
              'file_type': 'png',
            },
          ])),
          download: bytes(base64.decode(png)));
      final (url, headers, body) = sent.single;
      expect(url.toString(), 'https://api.mistral.ai/v1/conversations');
      expect(headers['authorization'], 'Bearer m-key');
      expect(body['model'], 'mistral-medium-latest');
      expect(body['inputs'], 'A red fox');
      expect(body['tools'], [
        {'type': 'image_generation'},
      ]);
      expect(body['store'], false);
      expect(body['instructions'], contains('image generation tool'));
      final (fileUrl, _) = downloads.single;
      expect(fileUrl.toString(), 'https://api.mistral.ai/v1/files/f-1/content');
    });

    test('no image, only text: the text is said, and no same-model advice',
        () async {
      await expectLater(
          makeImage(mistral(), 'x',
              post: answer(outputs([
                {'type': 'text', 'text': 'I cannot generate images.'},
              ])),
              download: bytes(base64.decode(png))),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              allOf(contains('only text: "I cannot generate images."'),
                  isNot(contains('try mistral-medium-latest'))))));
    });

    test('a link in choices[].messages[] or choices[].message, downloaded',
        () async {
      for (final inMessages in [true, false]) {
        downloads.clear();
        final image = await makeImage(mistral(), 'x',
            post: answer(chunks([
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
          post: answer(chunks([
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
              post: answer(chunks([
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
                post: answer(chunks([
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
              post: answer(chunks([
                {'type': 'text', 'text': 'I cannot draw.'},
              ])),
              download: bytes(base64.decode(png))),
          throwsA(isA<AiError>().having(
              (e) => e.message, 'message', contains('Mistral sent no image'))));
      await expectLater(
          makeImage(mistral(), 'x',
              post: answer(chunks([
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
              post: answer(chunks([
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
