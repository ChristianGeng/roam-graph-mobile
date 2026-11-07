import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/ai/chat_store.dart';
import 'package:roam_graph_mobile/ai/tool_result_shortening.dart';

import 'ai_chat_test.dart'
    show FakeServer, anthropic, anthropicReply, deepseek, openAiReply,
        withoutCacheMarks;
import 'ai_visibility_test.dart' show graphOf, notes;

/// A synthetic note of [length] characters, first line "* [title]".
String noteText(String title, int length) {
  final head = '* $title\n';
  return head + 'x' * (length - head.length);
}

/// One message of mine in which the model read [title] with read_node
/// ([length] characters), then answered.
List<ChatEntry> readTurn(int n, String title, int length, {ToolImage? image}) {
  final call = ToolCall('call$n', 'read_node', {'title': title});
  return [
    UserMessage('Question $n'),
    AssistantMessage(text: '', toolCalls: [call], model: 'm'),
    ToolResults([ToolResult(call, noteText(title, length), image: image)]),
    AssistantMessage(text: 'Answer $n', model: 'm'),
  ];
}

/// The text of every tool result of [entries], in order.
List<String> results(List<ChatEntry> entries) => [
      for (final entry in entries)
        if (entry is ToolResults)
          for (final result in entry.results) result.content,
    ];

bool isStub(String text) => text.startsWith('[Earlier result of ');

/// A small shortening for tests: old after 3 of my messages, long above
/// 2,000 characters, a step once 5,000 characters are pending.
const small = ToolResultShortening(stepCharacters: 5000);

