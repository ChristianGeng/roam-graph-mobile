/// Images made by an AI model (#112), in the two ways providers offer:
/// the Images API (`/images/generations`, OpenRouter's `/images`) and chat
/// with image output (Vercel AI Gateway's `modalities`). Checked against
/// Vercel's and OpenRouter's documentation on 2026-10-18.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ai_chat.dart';
import 'ai_providers.dart';

/// What "Create image" needs: the provider with its image model, how to
/// ask it, and where.
class ImageConfig {
  const ImageConfig(this.provider,
      {required this.api, required this.imagesPath});

  /// The connection, with the image model as its model.
  final ProviderConfig provider;
  final ImageApi api;

  /// The Images API's path after the base URL.
  final String imagesPath;
}

/// An image the model made: its bytes, and the file extension they are.
class MadeImage {
  const MadeImage(this.bytes, this.extension);

  final Uint8List bytes;

  /// `png`, `jpg` or `webp`, from the bytes themselves.
  final String extension;
}

/// The extension of [bytes] when they are a PNG, JPEG or WebP image;
/// null for anything else, which is not saved.
String? imageExtension(Uint8List bytes) {
  bool starts(List<int> magic, [int at = 0]) {
    if (bytes.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
  if (starts([0xFF, 0xD8, 0xFF])) return 'jpg';
  if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)) {
    return 'webp';
  }
  return null;
}

/// Downloads an image the provider made, with [headers] (the API key,
/// only for the provider's own host); tests replace it.
typedef ImageDownload = Future<Uint8List> Function(Uri url,
    {Map<String, String> headers});

/// The most bytes an image may have.
const maxImageBytes = 30 * 1024 * 1024;

/// [ImageDownload] with `dart:io`: no redirects, a time limit, and at most
/// [maxImageBytes].
Future<Uint8List> downloadWithDartIo(Uri url,
    {Map<String, String> headers = const {}}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'RoamGraph';
  try {
    final request = await client.getUrl(url);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response =
        await request.close().timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) {
      throw AiError('The image could not be downloaded (HTTP '
          '${response.statusCode}).');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(minutes: 2))) {
      bytes.add(chunk);
      if (bytes.length > maxImageBytes) {
        throw const AiError('The image is too large to save.');
      }
    }
    return bytes.takeBytes();
  } on SocketException catch (e) {
    throw AiError('The image could not be downloaded: ${e.message}.');
  } on HandshakeException catch (e) {
    throw AiError('No secure connection for the image download: '
        '${e.message}.');
  } on HttpException catch (e) {
    throw AiError('The image could not be downloaded: ${e.message}.');
  } on TimeoutException {
    throw const AiError('The image download took too long. Try again.');
  } finally {
    client.close(force: true);
  }
}

/// Whether [url] is where DashScope puts the images it makes: Alibaba
/// Cloud's object storage, over HTTPS. Nothing else is downloaded.
bool isDashscopeImageUrl(Uri url) =>
    url.scheme == 'https' && url.host.endsWith('.aliyuncs.com');

/// Whether [url] is Mistral's file host, where its image tool puts the
/// images it makes (#126), over HTTPS. Nothing else is downloaded.
bool isMistralImageUrl(Uri url) =>
    url.scheme == 'https' && url.host == 'files.mistral.ai';

/// Where the app keeps the ID of the Mistral agent it made for an image
/// model (#163): in its AI settings, not in the notes, and not with the
/// key. Tests replace it.
abstract interface class ImageAgents {
  /// The agent's ID for [model], or null when there is none yet.
  String? read(String model);

  /// Keeps [id] as the agent for [model].
  Future<void> write(String model, String id);
}

/// [ImageAgents] kept only while the app runs.
class MemoryImageAgents implements ImageAgents {
  final Map<String, String> ids = {};

  @override
  String? read(String model) => ids[model];

  @override
  Future<void> write(String model, String id) async => ids[model] = id;
}

/// What the app's Mistral agent for images is told (#163).
const mistralAgentInstructions =
    'Use the image generation tool to make the image the user describes.';

/// The error when "EU only" is on and the image model has no EU route;
/// "Create image" then offers to make this one image outside the EU
/// (#127).
class NoEuRouteError extends AiError {
  const NoEuRouteError(super.message);
}

