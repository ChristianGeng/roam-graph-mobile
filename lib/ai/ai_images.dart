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

/// Asks [config]'s image model for a picture of [prompt]. Throws
/// [AiError] in plain words.
Future<MadeImage> makeImage(ImageConfig config, String prompt,
    {HttpPost post = postWithDartIo,
    ImageDownload download = downloadWithDartIo}) async {
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
        : Uri.parse(chat || mistral
            ? '$base/chat/completions'
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
    } else if (mistral) ...{
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'tools': [
        {'type': 'image_generation'},
      ],
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
      throw AiError('"${provider.model}" has no EU route, and "EU only" is '
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
  if (mistral) {
    return _mistralImage(json, provider, url, headers, download);
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

/// The image of a Mistral answer with its image tool (#126): a link on
/// Mistral's file host, or a file ID for its Files API at [chatUrl]'s
/// host, which must be Mistral's. Only these hosts get the API key.
Future<MadeImage> _mistralImage(
    Map<String, Object?> json,
    ProviderConfig provider,
    Uri chatUrl,
    Map<String, String> headers,
    ImageDownload download) async {
  final auth = {'authorization': ?headers['authorization']};
  final Uri imageUrl;
  switch (_fromMistral(json)) {
    case null:
      throw AiError('${provider.name} sent no image. The model '
          '"${provider.model}" may not use the image tool; try '
          'mistral-medium-latest.');
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

/// The first image in a Mistral answer: an `image_url` chunk (a link) or
/// a `tool_file` chunk (a file ID), in `choices[].messages[]`, which
/// Mistral sends when a tool ran, or in `choices[].message`.
({String? link, String? fileId})? _fromMistral(Map<String, Object?> json) {
  final choices = json['choices'];
  if (choices is! List) return null;
  for (final choice in choices) {
    if (choice is! Map) continue;
    final messages = [
      if (choice['messages'] case final List list) ...list,
      if (choice['message'] case final Map message) message,
    ];
    for (final message in messages) {
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
