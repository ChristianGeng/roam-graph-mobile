/// Speech to text for voice memos (#221): one recording, sent whole to
/// Mistral (Voxtral) or OpenAI, and the text that comes back.
///
/// Nothing is sent unless the user agreed for the recording shared, and
/// only for that file. HTTP goes through [AudioPost], which tests replace.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../platform/error_text.dart';
import 'ai_chat.dart';

/// The longest recording the app transcribes: a voice memo. Longer ones
/// (meetings, talks) are transcribed on the computer.
const maxRecording = Duration(minutes: 30);

/// The most bytes of a recording the app reads into memory, whatever the
/// provider takes.
const maxRecordingBytes = 100 * 1024 * 1024;

/// A provider of speech to text, with its defaults.
class SpeechProvider {
  const SpeechProvider({
    required this.id,
    required this.name,
    required this.keyId,
    required this.baseUrl,
    required this.defaultModel,
    required this.maxBytes,
    required this.where,
    required this.price,
    this.speakers = false,
  });

  /// Stable, for the saved settings.
  final String id;
  final String name;

  /// The name of the API key in the key store. Mistral's is the key of the
  /// chat provider of the same name.
  final String keyId;

  /// The API's base URL; the request goes to `<base>/audio/transcriptions`.
  final String baseUrl;
  final String defaultModel;

  /// The largest recording the provider takes in one request.
  final int maxBytes;

  /// Where the recording goes, for the question before the first use.
  final String where;

  /// One line on the price.
  final String price;

  /// Whether the provider can label the speakers.
  final bool speakers;
}

/// The providers, Mistral first: it is the default when its key is set.
const speechProviders = <SpeechProvider>[
  SpeechProvider(
    id: 'mistral',
    name: 'Mistral',
    keyId: 'mistral',
    baseUrl: 'https://api.mistral.ai/v1',
    defaultModel: 'voxtral-mini-latest',
    maxBytes: maxRecordingBytes,
    where: 'Mistral is a French company; the recording is processed in the '
        'EU.',
    price: 'about 0.003 USD per minute of audio',
    speakers: true,
  ),
  SpeechProvider(
    id: 'openai',
    name: 'OpenAI',
    keyId: 'openai-speech',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini-transcribe',
    maxBytes: 25 * 1024 * 1024,
    where: 'OpenAI is a US company; the recording is processed outside the '
        'EU.',
    price: 'about 0.003 USD per minute of audio with '
        'gpt-4o-mini-transcribe',
  ),
];

/// The speech provider with [id], or Mistral.
SpeechProvider speechProviderById(String id) =>
    speechProviders.firstWhere((p) => p.id == id,
        orElse: () => speechProviders.first);

/// A recording to transcribe.
class SpeechAudio {
  const SpeechAudio({
    required this.name,
    required this.bytes,
    required this.mimeType,
    this.length,
  });

  /// The file name, without folders.
  final String name;
  final Uint8List bytes;
  final String mimeType;

  /// The recording's length, if it could be told.
  final Duration? length;
}

/// How a request is made: the provider, model, key and settings.
class SpeechConfig {
  const SpeechConfig({
    required this.provider,
    required this.model,
    required this.apiKey,
    this.language,
    this.speakers = false,
  });

  final SpeechProvider provider;
  final String model;
  final String apiKey;

  /// The language code, or null to let the provider detect it.
  final String? language;

  /// Whether speaker labels are asked for.
  final bool speakers;

  /// "Mistral voxtral-mini-latest", for the line above the text.
  String get label => '${provider.name} $model';
}

/// The text of a recording.
class Transcript {
  const Transcript(this.text, {this.speakerCount = 0});

  /// The text; with speaker labels, `Speaker 1: …` lines.
  final String text;

  /// How many speakers the labels name; 0 without labels.
  final int speakerCount;
}

/// Lets the user stop a request.
class CancelToken {
  final _done = Completer<void>();

  bool get cancelled => _done.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// The request was cancelled; not an error to show.
class SpeechCancelled implements Exception {
  const SpeechCancelled();

