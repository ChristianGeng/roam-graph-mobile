/// Weekly check of the recommended models (#190): every model in
/// `lib/ai/model_advice.dart` for Mistral, Vercel AI Gateway and OpenRouter
/// must still be in the provider's model list. It only fetches the lists:
/// no paid request. `.github/workflows/live-advice.yml` runs it.
///
/// The keys come from the environment: MISTRAL_API_KEY,
/// VERCEL_AI_GATEWAY_API_KEY and OPENROUTER_API_KEY. A key is never
/// printed: texts are written with every key value replaced by `***`.
///
/// When LIVE_RESULTS names a file, each model adds a line to it:
/// `<provider> <model>\tpassed|missing|error\t<one line>`. "missing" means
/// the list was read and the model is not in it; "error" means the list
/// could not be read, which is no reason to open the issue.
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_models.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/model_advice.dart';

const keyNames = {
  'mistral': 'MISTRAL_API_KEY',
  'vercel': 'VERCEL_AI_GATEWAY_API_KEY',
  'openrouter': 'OPENROUTER_API_KEY',
};

/// [text] on one line, without any key, cut short.
String clean(String text) {
  var result = text;
  for (final name in keyNames.values) {
    final value = (Platform.environment[name] ?? '').trim();
    if (value.isNotEmpty) result = result.replaceAll(value, '***');
  }
  result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
  return result.length <= 400 ? result : '${result.substring(0, 399)}…';
}

void record(String name, String status, String detail) {
  final path = Platform.environment['LIVE_RESULTS'];
  if (path == null || path.isEmpty) return;
  File(path).writeAsStringSync(
    '$name\t$status\t${clean(detail)}\n',
    mode: FileMode.append,
  );
}

void main() {
  for (final entry in keyNames.entries) {
    final preset = presetById(entry.key);
    test('${preset.name}: recommended models are listed', () async {
      final key = (Platform.environment[entry.value] ?? '').trim();
      final advice = adviceForProvider(preset.id);
      Set<String> listed;
      if (key.isEmpty) {
        for (final a in advice) {
          record('${preset.id} ${a.model}', 'error',
              'The secret ${entry.value} is not set');
        }
        fail('The secret ${entry.value} is not set');
      }
      try {
        final models = await fetchModels(
          provider: preset.name,
          api: preset.api,
          baseUrl: preset.baseUrl,
          apiKey: key,
        );
        listed = {for (final m in models) m.id};
      } on AiError catch (e) {
        for (final a in advice) {
          record('${preset.id} ${a.model}', 'error', e.message);
        }
        fail(clean(e.message));
      }
      if (listed.isEmpty) {
        for (final a in advice) {
          record('${preset.id} ${a.model}', 'error', 'The list is empty');
        }
        fail('${preset.name} sent an empty model list');
      }
      final missing = <String>[];
      for (final a in advice) {
        final name = '${preset.id} ${a.model}';
        if (isListed(a.model, listed)) {
          record(name, 'passed', 'listed (${listed.length} models)');
        } else {
          record(name, 'missing', 'not in the list of ${preset.name}');
          missing.add(a.model);
        }
      }
      expect(missing, isEmpty, reason: 'not listed: ${missing.join(', ')}');
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
