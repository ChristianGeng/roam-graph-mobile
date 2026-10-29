import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/ai/chat_note.dart';
import 'package:roam_graph_mobile/ai/chat_store.dart';

import 'ai_chat_test.dart' show FakeServer, anthropic, anthropicReply;
import 'ai_visibility_test.dart' show graphOf, notes;

/// A server that holds every request until [gate] is completed.
class GatedServer extends FakeServer {
  GatedServer(super.replies);

  final gate = Completer<void>();

  /// How many requests have arrived, also those still held.
  int arrived = 0;

  @override
  Future<HttpReply> post(
      Uri url, Map<String, String> headers, String body) async {
    arrived++;
    await gate.future;
    return super.post(url, headers, body);
  }
}

Map<String, Object?> answer(String text) => anthropicReply([
      {'type': 'text', 'text': text},
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final graph = graphOf(notes);
  RoamTools tools() => RoamTools(graph,
      readNote: (path) async => notes[path],
      visibility: const AiVisibility({'private'}));

  late MemoryChatStorage storage;
  late ChatStore store;

  setUp(() {
    storage = MemoryChatStorage();
    store = ChatStore(storage, now: () => DateTime.utc(2026, 10, 20, 12));
  });

  /// A chat of [store] with a session on [server].
  Chat chatOn(FakeServer server,
      {ChatStore? on, ToolImage? Function(ToolCall)? toolImage}) {
    final chat = (on ?? store).create(
      providerId: 'anthropic',
      providerName: 'Anthropic',
      model: anthropic.model,
      startNodeId: 'ideas',
      startNodeTitle: 'Ideas',
    );
    chat.attach(ChatSession(
        tools: tools(),
        config: anthropic,
        post: server.post,
        toolImage: toolImage));
    return chat;
  }

  group('saving', () {
    test('a chat is saved and read again with its transcript', () async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'org_roam_find',
            'input': {'search': 'Plan'},
          },
        ], stop: 'tool_use'),
        answer('It is [[id:plan][Plan]].'),
      ]);
      final chat = chatOn(server);
      await chat.send('Where is my plan?', context: 'I am at Ideas.');
      await store.flush();

      // One file per chat, in the storage, with the title and the model.
      final text = storage.files[chat.id]!;
      expect(storage.files, hasLength(1));
      final json = jsonDecode(text) as Map;
      expect(json['model'], 'claude-sonnet-5-5');
      expect(json['provider'], 'anthropic');
      expect(json['startNode'], 'ideas');
      expect(json['created'], isA<String>());
      expect(json['lastUsed'], '2026-10-20T12:00:00.000Z');
      expect(text, contains('Where is my plan?'));
      // Never the key.
      expect(text, isNot(contains('sk-test')));

      final again = ChatStore(storage);
      await again.load();
      final loaded = again.chats.single;
      expect(loaded.id, chat.id);
      expect(loaded.title, 'Where is my plan?');
      expect(loaded.model, 'claude-sonnet-5-5');
      expect(loaded.providerName, 'Anthropic');
      expect(loaded.startNodeTitle, 'Ideas');
      expect(loaded.transcript, hasLength(4));
      expect((loaded.transcript.last as AssistantMessage).text,
          'It is [[id:plan][Plan]].');
      final first = loaded.transcript.first as UserMessage;
      expect(first.forModel, 'I am at Ideas.\n\nWhere is my plan?');
      final results = loaded.transcript[2] as ToolResults;
      expect(results.results.single.content, contains('plan | Plan'));
      expect(loaded.usage.output, chat.usage.output);
    });

    test('an old chat is continued with its saved transcript', () async {
      final first = FakeServer([answer('Plan is a note.')]);
      final chat = chatOn(first);
      await chat.send('What is Plan?');
      await store.flush();

      final again = ChatStore(storage);
      await again.load();
      final loaded = again.chats.single;
      final second = FakeServer([answer('Yes.')]);
      loaded.attach(
          ChatSession(tools: tools(), config: anthropic, post: second.post));
      await loaded.send('Really?');

      final messages = second.requests.single.body['messages'] as List;
      expect(messages, hasLength(3));
      expect(jsonEncode(messages[0]), contains('What is Plan?'));
      expect(jsonEncode(messages[1]), contains('Plan is a note.'));
      expect(jsonEncode(messages[2]), contains('Really?'));
    });

    test('a changed model adds a line, saved with the chat (#203)', () async {
      final server = FakeServer([answer('One.'), answer('Two.')]);
      final chat = chatOn(server);
      await chat.send('First');
      // The same model: no line.
      expect(chat.transcript.whereType<ModelChanged>(), isEmpty);
      chat.session!.model = 'claude-opus-5-5';
      chat.model = 'claude-opus-5-5';
      await chat.send('Second');
      final lines = chat.transcript.whereType<ModelChanged>().toList();
      expect(lines.single.text, 'Model changed to anthropic/claude-opus-5-5');
      // The line comes before my message and is not sent.
      expect(chat.transcript[2], isA<ModelChanged>());
      expect(chat.transcript[3], isA<UserMessage>());
      expect(jsonEncode(server.requests.last.body['messages']),
          isNot(contains('Model changed')));
      expect(server.requests.last.body['model'], 'claude-opus-5-5');
      await store.flush();

      final again = ChatStore(storage);
      await again.load();
      final loaded = again.chats.single;
      expect(loaded.model, 'claude-opus-5-5');
      expect(loaded.transcript.whereType<ModelChanged>().single.text,
          'Model changed to anthropic/claude-opus-5-5');
      // Continued with the same model: no second line.
      final next = FakeServer([answer('Three.')]);
      loaded.attach(ChatSession(
          tools: tools(),
          config: anthropic.withModel('claude-opus-5-5'),
          post: next.post));
      await loaded.send('Third');
      expect(loaded.transcript.whereType<ModelChanged>(), hasLength(1));
    });

    test('the bytes of an image are not saved, only a line', () async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'org_roam_find',
            'input': {'search': 'Plan'},
          },
        ], stop: 'tool_use'),
        answer('Done.'),
      ]);
      final bytes = List<int>.generate(60, (i) => 200 + i % 50);
      final chat = chatOn(server,
          toolImage: (call) => ToolImage(bytes, 'image/png'));
      await chat.send('Draw it.');
      await store.flush();

      final text = storage.files[chat.id]!;
      expect(text, isNot(contains(base64Encode(bytes))));
      expect(text, contains('[image: image/png'));
      final again = ChatStore(storage);
      await again.load();
      final results = again.chats.single.transcript[2] as ToolResults;
      expect(results.results.single.image, isNull);
      expect(results.results.single.content, contains('[image: image/png'));
    });

    test('a chat without a message is not in the list', () {
      chatOn(FakeServer([]));
      expect(store.chats, isEmpty);
      expect(storage.files, isEmpty);
    });

    test('a damaged file is skipped and counted, never a crash', () async {
      final server = FakeServer([answer('Fine.')]);
      final chat = chatOn(server);
      await chat.send('Good one.');
      await store.flush();
      storage.files['broken'] = '{this is not json';
      storage.files['not-a-chat'] = '{"version": 1}';
      storage.files['half'] = jsonEncode({
        'created': '2026-10-20T12:00:00.000Z',
        'lastUsed': '2026-10-20T12:00:00.000Z',
        'transcript': [
          {'type': 'user'},
        ],
      });

      final again = ChatStore(storage);
      await again.load();
      expect(again.chats.map((c) => c.id), [chat.id]);
      expect(again.skipped, 3);
      // The files are left where they are.
      expect(storage.files.keys, containsAll(['broken', 'not-a-chat']));
    });

    test('rename keeps the title; an empty title brings the message back',
        () async {
      final chat = chatOn(FakeServer([answer('Hi.')]));
      await chat.send('A long first question about the plan');
      store.rename(chat, '  Plan talk ');
      await store.flush();
      expect(chat.title, 'Plan talk');
      expect(jsonDecode(storage.files[chat.id]!)['title'], 'Plan talk');
      store.rename(chat, '');
      expect(chat.title, 'A long first question about the plan');
    });

    test('the title is the first message cut to one line', () async {
      final chat = chatOn(FakeServer([answer('Hi.')]));
      await chat.send('First line\nsecond line ${'x' * 100}');
      expect(chat.title, startsWith('First line second line xxx'));
      expect(chat.title.length, lessThanOrEqualTo(61));
      expect(chat.title, endsWith('…'));
    });
  });

  group('clean-up', () {
    test('a chat older than "Keep chats for" is deleted at the start',
        () async {
      var day = DateTime.utc(2026, 5, 1);
      final writing = ChatStore(storage, now: () => day);
      final old = chatOn(FakeServer([answer('Old.')]), on: writing);
      await old.send('Old question');
      day = DateTime.utc(2026, 10, 1);
      final recent = chatOn(FakeServer([answer('New.')]), on: writing);
      await recent.send('Recent question');
      await writing.flush();
      expect(storage.files, hasLength(2));

      final starting = ChatStore(storage, now: () => DateTime.utc(2026, 10, 29));
      await starting.load(keepDays: 90);
      await starting.flush();
      expect(starting.chats.map((c) => c.title), ['Recent question']);
      expect(storage.files.keys, [recent.id]);
    });

    test('"Always" keeps every chat', () async {
      final writing = ChatStore(storage, now: () => DateTime.utc(2020, 1, 1));
      final old = chatOn(FakeServer([answer('Old.')]), on: writing);
      await old.send('Very old');
      await writing.flush();
      final starting = ChatStore(storage, now: () => DateTime.utc(2026, 10, 29));
      await starting.load();
      expect(starting.chats, hasLength(1));
    });

    test('the settings keep the two new values', () {
      final settings = AiSettings.fromJson(
          const AiSettings(maxParallelChats: 2, keepChatsDays: 365).toJson());
      expect(settings.maxParallelChats, 2);
      expect(settings.keepChatsDays, 365);
      const defaults = AiSettings();
      expect(defaults.maxParallelChats, 3);
      expect(defaults.keepChatsDays, 90);
      // A value that is not a choice keeps the default.
      expect(AiSettings.fromJson({'keepChatsDays': 45}).keepChatsDays, 90);
      expect(AiSettings.fromJson({'keepChatsDays': 0}).keepChatsDays, 0);
      expect(AiSettings.fromJson({'maxParallelChats': 0}).maxParallelChats, 3);
    });
  });

  group('closing the screen', () {
    test('the answer arrives in the store while nobody looks', () async {
      final server = GatedServer([answer('Here it is.')]);
      final chat = chatOn(server);
      final done = chat.send('Question');
      await pumpEventQueue();
      expect(chat.sending, isTrue);
      expect(chat.unseen, isFalse);
      server.gate.complete();
      await done;
      expect(chat.sending, isFalse);
      expect((chat.transcript.last as AssistantMessage).text, 'Here it is.');
      // Nobody had it open: the list shows a dot.
      expect(chat.unseen, isTrue);
      await store.flush();
      expect(jsonDecode(storage.files[chat.id]!)['unseen'], true);
      chat.markSeen();
      expect(chat.unseen, isFalse);
    });

    test('no dot for a chat that is open', () async {
      final chat = chatOn(FakeServer([answer('Hi.')]));
      chat.viewers++;
      await chat.send('Question');
      expect(chat.unseen, isFalse);
    });
  });

  group('parallel chats', () {
    test('two chats send at the same time and both answer', () async {
      final one = GatedServer([answer('First answer.')]);
      final two = GatedServer([answer('Second answer.')]);
      final a = chatOn(one);
      final b = chatOn(two);
      final doneA = a.send('One');
      final doneB = b.send('Two');
      await pumpEventQueue();
      // Both requests are on their way before either answer came.
      expect(one.arrived, 1);
      expect(two.arrived, 1);
      expect(b.queued, isFalse);
      one.gate.complete();
      two.gate.complete();
      await Future.wait([doneA, doneB]);
      expect((a.transcript.last as AssistantMessage).text, 'First answer.');
      expect((b.transcript.last as AssistantMessage).text, 'Second answer.');
      expect(store.chats, hasLength(2));
    });

    test('with a limit of 1, the second waits and then runs', () async {
      store.maxParallel = 1;
      final one = GatedServer([answer('First answer.')]);
      final two = GatedServer([answer('Second answer.')]);
      two.gate.complete();
      final a = chatOn(one);
      final b = chatOn(two);
      final doneA = a.send('One');
      final doneB = b.send('Two');
      await pumpEventQueue();
      expect(one.arrived, 1);
      expect(two.arrived, 0);
      expect(b.queued, isTrue);
      expect(b.sending, isTrue);
      expect(b.pendingText, 'Two');
      // The waiting chat shows in the list already.
      expect(store.chats, contains(b));

      one.gate.complete();
      await doneA;
      await doneB;
      expect(b.queued, isFalse);
      expect(two.arrived, 1);
      expect((b.transcript.last as AssistantMessage).text, 'Second answer.');
      expect(b.pendingText, isNull);
    });

    test('a higher limit lets a waiting chat start at once', () async {
      store.maxParallel = 1;
      final one = GatedServer([answer('A.')]);
      final two = GatedServer([answer('B.')]);
      two.gate.complete();
      final a = chatOn(one);
      final b = chatOn(two);
      final doneA = a.send('One');
      final doneB = b.send('Two');
      await pumpEventQueue();
      expect(b.queued, isTrue);
      store.maxParallel = 2;
      await doneB;
      expect(two.arrived, 1);
      one.gate.complete();
      await doneA;
    });

    test('a chat deleted while it waits never sends', () async {
      store.maxParallel = 1;
      final one = GatedServer([answer('A.')]);
      final two = GatedServer([answer('B.')]);
      two.gate.complete();
      final a = chatOn(one);
      final b = chatOn(two);
      final doneA = a.send('One');
      final doneB = b.send('Two');
      await pumpEventQueue();
      store.remove(b);
      await doneB;
      expect(two.arrived, 0);
      expect(b.queued, isFalse);
      expect(b.sending, isFalse);
      one.gate.complete();
      await doneA;
      expect(store.chats, [a]);
    });

    test('an error ends the turn, frees the place and can be sent again',
        () async {
      store.maxParallel = 1;
      final server = FakeServer([
        const HttpReply(401, '{"error": {"message": "bad key"}}'),
        answer('Now it works.'),
      ]);
      final chat = chatOn(server);
      await chat.send('Question');
      expect(chat.error, contains('refused the API key'));
      expect(chat.errorDetail, isNotNull);
      expect(chat.session!.waiting, isTrue);
      await chat.resume();
      expect(chat.error, isNull);
      expect((chat.transcript.last as AssistantMessage).text, 'Now it works.');
    });
  });

  group('deleting', () {
    test('delete removes the file, restore brings the chat back', () async {
      final chat = chatOn(FakeServer([answer('Hi.')]));
      await chat.send('Question');
      await store.flush();
      expect(storage.files, hasLength(1));

      store.remove(chat);
      await store.flush();
      expect(store.chats, isEmpty);
      expect(storage.files, isEmpty);

      store.restore(chat);
      await store.flush();
      expect(store.chats, [chat]);
      expect(storage.files.keys, [chat.id]);
      expect(chat.title, 'Question');
      expect(chat.transcript, hasLength(2));
    });

    test('the list is in the order of last use', () async {
      var day = DateTime.utc(2026, 10, 1);
      final ordered = ChatStore(storage, now: () => day);
      final first = chatOn(FakeServer([answer('A.')]), on: ordered);
      await first.send('First');
      day = DateTime.utc(2026, 10, 2);
      final second = chatOn(FakeServer([answer('B.')]), on: ordered);
      await second.send('Second');
      expect(ordered.chats, [second, first]);
    });
  });

  group('Save chat as note', () {
    test('each question and answer is a heading', () {
      final note = chatAsNote(
        title: 'Plan talk',
        transcript: [
          const UserMessage('Where is my plan?', context: 'Not shown.'),
          const AssistantMessage(
              text: 'Looking.', model: 'm', toolCalls: [ToolCall('t', 'x', {})]),
          const ToolResults([]),
          const AssistantMessage(
              text: 'It is [[id:plan][Plan]].\n* not a heading', model: 'm'),
          const UserMessage('Thanks.\nAnd more.'),
          const AssistantMessage(text: '', model: 'm'),
        ],
        provider: 'Anthropic',
        model: 'claude-sonnet-5-5',
        created: DateTime(2026, 10, 20, 12),
      );
      expect(note.title, 'Plan talk');
      expect(note.body, '''
A chat with the AI (Anthropic, claude-sonnet-5-5) on 2026-10-20.

* Question: Where is my plan?
* Answer
Looking.

It is [[id:plan][Plan]].
,* not a heading

* Question: Thanks.
Thanks.
And more.
* Answer
(No answer.)
''');
      expect(note.body, isNot(contains('Not shown')));
      expect(chatNoteTag, 'chat');
    });

    test('an empty title becomes "Chat"', () {
      final note = chatAsNote(
          title: '  ',
          transcript: const [],
          provider: 'P',
          model: 'm',
          created: DateTime(2026, 1, 2));
      expect(note.title, 'Chat');
    });
  });
}
