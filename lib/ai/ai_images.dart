/// Images made by an AI model (#112), in the two ways providers offer:
/// the Images API (`/images/generations`, OpenRouter's `/images`) and chat
/// with image output (Vercel AI Gateway's `modalities`). Checked against
/// Vercel's and OpenRouter's documentation on 2026-10-18.
library;

import 'dart:convert';
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

/// Asks [config]'s image model for a picture of [prompt]. Throws
/// [AiError] in plain words.
Future<MadeImage> makeImage(ImageConfig config, String prompt,
    {HttpPost post = postWithDartIo}) async {
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
  final Uri url;
  try {
    url = Uri.parse(chat ? '$base/chat/completions' : '$base${config.imagesPath}');
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
    if (chat) ...{
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
  final json = await postJson(provider, url, headers, body, post);
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
