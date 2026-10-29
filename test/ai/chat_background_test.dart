import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/ai/chat_store.dart';
import 'package:roam_graph_mobile/platform/chat_background.dart';

import 'ai_chat_test.dart' show FakeServer, anthropic, anthropicReply;
import 'ai_visibility_test.dart' show graphOf, notes;
import 'chat_store_test.dart' show GatedServer, answer;

/// A foreground service that records what it is told.
class FakeService implements BackgroundService {
  final calls = <String>[];

  /// Makes every call fail, as when Android refuses the service.
  bool failing = false;

  /// Makes the next calls fail, then lets them pass.
  int failNext = 0;

  @override
  Future<void> working(int chats) async {
    calls.add('working $chats');
    if (failNext > 0) {
      failNext--;
      throw Exception('not allowed');
    }
    if (failing) throw Exception('not allowed');
  }

  @override
  Future<void> idle() async {
    calls.add('idle');
    if (failing) throw Exception('not allowed');
  }
}

/// A notifier that records the notifications and the permission questions.
class FakeNotifier implements AnswerNotifier {
  FakeNotifier({this.granted = true});

  bool granted;
  int asked = 0;
  final shown = <({String chatId, String title, String text})>[];

  @override
  Future<bool> permissionGranted() async => granted;

  @override
  Future<bool> requestPermission() async {
    asked++;
    return granted;
  }

  @override
  Future<void> show({
    required String chatId,
    required String title,
    required String text,
  }) async {
    shown.add((chatId: chatId, title: title, text: text));
  }

  @override
  void listen(void Function(String chatId) onTap) {}

  @override
  Future<String?> launchTap() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final graph = graphOf(notes);

  late FakeService service;
  late FakeNotifier notifier;
  late ChatStore store;

  setUp(() {
    service = FakeService();
    notifier = FakeNotifier();
    store = ChatStore(
      MemoryChatStorage(),
      background: service,
      notifier: notifier,
    );
  });

  /// A chat of [store] with a session on [server].
  Chat chatOn(FakeServer server) {
    final chat = store.create(
      providerId: 'anthropic',
      providerName: 'Anthropic',
      model: anthropic.model,
    );
    chat.attach(ChatSession(
      tools: RoamTools(graph,
          readNote: (path) async => notes[path],
          visibility: const AiVisibility({'private'})),
      config: anthropic,
      post: server.post,
    ));
    return chat;
  }

