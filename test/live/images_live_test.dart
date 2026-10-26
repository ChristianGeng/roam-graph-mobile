/// Live image tests (#168): the app's real image code, asked in the real
/// way, with real keys, for each provider the app makes images with. They
/// cost a few cents per run, so the normal test step leaves them out
/// (`flutter test --exclude-tags live`); `.github/workflows/live-images.yml`
/// runs them.
///
/// The keys come from the environment: MISTRAL_API_KEY,
/// VERCEL_AI_GATEWAY_API_KEY and OPENROUTER_API_KEY. A missing key fails
/// its cases; nothing is skipped silently. A key is never printed: error
/// texts are written with every key value replaced by `***`.
///
/// When LIVE_RESULTS names a file, each case adds a line to it:
/// `<case>\tpassed|failed\t<one line>`. The workflow reads it for the
/// annotations, the issue and the release notes.
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_images.dart';
import 'package:roam_graph_mobile/ai/ai_models.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';

const mistralKey = 'MISTRAL_API_KEY';
const vercelKey = 'VERCEL_AI_GATEWAY_API_KEY';
const openRouterKey = 'OPENROUTER_API_KEY';

/// Short and synthetic: no real notes in a live test.
const shortPrompt = 'A red circle on white';

/// The long infographic prompt of #181: it names data and sources, which
/// once made Mistral answer with text and links instead of an image. The
/// central bank and the numbers are made up.
const longPrompt =
    'Erstelle eine Infografik über die Entwicklung der Leitzinsen der '
    'fiktiven Beispiel-Zentralbank in den letzten fünf Jahren. Daten '
    '(Jahresende): 2020: 0,00 %, 2021: 0,00 %, 2022: 2,50 %, 2023: 4,50 %, '
    '2024: 3,15 %, 2025: 2,15 %. Liniendiagramm mit beschrifteten Punkten, '
    'Titel "Zinsentwicklung 2020-2025". Quellen: [EZB Leitzinsen]'
    '(https://www.ecb.europa.eu/stats/policy_and_exchange_rates/'
    'key_ecb_interest_rates/html/index.en.html), '
    'https://www.ecb.eu/press/pr/date/2024/html/index.en.html.';

/// The secret [name], or a failure that names it.
String secret(String name) {
  final value = Platform.environment[name] ?? '';
  if (value.trim().isEmpty) fail('The secret $name is not set');
  return value.trim();
}

/// [text] on one line, without any key, cut short.
String clean(String text) {
  var result = text;
  for (final name in [mistralKey, vercelKey, openRouterKey]) {
    final value = (Platform.environment[name] ?? '').trim();
    if (value.isNotEmpty) result = result.replaceAll(value, '***');
  }
  result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
  return result.length <= 400 ? result : '${result.substring(0, 399)}…';
}

void record(String name, bool passed, String detail) {
  final path = Platform.environment['LIVE_RESULTS'];
  if (path == null || path.isEmpty) return;
  File(path).writeAsStringSync(
    '$name\t${passed ? 'passed' : 'failed'}\t${clean(detail)}\n',
    mode: FileMode.append,
  );
}

/// An image came back: PNG, JPEG or WebP bytes, larger than 1 kB.
String checkImage(MadeImage image) {
  expect(imageExtension(image.bytes), isNotNull,
      reason: 'the bytes are no PNG, JPEG or WebP image');
  expect(image.bytes.length, greaterThan(1024),
      reason: 'the image has ${image.bytes.length} bytes');
  return '${image.extension}, ${image.bytes.length} bytes';
}

/// The image config the app builds for the preset [id]: its connection and
/// paths, with [model] asked in the way [api].
ImageConfig configFor(
  String id,
  String keyName, {
  required String model,
  required ImageApi api,
  bool euOnly = false,
}) {
  final preset = presetById(id);
  return ImageConfig(
    ProviderConfig(
      name: preset.name,
      api: preset.api,
      baseUrl: preset.baseUrl,
      model: model,
      apiKey: secret(keyName),
      euOnly: euOnly,
    ),
    api: api,
    imagesPath: preset.imagesPath!,
  );
}

/// One case: [body] makes the image and returns what to report. The result
/// is recorded either way; a failure stays a failed test.
void liveCase(String name, Future<String> Function() body) {
  test(name, () async {
    try {
      final detail = await body();
      // ignore: avoid_print
      print('$name: passed ($detail)');
      record(name, true, detail);
    } on Object catch (e) {
      final text = e is AiError
          ? e.message
          : e is TestFailure
              ? (e.message ?? '$e')
              : '$e';
      // ignore: avoid_print
      print('$name: FAILED (${clean(text)})');
      record(name, false, text);
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

void main() {
  // One Mistral agent for both Mistral cases, as the app keeps one.
  final agents = MemoryImageAgents();

  group('Mistral', () {
    final preset = presetById('mistral');
    ImageConfig config() => configFor('mistral', mistralKey,
        model: preset.imageModel, api: preset.imageApi);

    liveCase('Mistral, short prompt', () async {
      final image = await makeImage(config(), shortPrompt, agents: agents);
      return checkImage(image);
    });

    liveCase('Mistral, long infographic prompt', () async {
      final image = await makeImage(config(), longPrompt, agents: agents);
      return checkImage(image);
    });
  });

  group('Vercel AI Gateway', () {
    final preset = presetById('vercel');

    liveCase('Vercel, Images API, cheapest image model', () async {
      // The cheapest image-only model of Vercel's list as it is today, by
      // the price the app reads from the list (the lowest across sizes and
      // qualities); the list is public.
      final models = await fetchModels(
        provider: preset.name,
        api: preset.api,
        baseUrl: preset.baseUrl,
        apiKey: secret(vercelKey),
        refresh: true,
      );
      final priced = [
        for (final m in models)
          if (m.images == true && m.chat != true && (m.imagePrice ?? 0) > 0)
            m,
      ]..sort((a, b) => a.imagePrice!.compareTo(b.imagePrice!));
      if (priced.isEmpty) {
        fail('Vercel\'s model list has no image-only model with a price');
      }
      final cheapest = priced.first;
      final image = await makeImage(
        configFor('vercel', vercelKey,
            model: cheapest.id, api: ImageApi.images),
        shortPrompt,
      );
      return '${cheapest.id} at \$${cheapest.imagePrice} per image: '
          '${checkImage(image)}';
    });

    liveCase('Vercel, chat with google/gemini-2.5-flash-image', () async {
      // The "EU only" path of the preset.
      final image = await makeImage(
        configFor('vercel', vercelKey,
            model: 'google/gemini-2.5-flash-image',
            api: ImageApi.chat,
            euOnly: true),
        shortPrompt,
      );
      return checkImage(image);
    });
  });

  group('OpenRouter', () {
    liveCase('OpenRouter, google/gemini-2.5-flash-image', () async {
      final image = await makeImage(
        configFor('openrouter', openRouterKey,
            model: 'google/gemini-2.5-flash-image', api: ImageApi.chat),
        shortPrompt,
      );
      return checkImage(image);
    });
  });
}
