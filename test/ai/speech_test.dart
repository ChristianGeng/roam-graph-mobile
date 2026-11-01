import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/speech.dart';

/// A synthetic recording: one second of silence as a WAV file.
Uint8List silence({int seconds = 1}) {
  final data = 8000 * 2 * seconds;
  final bytes = ByteData(44 + data);
  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + data, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 8000, Endian.little);
  bytes.setUint32(28, 16000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, data, Endian.little);
  return bytes.buffer.asUint8List();
}

SpeechAudio audio({Duration? length = const Duration(seconds: 1)}) =>
    SpeechAudio(
        name: 'memo.wav',
        bytes: silence(),
        mimeType: 'audio/wav',
        length: length);

SpeechConfig config(
        {String provider = 'mistral',
        String? language,
        bool speakers = false,
        String key = 'sk-test-key-1234'}) =>
    SpeechConfig(
      provider: speechProviderById(provider),
      model: speechProviderById(provider).defaultModel,
      apiKey: key,
      language: language,
      speakers: speakers,
    );

void main() {
  late List<({Uri url, Map<String, String> headers, String body})> sent;
  AudioPost answer(Object reply, {int status = 200}) =>
      (url, headers, body, cancel) async {
        sent.add((url: url, headers: headers, body: latin1.decode(body)));
        return HttpReply(status, jsonEncode(reply));
      };
  setUp(() => sent = []);

  /// The value of the form field [name] in the last request.
  String? field(String name) {
    final match = RegExp('name="$name"\r\n\r\n(.*?)\r\n')
        .firstMatch(sent.last.body);
    return match?[1];
  }

  group('transcribeAudio (#221)', () {
    test('Mistral: a multipart request to the transcription endpoint',
        () async {
      final transcript = await transcribeAudio(config(), audio(),
          post: answer({'text': ' Hello there. '}), boundary: 'xyz');
      expect(transcript.text, 'Hello there.');
      expect(transcript.speakerCount, 0);
      final request = sent.single;
      expect(request.url.toString(),
          'https://api.mistral.ai/v1/audio/transcriptions');
      expect(request.headers['authorization'], 'Bearer sk-test-key-1234');
      expect(request.headers['content-type'],
          'multipart/form-data; boundary=xyz');
      expect(field('model'), 'voxtral-mini-latest');
      expect(field('language'), isNull);
      expect(field('diarize'), isNull);
      expect(request.body, contains('name="file"; filename="memo.wav"'));
      expect(request.body, contains('Content-Type: audio/wav'));
      expect(request.body, contains('RIFF'));
      expect(request.body, endsWith('\r\n--xyz--\r\n'));
    });

    test('a language code is sent', () async {
      await transcribeAudio(config(language: 'de'), audio(),
          post: answer({'text': 'Hallo.'}));
      expect(field('language'), 'de');
    });

    test('OpenAI: its endpoint, model and response format', () async {
      await transcribeAudio(config(provider: 'openai', language: 'en'), audio(),
          post: answer({'text': 'Hello.'}));
      final request = sent.single;
      expect(request.url.toString(),
          'https://api.openai.com/v1/audio/transcriptions');
      expect(field('model'), 'gpt-4o-mini-transcribe');
      expect(field('language'), 'en');
      expect(field('response_format'), 'json');
    });

    test('speakers: diarization with segments, labels in order', () async {
      final transcript = await transcribeAudio(
          config(speakers: true, language: 'de'), audio(),
          post: answer({
            'text': 'Hello. Hi. How are you? Fine.',
            'segments': [
              {'text': ' Hello.', 'speaker_id': 'speaker_b'},
              {'text': 'Hi.', 'speaker_id': 'speaker_a'},
              {'text': 'How are you?', 'speaker_id': 'speaker_a'},
              {'text': 'Fine.', 'speaker_id': 'speaker_b'},
            ],
          }));
      expect(transcript.text,
          'Speaker 1: Hello.\nSpeaker 2: Hi. How are you?\nSpeaker 1: Fine.');
      expect(transcript.speakerCount, 2);
      expect(field('diarize'), 'true');
      expect(field('timestamp_granularities'), 'segment');
      // Mistral takes no language together with timestamps.
      expect(field('language'), isNull);
    });

    test('speakers asked for, but the answer names none: the plain text',
        () async {
      final transcript = await transcribeAudio(
          config(speakers: true), audio(),
          post: answer({
            'text': 'Just text.',
            'segments': [
              {'text': 'Just text.'},
            ],
          }));
      expect(transcript.text, 'Just text.');
      expect(transcript.speakerCount, 0);
    });

    test('OpenAI is not asked for speakers', () async {
      await transcribeAudio(config(provider: 'openai', speakers: true), audio(),
          post: answer({'text': 'x'}));
      expect(field('diarize'), isNull);
    });

    test('no key: the message names AI settings, nothing is sent', () async {
      await expectLater(
          transcribeAudio(config(key: ' '), audio(), post: answer({})),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              contains('Speech to text'))));
      expect(sent, isEmpty);
    });

    test('a recording over 30 minutes is refused before it is sent',
        () async {
      final long = audio(length: const Duration(minutes: 31, seconds: 20));
      await expectLater(
          transcribeAudio(config(), long, post: answer({})),
          throwsA(isA<AiError>().having(
              (e) => e.message,
              'message',
              'This recording is 31 min 20 s. The app transcribes '
                  'recordings of up to 30 minutes; transcribe longer ones '
                  'on the computer and share the text.')));
      expect(sent, isEmpty);
      // Exactly 30 minutes is taken.
      await transcribeAudio(
          config(), audio(length: const Duration(minutes: 30)),
          post: answer({'text': 'ok'}));
      expect(sent, hasLength(1));
    });

    test('OpenAI takes 25 MB at most', () async {
      final big = SpeechAudio(
          name: 'big.wav',
          bytes: Uint8List(25 * 1024 * 1024 + 1),
          mimeType: 'audio/wav',
          length: const Duration(minutes: 5));
      await expectLater(
          transcribeAudio(config(provider: 'openai'), big, post: answer({})),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              allOf(contains('25.0 MB'), contains('30 minutes')))));
      expect(sent, isEmpty);
    });

    test('a provider error in plain words, without the key', () async {
      await expectLater(
          transcribeAudio(config(), audio(),
              post: answer({
                'message': 'Invalid model: sk-test-key-1234',
              }, status: 400)),
          throwsA(isA<AiError>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.message, 'message',
                  allOf(contains('HTTP 400'), contains('Invalid model'),
                      isNot(contains('sk-test-key-1234'))))
              .having((e) => e.provider, 'provider', 'Mistral')));
      await expectLater(
          transcribeAudio(config(provider: 'openai'), audio(),
              post: answer({
                'error': {'message': 'Incorrect API key'},
              }, status: 401)),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              allOf(contains('refused the API key'),
                  contains('Incorrect API key')))));
      await expectLater(
          transcribeAudio(config(), audio(), post: answer({}, status: 503)),
          throwsA(isA<AiError>().having((e) => e.passing, 'passing', isTrue)));
    });

    test('a network failure can be tried again', () async {
      await expectLater(
          transcribeAudio(config(), audio(),
              post: (url, headers, body, cancel) =>
                  throw const SocketException('unreachable')),
          throwsA(isA<AiError>()
              .having((e) => e.passing, 'passing', isTrue)
              .having((e) => e.message, 'message', contains('No connection'))));
    });

    test('an answer without text', () async {
      await expectLater(
          transcribeAudio(config(), audio(), post: answer({'text': '  '})),
          throwsA(isA<AiError>().having((e) => e.message, 'message',
              'No speech was found in the recording.')));
    });

    test('cancel: no result, no error', () async {
      final token = CancelToken();
      final result = transcribeAudio(config(), audio(),
          cancel: token,
          post: (url, headers, body, cancel) async {
            await cancel.whenCancelled;
            throw const SpeechCancelled();
          });
      token.cancel();
      await expectLater(result, throwsA(isA<SpeechCancelled>()));
    });

    test('cancelled while the answer was on its way', () async {
      final token = CancelToken();
      await expectLater(
          transcribeAudio(config(), audio(),
              cancel: token,
              post: (url, headers, body, cancel) async {
                token.cancel();
                return const HttpReply(200, '{"text":"late"}');
              }),
          throwsA(isA<SpeechCancelled>()));
    });
  });

  group('helpers', () {
    test('formatLength', () {
      expect(formatLength(const Duration(seconds: 42)), '42 s');
      expect(formatLength(const Duration(minutes: 12, seconds: 5)),
          '12 min 5 s');
    });

    test('voiceMemoTitle and voiceMemoBody', () {
      expect(voiceMemoTitle(DateTime(2026, 11, 1, 9, 14)),
          'Voice memo 2026-11-01 09:14');
      expect(
          voiceMemoBody(
              fileName: 'memo.m4a',
              length: const Duration(minutes: 1, seconds: 30),
              config: config(),
              text: 'Hello.'),
          'Transcribed from memo.m4a (1 min 30 s) with Mistral '
          'voxtral-mini-latest.\n\nHello.');
      expect(
          voiceMemoBody(
              fileName: 'memo.m4a',
              length: null,
              config: config(provider: 'openai'),
              text: 'Hi.'),
          'Transcribed from memo.m4a with OpenAI gpt-4o-mini-transcribe.'
          '\n\nHi.');
    });

    test('multipartBody makes a safe file name', () {
      final body = latin1.decode(multipartBody('b', {'model': 'm'},
          fileField: 'file',
          fileName: 'a"b\r\nc.wav',
          mimeType: 'audio/wav',
          bytes: Uint8List.fromList([1, 2, 3])));
      expect(body, contains('filename="a_b__c.wav"'));
    });
  });

  group('speech settings', () {
    test('are saved and read back', () {
      const settings = AiSettings(
        speechProvider: 'openai',
        speechModels: {'openai': 'whisper-1'},
        speechLanguage: 'de',
        speechSpeakers: true,
        speechConsent: ['mistral'],
      );
      final back = AiSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
      expect(back.speechProvider, 'openai');
      expect(back.speechModel('openai'), 'whisper-1');
      expect(back.speechModel('mistral'), 'voxtral-mini-latest');
      expect(back.speechLanguage, 'de');
      expect(back.speechSpeakers, isTrue);
      expect(back.speechConsent, ['mistral']);
    });

    test('defaults, and odd values are ignored', () {
      const defaults = AiSettings();
      expect(defaults.speechProvider, '');
      expect(defaults.speechLanguage, '');
      expect(defaults.speechSpeakers, isFalse);
      expect(defaults.speechConsent, isEmpty);
      final odd = AiSettings.fromJson({
        'speechProvider': 'nobody',
        'speechModels': {'openai': ' ', 'nobody': 'x', 'mistral': 'm'},
        'speechLanguage': 'not a code',
        'speechSpeakers': 'yes',
        'speechConsent': ['openai', 'nobody', 3],
      });
      expect(odd.speechProvider, '');
      expect(odd.speechModels, {'mistral': 'm'});
      expect(odd.speechLanguage, '');
      expect(odd.speechSpeakers, isFalse);
      expect(odd.speechConsent, ['openai']);
      expect(AiSettings.fromJson({'speechLanguage': 'auto'}).speechLanguage,
          speechLanguageAuto);
    });
  });
}