/// Asks [config]'s image model for a picture of [prompt]. Throws
/// [AiError] in plain words. For Mistral, [agents] keeps the ID of the
/// agent with the image tool; without it, a new agent is made each time.
Future<MadeImage> makeImage(ImageConfig config, String prompt,
    {HttpPost post = postWithDartIo,
    ImageDownload download = downloadWithDartIo,
    ImageAgents? agents}) async {
  final provider = config.provider;
  if (provider.model.trim().isEmpty) {
    throw AiError('Choose an image model for ${provider.name} in AI '
        'settings.');
  }
  if (provider.keyRequired && provider.apiKey.isEmpty) {
    throw AiError('Enter the API key for ${provider.name} in AI settings.');
  }
  var base = provider.baseUrl.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final chat = config.api == ImageApi.chat;
  final dashscope = config.api == ImageApi.dashscope;
  final mistral = config.api == ImageApi.mistral;
  final Uri url;
  try {
    final baseUri = Uri.parse(base);
    url = dashscope
        // DashScope's path starts at the host, not at the base URL's
        // compatible-mode/v1.
        ? baseUri.replace(path: config.imagesPath, query: null)
        : Uri.parse(chat
            ? '$base/chat/completions'
            // Mistral's image tool works through an agent in its
            // Conversations API (#163), not Chat Completions.
            : mistral
                ? '$base/conversations'
                : '$base${config.imagesPath}');
  } on FormatException {
    throw AiError('The base URL of ${provider.name} is not a valid URL.');
  }
  if (url.scheme != 'https' && provider.apiKey.isNotEmpty) {
    throw const AiError('The app sends an API key only over HTTPS. Use an '
        'https:// base URL.');
  }
  final headers = {
    'content-type': 'application/json',
    if (provider.apiKey.isNotEmpty)
      'authorization': 'Bearer ${provider.apiKey}',
  };
  if (mistral) {
    return _mistralImage(provider, prompt, Uri.parse('$base/agents'), url,
        headers, post, download, agents ?? MemoryImageAgents());
  }
  final body = <String, Object?>{
    'model': provider.model,
    if (dashscope) ...{
      'input': {
        'messages': [
          {
            'role': 'user',
            'content': [
              {'text': prompt},
            ],
          },
        ],
      },
      'parameters': {
        'size': '1024*1024',
        'n': 1,
        'watermark': false,
      },
    } else if (chat) ...{
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'modalities': ['image', 'text'],
      'stream': false,
    } else ...{
      'prompt': prompt,
      'n': 1,
    },
    // Vercel AI Gateway: inference and stored data in the EU.
    if (provider.euOnly)
      'providerOptions': {
        'gateway': {
          'inferenceRegion': {'scope': 'zone', 'geoRegion': 'eu'},
        },
      },
  };
  final Map<String, Object?> json;
  try {
    json = await postJson(provider, url, headers, body, post);
  } on AiError catch (e) {
    // Vercel with "EU only": the model has no route in the EU.
    if (provider.euOnly &&
        e.message.toLowerCase().contains('inference region')) {
      throw NoEuRouteError('"${provider.model}" has no EU route, and "EU only" is '
          'on for ${provider.name}. Choose an image model that runs in the '
          'EU ("Choose model" marks the others), or turn "EU only" off in AI '
          'settings.');
    }
    rethrow;
  }
  if (dashscope) {
    final link = _fromDashscope(json);
    if (link == null) {
      throw AiError('${provider.name} sent no image. The model '
          '"${provider.model}" may not make images.');
    }
    final Uri imageUrl;
    try {
      imageUrl = Uri.parse(link);
    } on FormatException {
      throw AiError('${provider.name} sent an image link the app cannot read.');
    }
    if (!isDashscopeImageUrl(imageUrl)) {
      throw AiError('${provider.name} sent an image link to '
          '${imageUrl.host}, which the app does not download.');
    }
    final bytes = await download(imageUrl);
    final extension = imageExtension(bytes);
    if (extension == null) {
      throw AiError('${provider.name} sent something that is no PNG, JPEG '
          'or WebP image; nothing is saved.');
    }
    return MadeImage(bytes, extension);
  }
  final encoded = chat ? _fromChat(json) : _fromImages(json);
  if (encoded == null) {
    throw AiError('${provider.name} sent no image. The model '
        '"${provider.model}" may not make images, or not this way: check '
        '"How the image model is asked" in AI settings.');
  }
  final Uint8List bytes;
  try {
    bytes = base64.decode(encoded);
  } on FormatException {
    throw AiError('${provider.name} sent an image the app cannot read.');
  }
  final extension = imageExtension(bytes);
  if (extension == null) {
    throw AiError('${provider.name} sent something that is no PNG, JPEG or '
        'WebP image; nothing is saved.');
  }
  return MadeImage(bytes, extension);
}