void main() {
  group('which results are shortened', () {
    test('a long old result becomes a stub naming tool, argument and size',
        () {
      final transcript = [
        ...readTurn(1, 'kgv', 12400),
        for (var n = 2; n <= 4; n++) ...readTurn(n, 'short$n', 100),
        const UserMessage('Now?'),
      ];
      final sent = shortenOldToolResults(transcript, small);
      final first = results(sent).first;
      expect(
          first,
          '[Earlier result of read_node "kgv" (12,400 characters), '
          'shortened. It began: "* kgv". Read it again if you need it.]');
      // The other (short) results stay as they were.
      expect(results(sent).skip(1), results(transcript).skip(1));
    });

    test('a short old result and a long recent one stay', () {
      final transcript = [
        ...readTurn(1, 'short', 1500),
        ...readTurn(2, 'filler', 6000),
        ...readTurn(3, 'recent', 9000),
        const UserMessage('Now?'),
      ];
      final sent = shortenOldToolResults(transcript, small);
      final texts = results(sent);
      // Turn 1 is old (3 of my messages after it) but short; turn 2 is
      // long but only 2 messages old; turn 3 is recent.
      expect(texts[0], noteText('short', 1500));
      expect(isStub(texts[1]), isFalse);
      expect(texts[2], noteText('recent', 9000));
    });

    test('my messages and the answers are never shortened', () {
      final transcript = [
        ...readTurn(1, 'kgv', 12000),
        UserMessage('y' * 30000),
        AssistantMessage(text: 'z' * 30000, model: 'm'),
        ...readTurn(3, 'a', 10),
        ...readTurn(4, 'b', 10),
        const UserMessage('Now?'),
      ];
      final sent = shortenOldToolResults(transcript, small);
      expect(sent.whereType<UserMessage>().map((e) => e.text),
          transcript.whereType<UserMessage>().map((e) => e.text));
      expect(sent.whereType<AssistantMessage>().map((e) => e.text),
          transcript.whereType<AssistantMessage>().map((e) => e.text));
      expect(isStub(results(sent).first), isTrue);
    });

    test('nothing changes until the old, long results pass the step', () {
      // 2,500 characters each: one is not yet a step (5,000).
      final transcript = [
        ...readTurn(1, 'a', 2500),
        ...readTurn(2, 'f2', 10),
        ...readTurn(3, 'b', 2500),
        ...readTurn(4, 'f4', 10),
        const UserMessage('Now?'),
      ];
      // At the 5th message turns 1 and 2 are old: 2,500 pending.
      expect(shortenOldToolResults(transcript, small), same(transcript));
      // At the 6th turn 3 is old too: 5,000 pending, a step shortens both.
      final later = [
        ...transcript,
        const AssistantMessage(text: 'A5', model: 'm'),
        const UserMessage('And now?'),
      ];
      final texts = results(shortenOldToolResults(later, small));
      expect(isStub(texts[0]), isTrue);
      expect(texts[1], noteText('f2', 10));
      expect(isStub(texts[2]), isTrue);
    });

    test('an image of an old result is dropped with it, and said so', () {
      final transcript = [
        ...readTurn(1, 'chart', 12000,
            image: const ToolImage([1, 2, 3], 'image/png')),
        for (var n = 2; n <= 4; n++) ...readTurn(n, 'f$n', 10),
        const UserMessage('Now?'),
      ];
      final sent = shortenOldToolResults(transcript, small);
      final result = (sent[2] as ToolResults).results.single;
      expect(result.image, isNull);
      expect(result.content, contains('Its image is left out too.'));
    });

    test('with the setting off, every result is sent whole', () {
      final transcript = [
        ...readTurn(1, 'kgv', 60000),
        for (var n = 2; n <= 5; n++) ...readTurn(n, 'f$n', 10),
        const UserMessage('Now?'),
      ];
      expect(shortenOldToolResults(transcript, ToolResultShortening.off),
          same(transcript));
      expect(
          isStub(results(shortenOldToolResults(
                  transcript, const ToolResultShortening()))
              .first),
          isTrue);
    });

    test('the transcript itself is not changed', () {
      final transcript = [
        ...readTurn(1, 'kgv', 12000),
        for (var n = 2; n <= 4; n++) ...readTurn(n, 'f$n', 10),
        const UserMessage('Now?'),
      ];
      final before = results(transcript);
      shortenOldToolResults(transcript, small);
      expect(results(transcript), before);
    });
  });

  group('requests (fake HTTP)', () {
    final graph = graphOf(notes);
    RoamTools tools() => RoamTools(graph,
        readNote: (path) async => notes[path],
        visibility: const AiVisibility({'private'}));

    /// A session with [history] already in it, on [server].
    ChatSession sessionWith(ProviderConfig config, FakeServer server,
        List<ChatEntry> history,
        {ToolResultShortening shortening = small}) {
      final session = ChatSession(
          tools: tools(),
          config: config,
          post: server.post,
          shortening: shortening);
      session.transcript.addAll(history);
      return session;
    }

    /// Whether every message of [earlier] comes again, unchanged, at the
    /// start of [later]: the request starts with the same bytes.
    void expectSameStart(Map earlier, Map later) {
      final a = withoutCacheMarks(earlier['messages']) as List;
      final b = withoutCacheMarks(later['messages']) as List;
      expect(b.length, greaterThan(a.length));
      for (var i = 0; i < a.length; i++) {
        expect(jsonEncode(b[i]), jsonEncode(a[i]), reason: 'message $i');
      }
      for (final key in ['model', 'tools', 'system']) {
        expect(jsonEncode(withoutCacheMarks(later[key])),
            jsonEncode(withoutCacheMarks(earlier[key])),
            reason: key);
      }
    }

    // Turns 1 and 3 read 3,000 characters each. At the 5th message only
    // turn 1 is old (3,000, below the step); at the 6th turn 3 is old too
    // (6,000): a step. At the 7th only the short turn 4 is newly old.
    final history = [
      ...readTurn(1, 'kgv', 3000),
      ...readTurn(2, 'f2', 10),
      ...readTurn(3, 'linux-alsa', 3000),
      ...readTurn(4, 'f4', 10),
    ];

    for (final (name, config, reply) in [
      (
        'Anthropic',
        anthropic,
        (String t) => anthropicReply([
              {'type': 'text', 'text': t},
            ])
      ),
      (
        'OpenAI-compatible',
        deepseek,
        (String t) => openAiReply({'role': 'assistant', 'content': t})
      ),
    ]) {
      test('$name: between two steps the start of the request is the same, '
          'byte for byte', () async {
        final server = FakeServer([reply('A5'), reply('A6'), reply('A7')]);
        final session = sessionWith(config, server, history);
        await session.send('Fifth?');
        await session.send('Sixth?');
        await session.send('Seventh?');
        final [fifth, sixth, seventh] =
            [for (final r in server.requests) r.body];
        // The 5th request: turn 1 is old but alone below the step.
        expect(jsonEncode(fifth), contains('* kgv'));
        expect(jsonEncode(fifth), isNot(contains('Earlier result of')));
        // The 6th: a step, turns 1 and 2 are stubs now.
        final text6 = jsonEncode(sixth);
        expect(text6, contains('Earlier result of read_node \\"kgv\\"'));
        expect(text6, contains('Earlier result of read_node \\"linux-alsa\\"'));
        expect(text6, isNot(contains('x' * 2000)));
        // The 7th: no new step, so it starts exactly as the 6th did.
        expectSameStart(sixth, seventh);
        // And the transcript keeps everything.
        expect(results(session.transcript).first, noteText('kgv', 3000));
      });
    }

    test('without the setting, the requests carry the whole results',
        () async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'A5'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': 'A6'},
        ]),
      ]);
      final session = sessionWith(anthropic, server, history,
          shortening: ToolResultShortening.off);
      await session.send('Fifth?');
      await session.send('Sixth?');
      expect(jsonEncode(server.requests.last.body),
          isNot(contains('Earlier result of')));
      expect(jsonEncode(server.requests.last.body), contains('x' * 2000));
    });
  });

  group('the setting', () {
    test('on by default, after 3 messages; saved and read back', () {
      const defaults = AiSettings();
      expect(defaults.shortenToolResults, isTrue);
      expect(defaults.shortenAfterTurns, 3);
      expect(defaults.shortening.enabled, isTrue);
      expect(defaults.shortening.afterTurns, 3);
      final changed = defaults.copyWith(
          shortenToolResults: false, shortenAfterTurns: 5);
      final back = AiSettings.fromJson(
          jsonDecode(jsonEncode(changed.toJson())));
      expect(back.shortenToolResults, isFalse);
      expect(back.shortenAfterTurns, 5);
      expect(back.shortening.enabled, isFalse);
    });

    test('settings saved before #251, or unreadable values, keep the default',
        () {
      expect(AiSettings.fromJson({'maxToolRounds': 4}).shortenToolResults,
          isTrue);
      final bad = AiSettings.fromJson(
          {'shortenToolResults': 'yes', 'shortenAfterTurns': 0});
      expect(bad.shortenToolResults, isTrue);
      expect(bad.shortenAfterTurns, 3);
    });
  });

  group('the size of a chat (#201) counts what is sent', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final graph = graphOf(notes);

    Chat chatWith(ToolResultShortening shortening) {
      final store = ChatStore(MemoryChatStorage(),
          now: () => DateTime.utc(2026, 11, 7, 12));
      final chat = store.create(
          providerId: 'anthropic',
          providerName: 'Anthropic',
          model: anthropic.model);
      chat.attach(ChatSession(
          tools: RoamTools(graph,
              readNote: (path) async => notes[path],
              visibility: const AiVisibility({'private'})),
          config: anthropic,
          shortening: shortening));
      chat.session!.transcript.addAll([
        ...readTurn(1, 'kgv', 60000),
        for (var n = 2; n <= 4; n++) ...readTurn(n, 'f$n', 10),
        const UserMessage('Now?'),
      ]);
      return chat;
    }

    test('without a session the whole chat counts, so the warning is never '
        'hidden (#271 review)', () {
      final store = ChatStore(MemoryChatStorage(),
          now: () => DateTime.utc(2026, 11, 7, 12));
      final chat = store.create(
          providerId: 'anthropic',
          providerName: 'Anthropic',
          model: anthropic.model);
      final withSession = chatWith(ToolResultShortening.off);
      // The same transcript, read from its file, before a session exists.
      final loaded = Chat.fromJson(store, chat.id,
          jsonDecode(jsonEncode(withSession.toJson())));
      expect(loaded.session, isNull);
      expect(loaded.characters, withSession.characters);
      expect(loaded.characters, greaterThan(60000));
    });

    test('an old result counts as its stub', () {
      final whole = chatWith(ToolResultShortening.off).characters;
      final shortened = chatWith(const ToolResultShortening()).characters;
      expect(whole, greaterThan(60000));
      expect(shortened, lessThan(1000));
    });
  });
}