  group('the foreground service', () {
    test('starts with the first working chat and stops after the last',
        () async {
      final one = GatedServer([answer('First.')]);
      final two = GatedServer([answer('Second.')]);
      final a = chatOn(one);
      final b = chatOn(two);
      final doneA = a.send('One');
      await pumpEventQueue();
      await store.flushPlatform();
      expect(service.calls, ['working 1']);

      final doneB = b.send('Two');
      await pumpEventQueue();
      await store.flushPlatform();
      expect(service.calls, ['working 1', 'working 2']);

      one.gate.complete();
      await doneA;
      await store.flushPlatform();
      // One chat still works: the service runs on, with the new number.
      expect(service.calls, ['working 1', 'working 2', 'working 1']);

      two.gate.complete();
      await doneB;
      await store.flushPlatform();
      expect(service.calls.last, 'idle');
      expect(service.calls.where((c) => c == 'idle'), hasLength(1));
    });

    test('a chat that waits for a place does not count', () async {
      store.maxParallel = 1;
      final one = GatedServer([answer('First.')]);
      final two = GatedServer([answer('Second.')]);
      two.gate.complete();
      final a = chatOn(one);
      final b = chatOn(two);
      final doneA = a.send('One');
      final doneB = b.send('Two');
      await pumpEventQueue();
      await store.flushPlatform();
      expect(b.queued, isTrue);
      expect(service.calls, ['working 1']);

      one.gate.complete();
      await doneA;
      await doneB;
      await store.flushPlatform();
      // The place passed on without a stop in between.
      expect(service.calls, ['working 1', 'idle']);
    });

    test('stops after an error', () async {
      final chat = chatOn(FakeServer([
        const HttpReply(401, '{"error": {"message": "bad key"}}'),
      ]));
      await chat.send('Question');
      await store.flushPlatform();
      expect(service.calls, ['working 1', 'idle']);
    });

    test('a service that could not start is tried again at the next step',
        () async {
      service.failNext = 1;
      final chat = chatOn(FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'org_roam_find',
            'input': {'search': 'Plan'},
          },
        ], stop: 'tool_use'),
        answer('Done.'),
      ]));
      await chat.send('Where is my plan?');
      await store.flushPlatform();
      expect(service.calls.first, 'working 1');
      // The first start failed; a step of the chat started it again.
      expect(service.calls.where((c) => c == 'working 1').length,
          greaterThanOrEqualTo(2));
      expect(service.calls.last, 'idle');
    });

    test('a service that fails does not stop the chat', () async {
      service.failing = true;
      final chat = chatOn(FakeServer([answer('Still here.')]));
      await chat.send('Question');
      await store.flushPlatform();
      expect((chat.transcript.last as AssistantMessage).text, 'Still here.');
      expect(chat.error, isNull);
    });
  });

  group('notifications', () {
    test('an answer in a closed chat names the chat and starts the answer',
        () async {
      final chat = chatOn(FakeServer([answer('The plan is ready.\nMore.')]));
      await chat.send('What is the plan?');
      await store.flushPlatform();
      expect(notifier.shown, hasLength(1));
      expect(notifier.shown.single.chatId, chat.id);
      expect(notifier.shown.single.title, "Answer in 'What is the plan?'");
      expect(notifier.shown.single.text, 'The plan is ready.');
    });

    test('an answer in the open chat gives none', () async {
      final chat = chatOn(FakeServer([answer('Here.')]));
      chat.viewers++;
      await chat.send('Question');
      await store.flushPlatform();
      expect(notifier.shown, isEmpty);
    });

    test('an open chat gives one while the app is in the background',
        () async {
      final chat = chatOn(FakeServer([answer('Here.')]));
      chat.viewers++;
      store.appVisible = false;
      await chat.send('Question');
      await store.flushPlatform();
      expect(notifier.shown, hasLength(1));
      expect(notifier.shown.single.title, "Answer in 'Question'");
    });

    test('an open chat covered by another page gives one', () async {
      final chat = chatOn(FakeServer([answer('Here.')]));
      chat.viewers++;
      chat.screenIsCurrent = () => false;
      await chat.send('Question');
      await store.flushPlatform();
      expect(notifier.shown, hasLength(1));
    });

    test('a failure gives "Failed in" with the chat title', () async {
      final chat = chatOn(FakeServer([
        const HttpReply(401, '{"error": {"message": "bad key"}}'),
      ]));
      await chat.send('Question');
      await store.flushPlatform();
      expect(notifier.shown, hasLength(1));
      expect(notifier.shown.single.title, "Failed in 'Question'");
      expect(notifier.shown.single.text, contains('refused the API key'));
    });

    test('with the setting off there is none, and no question', () async {
      store.notifyAnswers = false;
      notifier.granted = false;
      final chat = chatOn(FakeServer([answer('Here.')]));
      await chat.send('Question');
      await store.flushPlatform();
      expect(notifier.shown, isEmpty);
      expect(notifier.asked, 0);
      // The service does not depend on the setting.
      expect(service.calls, ['working 1', 'idle']);
    });

    test('a deleted chat gives none', () async {
      final one = GatedServer([answer('A.')]);
      final chat = chatOn(one);
      final done = chat.send('One');
      await pumpEventQueue();
      store.remove(chat);
      one.gate.complete();
      await done;
      await store.flushPlatform();
      expect(notifier.shown, isEmpty);
    });
  });

  group('the permission', () {
    test('is asked at the first send while there is none, only once',
        () async {
      notifier.granted = false;
      final chat = chatOn(FakeServer([answer('A.'), answer('B.')]));
      await chat.send('One');
      await pumpEventQueue();
      // At the first send, not later.
      expect(notifier.asked, 1);
      await chat.send('Two');
      await pumpEventQueue();
      expect(notifier.asked, 1);
    });

    test('is not asked when it is given', () async {
      final chat = chatOn(FakeServer([answer('A.')]));
      await chat.send('One');
      await pumpEventQueue();
      expect(notifier.asked, 0);
    });
  });

  group('a tap on a notification', () {
    test('is kept until a screen takes it, once', () {
      expect(store.takeOpenRequest(), isNull);
      var changes = 0;
      store.openRequest.addListener(() => changes++);
      store.requestOpen('c1');
      expect(changes, 1);
      expect(store.takeOpenRequest(), 'c1');
      expect(store.takeOpenRequest(), isNull);
    });
  });

  group('the setting', () {
    test('is on by default, saved and read again', () {
      expect(const AiSettings().notifyAnswers, isTrue);
      final off = AiSettings.fromJson(
          const AiSettings(notifyAnswers: false).toJson());
      expect(off.notifyAnswers, isFalse);
      expect(AiSettings.fromJson({'notifyAnswers': 'no'}).notifyAnswers, isTrue);
      expect(AiSettings.fromJson({}).notifyAnswers, isTrue);
    });
  });
}