/// A picture of [prompt] from Mistral's image tool (#163), as Mistral
/// documents it: an agent with the tool (`POST /v1/agents`, made once per
/// image model and kept in [agents]), then a conversation with its
/// `agent_id` (`POST /v1/conversations`). An agent that Mistral no longer
/// knows (deleted, or made with another key) is made again once.
Future<MadeImage> _mistralImage(
    ProviderConfig provider,
    String prompt,
    Uri agentsUrl,
    Uri conversationsUrl,
    Map<String, String> headers,
    HttpPost post,
    ImageDownload download,
    ImageAgents agents) async {
  Future<String> newAgent() async {
    final json = await postJson(
        provider,
        agentsUrl,
        headers,
        {
          'model': provider.model,
          'name': 'Roam Graph images',
          'description': 'Makes the images of "Create image" in the Roam '
              'Graph app.',
          'instructions': mistralAgentInstructions,
          'tools': [
            {'type': 'image_generation'},
          ],
        },
        post);
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw AiError('${provider.name} made no agent for its image tool: '
          'the answer has no agent ID.');
    }
    try {
      await agents.write(provider.model, id);
    } on Exception {
      // Not kept: the next image makes a new agent.
    }
    return id;
  }

  Future<Map<String, Object?>> converse(String agentId) => postJson(
      provider,
      conversationsUrl,
      headers,
      {
        'agent_id': agentId,
        'inputs': prompt,
        // Not kept on Mistral's servers as a conversation.
        'store': false,
      },
      post);

  final kept = agents.read(provider.model);
  Map<String, Object?> json;
  if (kept == null) {
    json = await converse(await newAgent());
  } else {
    try {
      json = await converse(kept);
    } on AiError catch (e) {
      if (!_missingAgent(e)) rethrow;
      json = await converse(await newAgent());
    }
  }
  return _mistralFile(json, provider, prompt, conversationsUrl, headers,
      download);
}

/// Whether [error] says that the agent does not exist (#163): HTTP 404,
/// or a refused request whose message says so.
bool _missingAgent(AiError error) {
  if (error.status == 404) return true;
  if (error.status != 400 && error.status != 422) return false;
  final message = error.message.toLowerCase();
  return message.contains('agent') &&
      const ['not found', 'not exist', "doesn't exist", 'no agent', 'unknown']
          .any(message.contains);
}

/// Whether [text] only repeats [prompt]: the same words, apart from
/// case, spaces, quotes and a full stop at the end.
bool _repeats(String text, String prompt) {
  String plain(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp('^[\\s"\'“”„‘’«»]+|[\\s"\'“”„‘’«».!]+\$'), '');
  final said = plain(text);
  return said.isNotEmpty && said == plain(prompt);
}

/// The image of a Mistral answer with its image tool (#126): a link on
/// Mistral's file host, or a file ID for its Files API at [chatUrl]'s
/// host, which must be Mistral's. Only these hosts get the API key.
Future<MadeImage> _mistralFile(
    Map<String, Object?> json,
    ProviderConfig provider,
    String prompt,
    Uri chatUrl,
    Map<String, String> headers,
    ImageDownload download) async {
  final auth = {'authorization': ?headers['authorization']};
  final Uri imageUrl;
  switch (_fromMistral(json)) {
    case null:
      final said = _mistralText(json);
      final advice = provider.model == 'mistral-medium-latest'
          ? 'try again, or choose another Mistral model as the image model'
          : 'try mistral-medium-latest';
      // The answer only repeats the prompt: the tool did not run (#163).
      if (_repeats(said, prompt)) {
        throw AiError('${provider.name} did not run its image tool. The '
            'model "${provider.model}" may not use it; $advice.');
      }
      throw AiError('${provider.name} sent no image'
          '${said.isEmpty ? '.' : ', only text: "${_shorten(said)}"'} The '
          'model "${provider.model}" may not use the image tool; $advice.');
    case (link: final link?, fileId: _):
      final parsed = Uri.tryParse(link);
      if (parsed == null) {
        throw AiError(
            '${provider.name} sent an image link the app cannot read.');
      }
      if (!isMistralImageUrl(parsed)) {
        throw AiError('${provider.name} sent an image link to '
            '${parsed.host}, which the app does not download.');
      }
      imageUrl = parsed;
    case (link: null, fileId: final fileId?):
      if (chatUrl.scheme != 'https' || chatUrl.host != 'api.mistral.ai') {
        throw AiError('${provider.name} sent an image as a file of '
            '${chatUrl.host}, which the app downloads only from '
            'api.mistral.ai.');
      }
      imageUrl = Uri.https('api.mistral.ai',
          '/v1/files/${Uri.encodeComponent(fileId)}/content');
    default:
      throw AiError('${provider.name} sent no image.');
  }
  final Uint8List bytes;
  try {
    bytes = await download(imageUrl, headers: auth);
  } on AiError catch (e) {
    throw AiError('${provider.name} made an image, but '
        '${e.message[0].toLowerCase()}${e.message.substring(1)}');
  }
  final extension = imageExtension(bytes);
  if (extension == null) {
    throw AiError('${provider.name} sent something that is no PNG, JPEG or '
        'WebP image; nothing is saved.');
  }
  return MadeImage(bytes, extension);
}

