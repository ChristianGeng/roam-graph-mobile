// Voice memos (#221), through the folder screen: a shared audio file, the
// question where it goes, the progress screen, the capture screen and
// "Keep the recording". The audio is synthetic (silence) and no request
// leaves the test: the speech provider is faked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/speech.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';
import 'package:roam_graph_mobile/capture/text_files.dart';
import 'package:roam_graph_mobile/capture/voice_memo.dart';
import 'package:roam_graph_mobile/platform/text_drop.dart';
import 'package:roam_graph_mobile/platform/voice_work.dart';

import '../ai/ai_settings_test.dart' show MemoryAiSettingsStore, MemoryKeyStore;
import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../widget_test.dart'
    show FakeFolderAccess, FakeShareInbox, start, withNotes, writableOrg;

/// [seconds] of silence as a mono 16-bit WAV file at 8 kHz.
Uint8List silence([int seconds = 1]) {
  final data = 16000 * seconds;
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

IncomingFile memo({Uint8List? bytes, int? durationMs}) => IncomingFile(
      'memo.wav',
      mimeType: 'audio/wav',
      bytes: bytes ?? silence(),
      durationMs: durationMs,
      modified: DateTime(2026, 11, 1, 9, 14),
    );

class FakeVoiceWork implements VoiceWork {
  final events = <String>[];

  @override
  Future<void> started() async => events.add('started');

  @override
  Future<void> finished() async => events.add('finished');

  @override
  Future<void> notify({required String title, required String text}) async =>
      events.add('notify: $title');
}

void main() {
  late FakeFolderAccess access;
  late FakeShareInbox inbox;
  late MemoryAiSettingsStore store;
  late MemoryKeyStore keys;
  late FakeVoiceWork work;
  late List<({Uri url, String body, CancelToken cancel})> sent;
  Completer<HttpReply>? answer;

  Future<HttpReply> fakePost(
      Uri url, Map<String, String> headers, Uint8List body, CancelToken c) {
    sent.add((url: url, body: latin1.decode(body), cancel: c));
    final pending = answer;
    if (pending != null) return pending.future;
    return Future.value(const HttpReply(200, '{"text":"Hello from the test."}'));
  }

  setUp(() {
    access = withNotes(saved: writableOrg);
    inbox = FakeShareInbox();
    store = MemoryAiSettingsStore();
    keys = MemoryKeyStore()..keys['mistral'] = 'mk-test-key';
    work = FakeVoiceWork();
    sent = [];
    answer = null;
  });

  Future<void> begin(WidgetTester tester) => start(tester, access,
      shares: inbox,
      memory: MemoryNodeMemory('a'),
      aiSettings: store,
      apiKeys: keys,
      speechPost: fakePost,
      voiceWork: work);

  /// Lets the app work without waiting for animations to end.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shareMemo(WidgetTester tester, [IncomingFile? file]) async {
    inbox.share(SharedFiles([file ?? memo()]));
    await settle(tester);
  }

  group('a shared voice memo', () {
    testWidgets('asks once where it goes, transcribes, and opens the capture '
        'screen', (tester) async {
      await begin(tester);
      await shareMemo(tester);

      // The question names the provider and says it gets the recording.
      expect(find.byKey(const ValueKey('voice-consent')), findsOneWidget);
      expect(find.textContaining('Send the recording to Mistral?'),
          findsOneWidget);
      expect(find.textContaining('processed in the EU'), findsOneWidget);
      expect(find.textContaining('gets the recording itself'),
          findsOneWidget);
      expect(sent, isEmpty);

      answer = Completer<HttpReply>();
      await tester.tap(find.byKey(const ValueKey('voice-consent-send')));
      await settle(tester);
      // The progress screen: file name, length, progress line, Cancel.
      expect(find.byKey(const ValueKey('voice-file')), findsOneWidget);
      expect(find.text('memo.wav'), findsOneWidget);
      expect(find.textContaining('1 s'), findsWidgets);
      expect(find.byKey(const ValueKey('voice-progress')), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-cancel')), findsOneWidget);
      expect(sent.single.url.toString(),
          'https://api.mistral.ai/v1/audio/transcriptions');
      expect(work.events, ['started']);

      answer!.complete(
          const HttpReply(200, '{"text":"Hello from the test."}'));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(work.events, ['started', 'finished']);
      expect(find.text('New node'), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('capture-title')))
              .controller!
              .text,
          'Voice memo 2026-11-01 09:14');
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('capture-body')))
              .controller!
              .text,
          'Transcribed from memo.wav (1 s) with Mistral voxtral-mini-latest.'
          '\n\nHello from the test.');
      // Nothing is saved before the user saves.
      expect(access.created, isEmpty);
      // The agreement is kept.
      expect(store.settings.speechConsent, ['mistral']);
    });

    testWidgets('the question is not asked again', (tester) async {
      store.settings = const AiSettings(speechConsent: ['mistral']);
      await begin(tester);
      await shareMemo(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-consent')), findsNothing);
      expect(sent, hasLength(1));
      expect(find.text('New node'), findsOneWidget);
    });

    testWidgets('Cancel in the question sends nothing', (tester) async {
      await begin(tester);
      await shareMemo(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(sent, isEmpty);
      expect(store.settings.speechConsent, isEmpty);
      expect(find.text('New node'), findsNothing);
    });

    testWidgets('Cancel while it works stops the request and opens nothing',
        (tester) async {
      store.settings = const AiSettings(speechConsent: ['mistral']);
      answer = Completer<HttpReply>();
      await begin(tester);
      await shareMemo(tester);
      await tester.tap(find.byKey(const ValueKey('voice-cancel')));
      await settle(tester);
      expect(sent.single.cancel.cancelled, isTrue);
      expect(find.byKey(const ValueKey('voice-file')), findsNothing);
      expect(find.text('New node'), findsNothing);
      expect(work.events, contains('finished'));
    });

    testWidgets('no key: the message names AI settings, nothing is sent',
        (tester) async {
      keys.keys.clear();
      await begin(tester);
      await shareMemo(tester);
      expect(find.byKey(const ValueKey('voice-problem')), findsOneWidget);
      expect(find.textContaining('AI settings → Speech to text'),
          findsOneWidget);
      expect(sent, isEmpty);
      expect(find.byKey(const ValueKey('voice-consent')), findsNothing);
    });

    testWidgets('a recording over 30 minutes is refused before the question',
        (tester) async {
      await begin(tester);
      // Not a readable header, so the length the sender gave counts.
      await shareMemo(
          tester,
          memo(
              bytes: Uint8List.fromList(utf8.encode('not really audio')),
              durationMs: 31 * 60 * 1000));
      expect(find.byKey(const ValueKey('voice-problem')), findsOneWidget);
      expect(
          find.textContaining('This recording is 31 min 0 s. The app '
              'transcribes recordings of up to 30 minutes; transcribe '
              'longer ones on the computer and share the text.'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('voice-consent')), findsNothing);
      expect(sent, isEmpty);
    });

    testWidgets('a provider error is shown with Try again', (tester) async {
      store.settings = const AiSettings(speechConsent: ['mistral']);
      answer = Completer<HttpReply>();
      await begin(tester);
      await shareMemo(tester);
      answer!.complete(
          const HttpReply(401, '{"message":"Unauthorized key"}'));
      await settle(tester);
      expect(find.byKey(const ValueKey('voice-error')), findsOneWidget);
      expect(find.textContaining('refused the API key'), findsOneWidget);
      expect(find.textContaining('Unauthorized key'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-retry')), findsOneWidget);

      answer = null;
      await tester.tap(find.byKey(const ValueKey('voice-retry')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(sent, hasLength(2));
      expect(find.text('New node'), findsOneWidget);
    });

    testWidgets('a notification when the app is in the background',
        (tester) async {
      store.settings = const AiSettings(speechConsent: ['mistral']);
      answer = Completer<HttpReply>();
      await begin(tester);
      await shareMemo(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      answer!.complete(const HttpReply(200, '{"text":"Done."}'));
      await settle(tester);
      expect(work.events, contains('notify: Voice memo ready'));
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
    });

    testWidgets('Keep the recording: written next to the note and linked',
        (tester) async {
      store.settings = const AiSettings(speechConsent: ['mistral']);
      await begin(tester);
      await shareMemo(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('capture-keep-recording')));
      await tester.tap(find.byKey(const ValueKey('capture-keep-recording')));
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      final audio = access.createdBytes.entries
          .where((e) => e.key.endsWith('.wav'))
          .single;
      expect(audio.key, startsWith('roam/'));
      expect(audio.value, silence());
      final note = access.createdBytes.entries
          .where((e) => e.key.endsWith('.org'))
          .single;
      final name = audio.key.substring('roam/'.length);
      expect(utf8.decode(note.value), contains('[[file:$name][Recording]]'));
      expect(note.key.replaceFirst('.org', '.wav'), audio.key);
    });

    testWidgets('without it, only the note is written', (tester) async {
      store.settings = const AiSettings(speechConsent: ['mistral']);
      await begin(tester);
      await shareMemo(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(access.createdBytes.keys.where((k) => k.endsWith('.wav')),
          isEmpty);
      expect(access.createdBytes.keys.where((k) => k.endsWith('.org')),
          hasLength(1));
    });

    testWidgets('a dropped voice memo is taken on the desktop',
        (tester) async {
      store.settings = const AiSettings(speechConsent: ['mistral']);
      await begin(tester);
      TextDrop.deliver(SharedFiles([memo()]));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(find.text('New node'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('loadRecording and the desktop reader', () {
    test('reads a file by its path, with the time it was changed', () async {
      final dir = Directory.systemTemp.createTempSync('voice_memo');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/note.wav';
      File(path).writeAsBytesSync(silence(2));
      final share = await shareFromDrop([path], null);
      final file = (share! as SharedFiles).files.single;
      expect(file.name, 'note.wav');
      expect(file.path, path);
      expect(file.bytes, isNull);
      final loaded = await loadRecording(file);
      expect(loaded.problem, isNull);
      expect(loaded.audio!.length, const Duration(seconds: 2));
      expect(loaded.audio!.mimeType, 'audio/wav');
      expect(loaded.time, file.modified);
    });

    test('says why a file cannot be used', () async {
      expect(
          (await loadRecording(const IncomingFile('a.mp3', error: 'denied')))
              .problem,
          'a.mp3 could not be read: denied');
      expect((await loadRecording(const IncomingFile('a.mp3'))).problem,
          'a.mp3 could not be read.');
      expect(
          (await loadRecording(IncomingFile('a.mp3', bytes: Uint8List(0))))
              .problem,
          'a.mp3 is empty.');
      final huge = await loadRecording(
          const IncomingFile('big.mp3', size: 101 * 1024 * 1024));
      expect(huge.problem, startsWith('big.mp3 is 101.0 MB. The app '
          'transcribes recordings of up to 30 minutes'));
      expect(
          (await loadRecording(const IncomingFile('gone.mp3',
                  path: '/nonexistent/gone.mp3')))
              .problem,
          startsWith('gone.mp3 could not be read:'));
    });

    test("discardCopy deletes only the app's own copies", () async {
      final dir = Directory.systemTemp.createTempSync('voice_copy');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ours = File('${dir.path}/cache/voice/1-a.wav')
        ..createSync(recursive: true);
      // A dropped file in a folder that is also called "voice".
      final dropped = File('${dir.path}/cache/voice/b.wav')
        ..createSync(recursive: true);
      await discardCopy(IncomingFile('a.wav', path: ours.path, isCopy: true));
      await discardCopy(IncomingFile('b.wav', path: dropped.path));
      expect(ours.existsSync(), isFalse);
      expect(dropped.existsSync(), isTrue);
    });
  });
}
