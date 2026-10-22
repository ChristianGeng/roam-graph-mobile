import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/note_from_answer.dart';

import 'ai_chat_test.dart'
    show FakeServer, anthropic, anthropicReply, deepseek, openAiReply;
import 'ai_visibility_test.dart' show graphOf, notes;

// Synthetic notes only (AGENTS.md).

void main() {
  group('parseNoteJson', () {
    test('a plain object', () {
      expect(parseNoteJson('{"title": "Morels", "body": "A mushroom."}'),
          (title: 'Morels', body: 'A mushroom.'));
    });

    test('in a code fence, with text around it', () {
      expect(
          parseNoteJson('Here it is:\n```json\n{"title": " Morels\\n in '
              'spring ", "body": "* Where\\nIn woods."}\n```\nDone.'),
          (title: 'Morels in spring', body: '* Where\nIn woods.'));
    });

    test('a #+title: or #+filetags: line at the start goes', () {
      expect(
          parseNoteJson('{"title": "Morels", "body": "#+title: Morels\\n'
              '#+filetags: :fungi:\\n\\nA mushroom."}'),
          (title: 'Morels', body: 'A mushroom.'));
    });

    test('no body is an empty body', () {
      expect(parseNoteJson('{"title": "Morels"}'),
          (title: 'Morels', body: ''));
    });

    test('unreadable answers', () {
      expect(parseNoteJson('Sorry, I cannot.'), isNull);
      expect(parseNoteJson('{"title": "Morels", "body": '), isNull);
      expect(parseNoteJson('{"title": "", "body": "Text"}'), isNull);
      expect(parseNoteJson('{"title": 3, "body": "Text"}'), isNull);
      expect(parseNoteJson('{"title": "T", "body": ["a"]}'), isNull);
      expect(parseNoteJson('["title", "body"]'), isNull);
    });
  });

  group('agentSaveRequest', () {
    test('the last answer, with the note the chat came from', () {
      final text = agentSaveRequest(
          answer: 'Anything',
          isLast: true,
          start: (id: 'ideas', title: 'Ideas [draft]'));
      expect(text, startsWith('Make a new note from your last answer with '
          'create_node'));
      expect(text, contains('in the language of the answer'));
      expect(text, contains('without chat phrases'));
      expect(text, contains('with the IDs the tools gave you'));
      expect(text, contains('[[id:ideas][Ideas draft]]'));
    });

    test('an earlier answer is named by how it begins', () {
      final text = agentSaveRequest(
          answer: '\n  Morels grow in spring.\nMore text.', isLast: false);
      expect(text, contains('your answer that begins "Morels grow in '
          'spring."'));
      expect(text, isNot(contains('opened the chat from')));
      final long = agentSaveRequest(answer: 'x' * 100, isLast: false);
      expect(long, contains('"${'x' * 60}…"'));
    });
  });

  group('noteRequestEntries', () {
    const call = ToolCall('t1', 'org_roam_find', {'search': 'Plan'});
    final transcript = <ChatEntry>[
      const UserMessage('Where is my plan?', context: 'I am looking at Ideas.'),
      const AssistantMessage(
          text: '', toolCalls: [call], model: 'm', raw: ['raw']),
      ToolResults([ToolResult(call, 'plan | Plan | ${'y' * 5000}')]),
      const AssistantMessage(text: 'It is [[id:plan][Plan]].', model: 'm'),
      const UserMessage('Thanks.'),
      const AssistantMessage(text: 'You are welcome.', model: 'm'),
    ];

    test('plain text up to the answer, then the instruction', () {
      final entries = noteRequestEntries(transcript, 3, startLinked: false);
      expect(entries, hasLength(4));
      expect((entries[0] as UserMessage).text,
          'I am looking at Ideas.\n\nWhere is my plan?');
      final results = (entries[1] as UserMessage).text;
      expect(results, contains('org_roam_find({"search":"Plan"})'));
      expect(results, contains('plan | Plan'));
      expect(results, contains('(cut here)'));
      expect(results.length, lessThan(maxToolResultChars + 200));
      final answer = entries[2] as AssistantMessage;
      expect(answer.text, 'It is [[id:plan][Plan]].');
      expect(answer.toolCalls, isEmpty);
      expect(answer.raw, isNull);
      final instruction = (entries[3] as UserMessage).text;
      expect(instruction, contains('{"title": "...", "body": "..."}'));
      expect(instruction, isNot(contains('the app adds that link')));
      // What came after the answer is not sent.
      expect(entries.whereType<UserMessage>().map((e) => e.text),
          isNot(contains('Thanks.')));
    });

    test('the start note is left to the app', () {
      final entries = noteRequestEntries(transcript, 5, startLinked: true);
      expect((entries.last as UserMessage).text,
          contains('the app adds that link'));
    });
  });

  group('ChatSession.askOnce', () {
    final graph = graphOf(notes);

    Future<(FakeServer, ChatSession)> chatOf(
        ProviderConfig config, List<Object> replies) async {
      final server = FakeServer(replies);
      final session = ChatSession(
        tools: RoamTools(graph, readNote: (path) async => notes[path]),
        config: config,
        post: server.post,
      );
      return (server, session);
    }

    test('Anthropic: no tools, its own system prompt, nothing kept',
        () async {
      final (server, session) = await chatOf(anthropic, [
        anthropicReply([
          {'type': 'text', 'text': 'Morels grow in spring.'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': '{"title": "Morels", "body": "Spring."}'},
        ]),
      ]);
      await session.send('Morels?');
      final reply = await session.askOnce(
          noteRequestEntries(session.transcript, 1, startLinked: false),
          system: noteFromAnswerSystem);
      expect(parseNoteJson(reply), (title: 'Morels', body: 'Spring.'));
      final body = server.requests.last.body;
      expect(body['tools'], isEmpty);
      expect(jsonEncode(body['system']), contains('You have no tools here'));
      // The conversation is as it was; the tokens count.
      expect(session.transcript, hasLength(2));
      expect(session.usage.output, 40);
    });

    test('OpenAI-compatible: no tools either', () async {
      final (server, session) = await chatOf(deepseek, [
        openAiReply({'role': 'assistant', 'content': 'Morels.'}),
        openAiReply({
          'role': 'assistant',
          'content': '{"title": "Morels", "body": ""}',
        }),
      ]);
      await session.send('Morels?');
      await session.askOnce(
          noteRequestEntries(session.transcript, 1, startLinked: false),
          system: noteFromAnswerSystem);
      final body = server.requests.last.body;
      expect(body['tools'], isEmpty);
      expect(body['messages'][0],
          {'role': 'system', 'content': noteFromAnswerSystem});
    });

    test('a cut answer is an error', () async {
      final (_, session) = await chatOf(anthropic, [
        anthropicReply([
          {'type': 'text', 'text': 'Morels.'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': '{"title": "Mo'},
        ], stop: 'max_tokens'),
      ]);
      await session.send('Morels?');
      expect(
          session.askOnce(
              noteRequestEntries(session.transcript, 1, startLinked: false),
              system: noteFromAnswerSystem),
          throwsA(isA<AiError>()));
    });
  });
}
