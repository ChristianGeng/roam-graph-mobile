/// The models a provider offers (#75), from its model list, so a model can
/// be picked instead of typed.
///
/// Pure Dart (no Flutter); HTTP goes through [HttpGet], which tests
/// replace.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_chat.dart';
import 'ai_providers.dart';

/// Sends a GET request; tests replace it.
typedef HttpGet =
    Future<HttpReply> Function(Uri url, Map<String, String> headers);

/// [HttpGet] with `dart:io`, without redirects, as `postWithDartIo`.
Future<HttpReply> getWithDartIo(Uri url, Map<String, String> headers) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'RoamGraph';
  try {
    final request = await client.getUrl(url);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 60));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 60));
    return HttpReply(response.statusCode, text);
  } finally {
    client.close(force: true);
  }
}

/// One model of a provider's list, with what the list says about it.
class ModelInfo {
  const ModelInfo(
    this.id, {
    this.name,
    this.tools,
    this.inputPrice,
    this.outputPrice,
    this.regions,
  });

  final String id;

  /// A readable name, where the list gives one.
  final String? name;

  /// Whether the model can call tools, which the chat needs; null when the
  /// list does not say.
  final bool? tools;

  /// US dollars per million tokens, in and out; null when not given.
  final double? inputPrice;
  final double? outputPrice;

  /// Regions the model can run in (Vercel AI Gateway's `regions`); null
  /// when the list does not say.
  final List<String>? regions;

  /// Whether the model runs in the EU: true or false where the list says,
  /// null where it does not.
  bool? get inEu => regions?.contains('eu');
}

/// Reads [json], a model list in the shape the OpenAI-compatible APIs and
/// Anthropic's use: `{"data": [{"id": …}, …]}`. What a provider adds is
/// read where it is known: OpenRouter's `supported_parameters` and
/// `pricing.prompt`/`completion`, Mistral's `capabilities.function_calling`,
/// Vercel's `pricing.input`/`output`, `regions` and `tags`, Hugging Face's
/// `providers[].supports_tools`, Anthropic's `display_name`. Anthropic's
/// models all call tools.
List<ModelInfo> readModelList(Object? json, {required ApiKind api}) {
  final data = json is Map ? json['data'] : json;
  if (data is! List) {
    throw const AiError(
      'The provider sent a model list the app cannot '
      'read. Type the model instead.',
    );
  }
  double? perMillion(Object? value) {
    final price = value is num ? value.toDouble() : double.tryParse('$value');
    return price == null || price < 0 ? null : price * 1e6;
  }

  final models = <ModelInfo>[];
  for (final entry in data.whereType<Map<Object?, Object?>>()) {
    final id = entry['id'];
    if (id is! String || id.isEmpty) continue;
    bool? tools;
    final parameters = entry['supported_parameters'];
    final capabilities = entry['capabilities'];
    final tags = entry['tags'];
    final providers = entry['providers'];
    if (api == ApiKind.anthropic) {
      tools = true;
    } else if (parameters is List) {
      tools = parameters.contains('tools');
    } else if (capabilities is Map &&
        capabilities['function_calling'] is bool) {
      tools = capabilities['function_calling'] as bool;
    } else if (tags is List) {
      tools = tags.contains('tool-use');
    } else if (providers is List) {
      tools = providers.whereType<Map<Object?, Object?>>().any(
        (p) => p['supports_tools'] == true,
      );
    }
    final pricing = entry['pricing'];
    final regions = entry['regions'];
    models.add(
      ModelInfo(
        id,
        name: switch (entry['display_name'] ?? entry['name']) {
          final String name when name.isNotEmpty && name != id => name,
          _ => null,
        },
        tools: tools,
        inputPrice: pricing is Map
            ? perMillion(pricing['input'] ?? pricing['prompt'])
            : null,
        outputPrice: pricing is Map
            ? perMillion(pricing['output'] ?? pricing['completion'])
            : null,
        regions: regions is List ? [for (final r in regions) '$r'] : null,
      ),
    );
  }
  models.sort((a, b) => a.id.compareTo(b.id));
  return models;
}

/// Model lists fetched this session, by provider and base URL.
final _cache = <String, List<ModelInfo>>{};

/// The models of the provider at [baseUrl] with [apiKey]: `GET
/// {base}/models` for OpenAI-compatible APIs, `GET {base}/v1/models` for
/// Anthropic's. Kept for the session; [refresh] fetches again. Throws
/// [AiError] with what to do.
Future<List<ModelInfo>> fetchModels({
  required String provider,
  required ApiKind api,
  required String baseUrl,
  required String apiKey,
  HttpGet get = getWithDartIo,
  bool refresh = false,
}) async {
  var base = baseUrl.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  if (base.isEmpty) {
    throw AiError('No base URL for $provider. Enter it first.');
  }
  final key = '$provider $api $base';
  final cached = _cache[key];
  if (!refresh && cached != null) return cached;
  final url = Uri.parse(
    api == ApiKind.anthropic ? '$base/v1/models?limit=1000' : '$base/models',
  );
  if (url.scheme != 'https' && apiKey.isNotEmpty) {
    throw const AiError(
      'The app sends an API key only over HTTPS. Use an '
      'https:// base URL.',
    );
  }
  HttpReply reply;
  try {
    reply = await get(url, {
      if (api == ApiKind.anthropic) ...{
        'anthropic-version': '2023-06-01',
        if (apiKey.isNotEmpty) 'x-api-key': apiKey,
      } else if (apiKey.isNotEmpty)
        'authorization': 'Bearer $apiKey',
    });
  } on SocketException catch (e) {
    throw AiError('No connection to ${url.host}: ${e.message}.');
  } on TimeoutException {
    throw AiError('${url.host} did not answer in time.');
  } on HttpException catch (e) {
    throw AiError('The connection to ${url.host} failed: ${e.message}.');
  }
  if (reply.status == 401 || reply.status == 403) {
    throw AiError(
      apiKey.isEmpty
          ? '$provider needs the API key for its model list. Enter the key '
                'first.'
          : '$provider refused the API key (HTTP ${reply.status}).',
    );
  }
  if (reply.status == 404) {
    throw AiError(
      '$provider has no model list at this base URL (HTTP '
      '404). Type the model instead.',
    );
  }
  if (reply.status < 200 || reply.status >= 300) {
    throw AiError(
      '$provider answered with an error (HTTP '
      '${reply.status}). Type the model instead.',
    );
  }
  Object? json;
  try {
    json = jsonDecode(reply.body);
  } on FormatException {
    json = null;
  }
  final models = readModelList(json, api: api);
  _cache[key] = models;
  return models;
}

/// Forgets the lists of this session, for tests.
void clearModelCache() => _cache.clear();
