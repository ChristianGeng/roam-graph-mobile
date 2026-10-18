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