  @override
  String toString() => 'Cancelled.';
}

/// Sends a POST request with a binary body; tests replace it. Completes
/// with [SpeechCancelled] thrown when [cancel] completes first.
typedef AudioPost = Future<HttpReply> Function(
    Uri url, Map<String, String> headers, Uint8List body, CancelToken cancel);

/// [AudioPost] with `dart:io`, without redirects, as `postWithDartIo`.
Future<HttpReply> postBytesWithDartIo(
    Uri url, Map<String, String> headers, Uint8List body,
    CancelToken cancel) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'RoamGraph';
  unawaited(cancel.whenCancelled.then((_) => client.close(force: true)));
  try {
    final request = await client.postUrl(url);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.contentLength = body.length;
    request.add(body);
    final response =
        await request.close().timeout(const Duration(minutes: 10));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(minutes: 10));
    return HttpReply(response.statusCode, text);
  } on Exception {
    // Closing the client breaks the request in many ways.
    if (cancel.cancelled) throw const SpeechCancelled();
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// "12 min 5 s", "42 s".
String formatLength(Duration length) {
  final seconds = (length.inMilliseconds / 1000).round();
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return minutes == 0 ? '$rest s' : '$minutes min $rest s';
}

/// "3.4 MB".
String formatSize(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Why [audio] cannot be transcribed with [provider]; null if it can.
String? refuseRecording(SpeechAudio audio, SpeechProvider provider) {
  final length = audio.length;
  const advice = 'The app transcribes recordings of up to 30 minutes; '
      'transcribe longer ones on the computer and share the text.';
  if (length != null && length > maxRecording) {
    return 'This recording is ${formatLength(length)}. $advice';
  }
  if (audio.bytes.length > provider.maxBytes) {
    return 'This recording is ${formatSize(audio.bytes.length)}. '
        '${provider.name} takes ${formatSize(provider.maxBytes)} in one '
        'request. $advice';
  }
  return null;
}

/// The multipart/form-data body of a transcription request.
Uint8List multipartBody(
  String boundary,
  Map<String, String> fields, {
  required String fileField,
  required String fileName,
  required String mimeType,
  required Uint8List bytes,
}) {
  final out = BytesBuilder(copy: false);
  void text(String value) => out.add(utf8.encode(value));
  for (final MapEntry(:key, :value) in fields.entries) {
    text('--$boundary\r\n'
        'Content-Disposition: form-data; name="$key"\r\n\r\n'
        '$value\r\n');
  }
  // A quote or a line end in the name would end the header early.
  final safeName = fileName.replaceAll(RegExp(r'["\r\n\\]'), '_');
  text('--$boundary\r\n'
      'Content-Disposition: form-data; name="$fileField"; '
      'filename="$safeName"\r\n'
      'Content-Type: $mimeType\r\n\r\n');
  out.add(bytes);
  text('\r\n--$boundary--\r\n');
  return out.takeBytes();
}

/// Transcribes [audio]; every failure is an [AiError] in plain words, and
/// [SpeechCancelled] is thrown when [cancel] is called.
Future<Transcript> transcribeAudio(
  SpeechConfig config,
  SpeechAudio audio, {
  AudioPost post = postBytesWithDartIo,
  CancelToken? cancel,
  String? boundary,
}) async {
  final token = cancel ?? CancelToken();
  final provider = config.provider;
  AiError fail(String message,
          {int? status, bool passing = false, String? answer}) =>
      AiError(redactSecrets(message, secrets: [config.apiKey]),
          status: status,
          passing: passing,
          provider: provider.name,
          model: config.model,
          api: 'audio/transcriptions',
          answer: answer);
  if (config.apiKey.trim().isEmpty) throw fail(noSpeechKey(provider));
  if (refuseRecording(audio, provider) case final reason?) {
    throw fail(reason);
  }
  final fields = <String, String>{
    'model': config.model,
    if (provider.id == 'mistral' && config.speakers) ...{
      'diarize': 'true',
      // Speaker labels come with the segments. Mistral does not take a
      // language together with timestamps, so the language is left out.
      'timestamp_granularities': 'segment',
    } else if (config.language != null)
      'language': config.language!,
    if (provider.id == 'openai') 'response_format': 'json',
  };
  final edge = boundary ?? 'roamgraph${DateTime.now().microsecondsSinceEpoch}';
  final body = multipartBody(edge, fields,
      fileField: 'file',
      fileName: audio.name,
      mimeType: audio.mimeType,
      bytes: audio.bytes);
  final url = Uri.parse('${provider.baseUrl}/audio/transcriptions');
  final headers = {
    'authorization': 'Bearer ${config.apiKey}',
    'content-type': 'multipart/form-data; boundary=$edge',
  };
  String answerOf(String raw) =>
      cleanAnswer(raw, secrets: [config.apiKey]);
  HttpReply reply;
  try {
    reply = await post(url, headers, body, token);
  } on SpeechCancelled {
    rethrow;
  } on SocketException catch (e) {
    throw fail(
        'No connection to ${url.host}: ${e.message}. Check the network.',
        passing: true);
  } on HandshakeException catch (e) {
    throw fail('No secure connection to ${url.host}: ${e.message}.');
  } on TimeoutException {
    throw fail('${url.host} did not answer in time. Try again.');
  } on HttpException catch (e) {
    throw fail('The connection to ${url.host} failed: ${e.message}.',
        passing: true);
  }
  if (token.cancelled) throw const SpeechCancelled();
  Object? json;
  try {
    json = jsonDecode(reply.body);
  } on FormatException {
    json = null;
  }
  if (reply.status < 200 || reply.status >= 300) {
    throw fail(_httpError(provider, config.model, reply.status,
            _errorMessage(json, reply.body)),
        status: reply.status,
        passing: const {502, 503, 504, 529}.contains(reply.status),
        answer: answerOf(reply.body));
  }
  if (json is! Map) {
    throw fail('${provider.name} sent an answer the app cannot read.',
        status: reply.status, answer: answerOf(reply.body));
  }
  final transcript = parseTranscript(json, speakers: config.speakers);
  if (transcript.text.isEmpty) {
    throw fail('No speech was found in the recording.',
        status: reply.status);
  }
  return transcript;
}

/// The message when there is no key for [provider].
String noSpeechKey(SpeechProvider provider) =>
    'There is no API key for ${provider.name}. Set one under AI settings → '
    'Speech to text.';

/// The text of a provider's answer. With [speakers] and segments that
/// name a speaker, `Speaker 1: …` lines, numbered in the order the
/// speakers first talk; else the plain text.
Transcript parseTranscript(Map<dynamic, dynamic> json,
    {bool speakers = false}) {
  final plain = switch (json['text']) {
    final String text => text.trim(),
    _ => '',
  };
  if (!speakers || json['segments'] is! List) return Transcript(plain);
  final numbers = <String, int>{};
  final lines = <({int speaker, StringBuffer text})>[];
  for (final segment in json['segments'] as List) {
    if (segment is! Map) continue;
    final text = switch (segment['text']) {
      final String text => text.trim(),
      _ => '',
    };
    if (text.isEmpty) continue;
    final who = segment['speaker_id'] ?? segment['speaker'];
    if (who == null) return Transcript(plain);
    final number = numbers.putIfAbsent('$who', () => numbers.length + 1);
    if (lines.isNotEmpty && lines.last.speaker == number) {
      lines.last.text.write(' $text');
    } else {
      lines.add((speaker: number, text: StringBuffer(text)));
    }
  }
  if (lines.isEmpty) return Transcript(plain);
  return Transcript(
    [for (final line in lines) 'Speaker ${line.speaker}: ${line.text}']
        .join('\n'),
    speakerCount: numbers.length,
  );
}

String _errorMessage(Object? json, String body) {
  if (json is Map) {
    final error = json['error'];
    if (error is Map && error['message'] is String) return error['message'];
    if (error is String) return error;
    if (json['message'] is String) return json['message'] as String;
    if (json['detail'] is String) return json['detail'] as String;
  }
  final text = body.trim();
  return text.length > 300 ? '${text.substring(0, 300)}…' : text;
}

String _httpError(
    SpeechProvider provider, String model, int status, String message) {
  final detail = message.isEmpty ? '' : ' $message';
  return switch (status) {
    401 || 403 => '${provider.name} refused the API key (HTTP $status). '
        'Check it under AI settings → Speech to text.$detail',
    413 => '${provider.name} says the recording is too large (HTTP 413).'
        '$detail',
    429 => 'Too many requests, or no credit left at ${provider.name} (HTTP '
        '429). Wait a moment, or check the account.$detail',
    404 => 'Not found at ${provider.name} (HTTP 404). Check the model '
        '"$model".$detail',
    _ => '${provider.name} answered with an error (HTTP $status).$detail',
  };
}

/// The text a voice memo proposes for the capture screen (#221): the
/// source line, then the transcript.
String voiceMemoBody({
  required String fileName,
  required Duration? length,
  required SpeechConfig config,
  required String text,
}) {
  final size = length == null ? '' : ' (${formatLength(length)})';
  return 'Transcribed from $fileName$size with ${config.label}.\n\n$text';
}

/// The title a voice memo proposes: `Voice memo 2026-11-01 09:14`, from the
/// time of the recording.
String voiceMemoTitle(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Voice memo ${time.year.toString().padLeft(4, '0')}-'
      '${two(time.month)}-${two(time.day)} ${two(time.hour)}:'
      '${two(time.minute)}';
}