/// The entries of a Mistral answer that hold content: the Conversations
/// API's `outputs` (`message.output` entries), and, as Chat Completions
/// sends them, `choices[].messages[]` and `choices[].message`.
List<Object?> _mistralMessages(Map<String, Object?> json) => [
      if (json['outputs'] case final List outputs) ...outputs,
      if (json['choices'] case final List choices)
        for (final choice in choices)
          if (choice is Map) ...[
            if (choice['messages'] case final List list) ...list,
            if (choice['message'] case final Map message) message,
          ],
    ];

/// [text], at most 200 characters.
String _shorten(String text) =>
    text.length <= 200 ? text : '${text.substring(0, 199)}…';

/// The text a Mistral answer gave instead of an image.
String _mistralText(Map<String, Object?> json) {
  final parts = <String>[];
  for (final message in _mistralMessages(json)) {
    // Only Mistral's own answer, not a tool's message.
    if (message is! Map ||
        (message['role'] != null && message['role'] != 'assistant')) {
      continue;
    }
    final content = message['content'];
    if (content is String) parts.add(content);
    if (content is List) {
      for (final chunk in content) {
        if (chunk is Map && chunk['type'] == 'text' && chunk['text'] is String) {
          parts.add(chunk['text'] as String);
        }
      }
    }
  }
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The first image in a Mistral answer: a `tool_file` chunk (a file ID)
/// or an `image_url` chunk (a link), in any of [_mistralMessages].
({String? link, String? fileId})? _fromMistral(Map<String, Object?> json) {
  for (final message in _mistralMessages(json)) {
    final content = message is Map ? message['content'] : null;
    if (content is! List) continue;
    for (final chunk in content) {
      if (chunk is! Map) continue;
      if (chunk['type'] == 'image_url') {
        final value = chunk['image_url'];
        final link = value is Map ? value['url'] : value;
        if (link is String && link.isNotEmpty) {
          return (link: link, fileId: null);
        }
      }
      if (chunk['type'] == 'tool_file') {
        if (chunk['file_id'] case final String id when id.isNotEmpty) {
          return (link: null, fileId: id);
        }
      }
    }
  }
  return null;
}

/// The base64 of the first image in an Images API answer: `b64_json`, or
/// a `data:` URL; a link to download is not followed.
String? _fromImages(Map<String, Object?> json) {
  final data = json['data'];
  if (data is! List || data.isEmpty || data.first is! Map) return null;
  final first = data.first as Map;
  if (first['b64_json'] case final String b64 when b64.isNotEmpty) return b64;
  if (first['url'] case final String url) return _dataUrl(url);
  return null;
}

/// The link to the first image of a DashScope answer:
/// `output.choices[0].message.content[0].image`.
String? _fromDashscope(Map<String, Object?> json) {
  final output = json['output'];
  final choices = output is Map ? output['choices'] : null;
  if (choices is! List || choices.isEmpty || choices.first is! Map) {
    return null;
  }
  final message = (choices.first as Map)['message'];
  final content = message is Map ? message['content'] : null;
  if (content is! List) return null;
  for (final part in content) {
    if (part is Map && part['image'] is String) return part['image'] as String;
  }
  return null;
}

/// The base64 of the first image of a chat answer with image output:
/// `choices[0].message.images[0].image_url.url`, a `data:` URL.
String? _fromChat(Map<String, Object?> json) {
  final choices = json['choices'];
  if (choices is! List || choices.isEmpty || choices.first is! Map) {
    return null;
  }
  final message = (choices.first as Map)['message'];
  if (message is! Map) return null;
  final images = message['images'];
  if (images is! List || images.isEmpty || images.first is! Map) return null;
  final imageUrl = (images.first as Map)['image_url'];
  final url = imageUrl is Map ? imageUrl['url'] : null;
  return url is String ? _dataUrl(url) : null;
}

String? _dataUrl(String url) {
  final match = RegExp(r'^data:image/[a-z+.-]+;base64,(.+)$', dotAll: true)
      .firstMatch(url.trim());
  return match?.group(1);
}
