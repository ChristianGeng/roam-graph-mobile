import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart' show HttpReply;
import 'package:roam_graph_mobile/ai/ai_models.dart' show HttpGet, clearModelCache;
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/chat_screen.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/web_links.dart';

import '../graph_view/graph_screen_test.dart'
    show MemoryNodeMemory, algorithmsHere, layoutHere;
import '../edit/note_editor_test.dart' show MemoryNoteStore;
import 'ai_chat_test.dart' show FakeServer, anthropicReply;
import 'ai_settings_test.dart' show MemoryAiSettingsStore, MemoryKeyStore;
import 'ai_visibility_test.dart' show graphOf, notes;

final graph = graphOf(notes);

MemoryKeyStore keysWithAnthropic() =>
    MemoryKeyStore()..keys['anthropic'] = 'sk-test';

Future<void> openChat(
  WidgetTester tester,
  FakeServer server, {
  MemoryKeyStore? keys,
  RoamNode? startNode,
  NoteWriter? writer,
  void Function(String id)? opened,
  AiSettings settings = const AiSettings(),
  AgentLog? agentLog,
  ValueNotifier<RoamGraph>? graphNotifier,
  UrlOpener? openUrl,
  HttpGet? getModels,
}) async {
  await tester.pumpWidget(AiSettingsHost(
    store: MemoryAiSettingsStore(settings),
    keys: keys ?? keysWithAnthropic(),
    child: MaterialApp(
      home: ChatScreen(
        graph: graphNotifier ?? ValueNotifier(graph),
        readNote: (path) async => notes[path],
        startNode: startNode,
        writer: writer,
        openNode: (_, id) => opened?.call(id),
        post: server.post,
        agentLog: agentLog ?? MemoryAgentLog(),
        openUrl: openUrl ?? (uri) async => true,
        // No model list unless a test gives one.
        getModels: getModels ?? (url, headers) async => const HttpReply(404, ''),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> ask(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('chat-input')), text);
  await tester.tap(find.byTooltip('Send'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a conversation with a tool call, a link and the token count',
      (tester) async {
    final server = FakeServer([
      anthropicReply([
        {
          'type': 'tool_use',
          'id': 't1',
          'name': 'org_roam_find',
          'input': {'search': 'Plan'},
        },
      ], stop: 'tool_use'),
      anthropicReply([
        {'type': 'text', 'text': 'Your plan is [[id:plan][the Plan note]].'},
      ], read: 500),
    ]);
    String? opened;
    await openChat(tester, server,
        startNode: graph.nodes['ideas'], opened: (id) => opened = id);
    expect(find.text('Anthropic · claude-sonnet-5-5'), findsOneWidget);
    await ask(tester, 'Where is my plan?');

    expect(find.text('Where is my plan?'), findsOneWidget);
    // The node the chat came from goes to the model, not on screen.
    final first = server.requests.first.body['messages'][0]['content'][0];
    expect(first['text'],
        startsWith('I am looking at the note "Ideas" (ID ideas).'));
    expect(find.text('I am looking at the note'), findsNothing);

    // The tool call, collapsed; opened, its result.
    expect(find.text('find(search: Plan)'), findsOneWidget);
    expect(find.textContaining('plan | Plan | plan.org'), findsNothing);
    await tester.tap(find.text('find(search: Plan)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('plan | Plan | plan.org'), findsOneWidget);

    expect(find.byKey(const ValueKey('chat-usage')), findsOneWidget);
    expect(find.textContaining('of them 500 from the cache'), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('the Plan note'));
    expect(opened, 'plan');
  });

  testWidgets('an answer without text says so', (tester) async {
    final server = FakeServer([anthropicReply([])]);
    await openChat(tester, server);
    await ask(tester, 'Hello?');
    expect(find.text('The model sent no text.'), findsOneWidget);
  });

  testWidgets('without a key, the chat says where to enter it',
      (tester) async {
    final server = FakeServer([]);
    await openChat(tester, server, keys: MemoryKeyStore());
    expect(find.text('Enter the API key for Anthropic in AI settings.'),
        findsOneWidget);
    final send = tester.widget<IconButton>(find.widgetWithIcon(
        IconButton, Icons.send));
    expect(send.onPressed, isNull);
    expect(server.requests, isEmpty);
  });

  testWidgets('answers and tool results can be copied (#94)', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final server = FakeServer([
      anthropicReply([
        {
          'type': 'tool_use',
          'id': 't1',
          'name': 'org_roam_find',
          'input': {'search': 'Plan'},
        },
      ], stop: 'tool_use'),
      anthropicReply([
        {'type': 'text', 'text': 'It is [[id:plan][Plan]].'},
      ]),
    ]);
    await openChat(tester, server);
    await ask(tester, 'Where is my plan?');

    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    expect(copied.last, 'It is [[id:plan][Plan]].');
    expect(find.text('Copied.'), findsOneWidget);

    await tester.tap(find.text('find(search: Plan)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-tool-copy')));
    await tester.pumpAndSettle();
    expect(copied.last, startsWith('org_roam_find(search: Plan)\n\n'));
    expect(copied.last, contains('plan | Plan | plan.org'));
  });

  testWidgets('an error, then "Send again"', (tester) async {
    // Each failure is tried twice more before the error shows (#131).
    final server = FakeServer([
      for (var i = 0; i < 3; i++) const SocketException('offline'),
      anthropicReply([
        {'type': 'text', 'text': 'Here now.'},
      ]),
    ]);
    await openChat(tester, server);
    await ask(tester, 'Hello?');
    expect(find.textContaining('No connection to api.anthropic.com'),
        findsOneWidget);
    await tester.tap(find.text('Send again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Here now.', findRichText: true),
        findsOneWidget);
    expect(find.byKey(const ValueKey('chat-error')), findsNothing);
    expect(find.text('Hello?'), findsOneWidget);
  });

  testWidgets('the model can be switched to the strong one', (tester) async {
    final server = FakeServer([
      anthropicReply([
        {'type': 'text', 'text': 'Sure.'},
      ]),
    ]);
    await openChat(tester, server);
    await tester.tap(find.byTooltip('Model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Strong: claude-opus-5-5'));
    await tester.pumpAndSettle();
    expect(find.text('Anthropic · claude-opus-5-5'), findsOneWidget);
    await ask(tester, 'Think hard.');
    expect(server.requests.single.body['model'], 'claude-opus-5-5');
  });

  group('"Save as new node" (#145)', () {
    NoteWriter plainWriter(List<(String, String)> written) => NoteWriter(
          create: (name, text) async {
            written.add((name, text));
            return Created(name);
          },
          allowWriting: () async {},
        );

    testWidgets('off mode: a request without tools fills "New node"',
        (tester) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'text',
            'text': 'Good question! Here is an overview:\n'
                'JACK runs on top of [[id:plan][Plan]].\n'
                'Shall I say more?',
          },
        ]),
        anthropicReply([
          {
            'type': 'text',
            'text': '```json\n{"title": "JACK and ALSA", "body": '
                '"JACK runs on top of [[id:plan][Plan]]."}\n```',
          },
        ]),
      ]);
      final written = <(String, String)>[];
      String? opened;
      // Without an editor the AI may not write: off mode.
      await openChat(tester, server,
          startNode: graph.nodes['ideas'],
          writer: plainWriter(written),
          opened: (id) => opened = id);
      await ask(tester, 'Tell me about JACK.');
      await tester.tap(find.text('Save as new node'));
      await tester.pumpAndSettle();

      // The extra request: no tools, its own system prompt, the answer and
      // the instruction; not shown in the chat.
      expect(server.requests, hasLength(2));
      final extra = server.requests.last.body;
      expect(extra.containsKey('tools'), isFalse);
      expect(jsonEncode(extra['system']), contains('JSON object'));
      final messages = extra['messages'] as List;
      expect(jsonEncode(messages), contains('Good question!'));
      expect(jsonEncode(messages.last), contains('{\\"title\\"'));
      expect(jsonEncode(messages.last), contains('the app adds that link'));
      expect(find.textContaining('Reply with only a JSON'), findsNothing);

      expect(find.byType(CaptureScreen), findsOneWidget);
      // Nothing is written before I save.
      expect(written, isEmpty);
      final title = tester.widget<TextField>(
          find.byKey(const ValueKey('capture-title')));
      expect(title.controller!.text, 'JACK and ALSA');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final (name, text) = written.single;
      expect(name, endsWith('-jack_and_alsa.org'));
      expect(text, contains('#+title: JACK and ALSA'));
      expect(text, contains('JACK runs on top of [[id:plan][Plan]].'));
      expect(text, isNot(contains('Good question')));
      // Linked to the note the chat came from.
      expect(text, contains('[[id:ideas][Ideas]]'));
      expect(opened, isNotNull);
      expect(jsonEncode([for (final r in server.requests) r.body]),
          isNot(contains('My diary')));
    });

    testWidgets('review mode: tool results go as text, without tool calls',
        (tester) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'org_roam_find',
            'input': {'search': 'Plan'},
          },
        ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'Your plan: [[id:plan][Plan]].'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': '{"title": "My plan", "body": "See '
              '[[id:plan][Plan]]."}'},
        ]),
      ]);
      final writer = NoteWriter(
        create: (name, text) async => Created(name),
        allowWriting: () async {},
        editor: NoteEditor(
            store: MemoryNoteStore(Map.of(notes)),
            history: MemoryEditHistory()),
      );
      await openChat(tester, server,
          writer: writer,
          settings: const AiSettings(editMode: AiEditMode.review));
      await ask(tester, 'Where is my plan?');
      await tester.tap(find.text('Save as new node'));
      await tester.pumpAndSettle();

      final extra = jsonEncode(server.requests.last.body);
      expect(server.requests.last.body.containsKey('tools'), isFalse);
      expect(extra, isNot(contains('tool_use')));
      expect(extra, isNot(contains('tool_result')));
      // The IDs the tools gave are in it.
      expect(extra, contains('plan | Plan | plan.org'));
      final title = tester.widget<TextField>(
          find.byKey(const ValueKey('capture-title')));
      expect(title.controller!.text, 'My plan');
    });

    testWidgets('an unreadable answer: the first line is the title, as '
        'before', (tester) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'text',
            'text': '# Jack and ALSA\nJACK runs on top of [[id:plan][Plan]].',
          },
        ]),
        anthropicReply([
          {'type': 'text', 'text': 'Sorry, I cannot do that.'},
        ]),
      ]);
      final written = <(String, String)>[];
      await openChat(tester, server,
          startNode: graph.nodes['ideas'], writer: plainWriter(written));
      await ask(tester, 'Write a note on JACK.');
      await tester.tap(find.text('Save as new node'));
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be read'), findsOneWidget);
      final title = tester.widget<TextField>(
          find.byKey(const ValueKey('capture-title')));
      expect(title.controller!.text, 'Jack and ALSA');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final (_, text) = written.single;
      expect(text, contains('JACK runs on top of [[id:plan][Plan]].'));
      expect(text, contains('[[id:ideas][Ideas]]'));
    });

    testWidgets('a failed request also falls back', (tester) async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Morels\nA mushroom.'},
        ]),
        const HttpReply(400, '{"error": {"message": "bad"}}'),
      ]);
      await openChat(tester, server, writer: plainWriter([]));
      await ask(tester, 'Morels?');
      await tester.tap(find.text('Save as new node'));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not write the note'), findsOneWidget);
      final title = tester.widget<TextField>(
          find.byKey(const ValueKey('capture-title')));
      expect(title.controller!.text, 'Morels');
    });

    testWidgets('the extra request shows as a wait on the button',
        (tester) async {
      final server = _GatedServer([
        anthropicReply([
          {'type': 'text', 'text': 'Morels\nA mushroom.'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': '{"title": "Morel", "body": "A mushroom."}'},
        ]),
      ], gateAt: 1);
      await openChat(tester, server, writer: plainWriter([]));
      await ask(tester, 'Morels?');
      await tester.tap(find.text('Save as new node'));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-save-wait')), findsOneWidget);
      expect(
          tester.widget<TextButton>(find.byKey(const ValueKey('chat-save-1')))
              .onPressed,
          isNull);
      server.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CaptureScreen), findsOneWidget);
    });

    testWidgets('agent mode: the fixed message, then create_node',
        (tester) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'text',
            'text': 'Good question! Morels are [[id:plan][Plan]]-worthy '
                'mushrooms.',
          },
        ]),
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 'a1',
            'name': 'create_node',
            'input': {
              'title': 'Morels',
              'text': 'Mushrooms, see [[id:plan][Plan]] and '
                  '[[id:ideas][Ideas]].',
            },
          },
        ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
      ]);
      final store = MemoryNoteStore(Map.of(notes));
      final writer = NoteWriter(
        create: (name, text) async {
          store.files[name] = text;
          return Created(name);
        },
        allowWriting: () async {},
        editor: NoteEditor(store: store, history: MemoryEditHistory()),
      );
      final log = MemoryAgentLog();
      await openChat(tester, server,
          startNode: graph.nodes['ideas'], writer: writer, agentLog: log);
      await ask(tester, 'Morels?');
      // Only the first answer has the button now.
      await tester.tap(find.byKey(const ValueKey('chat-save-1')));
      await tester.pumpAndSettle();

      // The message is mine, in the chat and in the request.
      expect(find.textContaining('Make a new note from your last answer'),
          findsOneWidget);
      final sent = jsonEncode(server.requests[1].body['messages']);
      expect(sent, contains('Make a new note from your last answer'));
      expect(sent, contains('[[id:ideas][Ideas]]'));
      // The write tools are offered: the normal agent loop.
      expect(
          [for (final t in server.requests[1].body['tools'] as List) t['name']],
          contains('create_node'));
      // No capture screen; the note is made, logged and summarised.
      expect(find.byType(CaptureScreen), findsNothing);
      expect(store.files.length, notes.length + 1);
      expect(log.entries, hasLength(1));
      expect(find.byKey(const ValueKey('agent-summary-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-undo-2')), findsOneWidget);
    });

    testWidgets('agent mode: the button is disabled while the chat sends',
        (tester) async {
      final server = _GatedServer([
        anthropicReply([
          {'type': 'text', 'text': 'Morels are mushrooms.'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
      ], gateAt: 1);
      final writer = NoteWriter(
        create: (name, text) async => Created(name),
        allowWriting: () async {},
        editor: NoteEditor(
            store: MemoryNoteStore(Map.of(notes)),
            history: MemoryEditHistory()),
      );
      await openChat(tester, server, writer: writer);
      await ask(tester, 'Morels?');
      await tester.tap(find.byKey(const ValueKey('chat-save-1')));
      await tester.pump();
      expect(
          tester.widget<TextButton>(find.byKey(const ValueKey('chat-save-1')))
              .onPressed,
          isNull);
      server.gate.complete();
      await tester.pumpAndSettle();
      expect(
          tester.widget<TextButton>(find.byKey(const ValueKey('chat-save-1')))
              .onPressed,
          isNotNull);
    });
  });

  testWidgets('a model gone from the provider\'s list is named (#113)',
      (tester) async {
    clearModelCache();
    addTearDown(clearModelCache);
    await openChat(tester, FakeServer([]),
        getModels: (url, headers) async => HttpReply(
            200,
            jsonEncode({
              'data': [
                {'id': 'claude-sonnet-6'},
              ],
            })));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-model-gone')), findsOneWidget);
    expect(
        find.text('claude-sonnet-5-5 is not in Anthropic\'s model list now. '
            'Choose another model.'),
        findsOneWidget);
  });

  testWidgets('a model in the list, or no list, says nothing (#113)',
      (tester) async {
    clearModelCache();
    addTearDown(clearModelCache);
    await openChat(tester, FakeServer([]),
        getModels: (url, headers) async => HttpReply(
            200,
            jsonEncode({
              'data': [
                {'id': 'claude-sonnet-5-5'},
              ],
            })));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-model-gone')), findsNothing);
    clearModelCache();
    await openChat(tester, FakeServer([]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-model-gone')), findsNothing);
  });

  testWidgets('a web link in an answer opens in the browser (#108)',
      (tester) async {
    final server = FakeServer([
      anthropicReply([
        {
          'type': 'text',
          'text': 'See [[https://example.org/doc][the docs]] and '
              '[[file:x.org][a file]].',
        },
      ]),
    ]);
    final opened = <Uri>[];
    await openChat(tester, server, openUrl: (uri) async {
      opened.add(uri);
      return true;
    });
    await ask(tester, 'Where?');
    await tester.tapOnText(find.textRange.ofSubstring('the docs'));
    await tester.pump();
    expect(opened, [Uri.parse('https://example.org/doc')]);
    expect(find.text('Opening https://example.org/doc'), findsOneWidget);
    await tester.tapOnText(find.textRange.ofSubstring('a file'));
    await tester.pump();
    expect(opened, hasLength(1));
    expect(
        find.text('The chat opens id:, web, mail and phone links, not '
            '"file:x.org".'),
        findsOneWidget);
  });

  group('agent mode (#82)', () {
    testWidgets('the AI changes notes itself; a summary and "Undo all"',
        (tester) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 'a1',
            'name': 'create_node',
            'input': {'title': 'Morel', 'text': 'A mushroom.'},
          },
          {
            'type': 'tool_use',
            'id': 'a2',
            'name': 'append_to_node',
            'input': {'id': 'plan', 'text': 'Mushrooms come next.'},
          },
        ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
      ]);
      final store = MemoryNoteStore(Map.of(notes));
      final writer = NoteWriter(
        create: (name, text) async {
          store.files[name] = text;
          return Created(name);
        },
        allowWriting: () async {},
        editor: NoteEditor(store: store, history: MemoryEditHistory()),
      );
      final log = MemoryAgentLog();
      await openChat(tester, server, writer: writer, agentLog: log);
      await ask(tester, 'Make a note on morels.');

      // Agent is the default: the write tools are offered, the review
      // tools are not.
      final tools = [
        for (final t in server.requests.first.body['tools'] as List) t['name']
      ];
      expect(tools, containsAll(['create_node', 'append_to_node',
          'edit_node_text', 'add_link']));
      expect(tools, isNot(contains('propose_edit')));
      // Both changes made, without a tap.
      expect(store.files.length, notes.length + 1);
      expect(store.files['plan.org'], endsWith('Mushrooms come next.\n'));
      expect(log.entries, hasLength(2));
      expect(find.text('1 note created, 1 changed'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-file-plan.org')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('agent-undo-0')));
      await tester.pumpAndSettle();
      expect(store.files, notes);
      expect(find.text('Undone.'), findsWidgets);
    });

    testWidgets('"Recent AI changes" undoes them after the chat is closed '
        '(#99)', (tester) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 'a1',
            'name': 'create_node',
            'input': {'title': 'Morel', 'text': 'A mushroom.'},
          },
          {
            'type': 'tool_use',
            'id': 'a2',
            'name': 'append_to_node',
            'input': {'id': 'plan', 'text': 'Mushrooms come next.'},
          },
        ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
      ]);
      final store = MemoryNoteStore(Map.of(notes));
      final writer = NoteWriter(
        create: (name, text) async {
          store.files[name] = text;
          return Created(name);
        },
        allowWriting: () async {},
        editor: NoteEditor(store: store, history: MemoryEditHistory()),
      );
      final log = MemoryAgentLog();
      await openChat(tester, server, writer: writer, agentLog: log);
      await ask(tester, 'Make a note on morels.');
      expect(store.files.length, notes.length + 1);

      // A new chat: the old one's "Undo all" is gone.
      await tester.pumpWidget(const SizedBox());
      await openChat(tester, FakeServer([]), writer: writer, agentLog: log);
      await tester.tap(find.byTooltip('Recent AI changes'));
      await tester.pumpAndSettle();
      expect(find.text('Make a note on morels.'), findsOneWidget);
      expect(find.textContaining('1 note created, 1 changed'), findsOneWidget);

      await tester.tap(find.text('Make a note on morels.'));
      await tester.pumpAndSettle();
      expect(find.text('Plan'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recent-undo-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-undo')));
      await tester.pumpAndSettle();
      expect(store.files, notes);
      expect(find.text('Undone.'), findsOneWidget);
      expect(find.text('Undone'), findsOneWidget);
      expect(find.textContaining('· undone'), findsOneWidget);
    });

    testWidgets('"Off" offers no write tools', (tester) async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Hi.'},
        ]),
      ]);
      final writer = NoteWriter(
        create: (name, text) async => Created(name),
        allowWriting: () async {},
        editor: NoteEditor(
            store: MemoryNoteStore(Map.of(notes)),
            history: MemoryEditHistory()),
      );
      await openChat(tester, server,
          writer: writer,
          settings: const AiSettings(editMode: AiEditMode.off));
      await ask(tester, 'Hi');
      final tools = [
        for (final t in server.requests.first.body['tools'] as List) t['name']
      ];
      expect(tools, isNot(contains('create_node')));
      expect(tools, isNot(contains('propose_edit')));
    });
  });

  group('AI edits (#39)', () {
    var lastBody = '';
    Future<(MemoryNoteStore, MemoryEditHistory)> proposeAndOpen(
        WidgetTester tester, Map<String, Object?> input) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 'e1',
            'name': 'propose_edit',
            'input': input,
          },
        ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'Proposed; please review it.'},
        ]),
      ]);
      final store = MemoryNoteStore(Map.of(notes));
      final history = MemoryEditHistory();
      final writer = NoteWriter(
        create: (name, text) async => Created(name),
        allowWriting: () async {},
        editor: NoteEditor(store: store, history: history),
      );
      await openChat(tester, server,
          writer: writer,
          settings: const AiSettings(editMode: AiEditMode.review));
      await ask(tester, 'Link Plan to Health.');
      // The tool is offered, and its result tells the model nothing is
      // saved yet.
      final tools = [
        for (final t in server.requests.first.body['tools'] as List) t['name']
      ];
      expect(tools, contains('propose_edit'));
      lastBody = jsonEncode(server.requests.last.body);
      return (store, history);
    }

    testWidgets('a proposal is saved only after the diff', (tester) async {
      final (store, history) = await proposeAndOpen(tester, {
        'node_id': 'plan',
        'mode': 'append',
        'text': 'Also [[id:health][Health]] and [[id:nope][X]].',
        'reason': 'Plan mentions health.',
      });
      expect(lastBody, contains('it is not saved yet'));
      expect(find.text('Add to "Plan"'), findsOneWidget);
      // Nothing is written by the tool.
      expect(store.writes, 0);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('The AI: Plan mentions health.'), findsOneWidget);
      expect(find.text('Links to IDs that are no note: nope.'), findsOneWidget);
      expect(find.text('+Also [[id:health][Health]] and [[id:nope][X]].'),
          findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.files['plan.org'],
          endsWith('[[id:ideas][Ideas]].\nAlso [[id:health][Health]] and '
              '[[id:nope][X]].\n'));
      expect((await history.versions('plan.org')).single.text,
          notes['plan.org']);
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('a note hidden from AI cannot be proposed', (tester) async {
      final (store, _) = await proposeAndOpen(tester, {
        'node_id': 'diary',
        'mode': 'append',
        'text': 'x',
      });
      expect(lastBody, contains('There is no note with the ID diary'));
      expect(find.text('Review'), findsNothing);
      expect(store.writes, 0);
    });
  });

  testWidgets('a change set: accept one, reject one, save, undo (#76)',
      (tester) async {
    final server = FakeServer([
      anthropicReply([
        {
          'type': 'tool_use',
          'id': 's1',
          'name': 'propose_edits',
          'input': {
            'summary': 'Link Plan and Ideas.',
            'edits': [
              {
                'node_id': 'plan',
                'mode': 'append',
                'text': 'See also [[id:ideas][Ideas]].',
                'reason': 'Related.',
              },
              {
                'node_id': 'ideas',
                'mode': 'append',
                'text': 'See also [[id:plan][Plan]].',
              },
            ],
          },
        },
      ], stop: 'tool_use'),
      anthropicReply([
        {'type': 'text', 'text': 'Please review the two edits.'},
      ]),
    ]);
    final store = MemoryNoteStore(Map.of(notes));
    final writer = NoteWriter(
      create: (name, text) async => Created(name),
      allowWriting: () async {},
      editor: NoteEditor(store: store, history: MemoryEditHistory()),
    );
    await openChat(tester, server,
        writer: writer,
        settings: const AiSettings(editMode: AiEditMode.review));
    await ask(tester, 'Link my plan and ideas.');
    final tool = (server.requests.first.body['tools'] as List)
        .firstWhere((t) => t['name'] == 'propose_edits');
    expect(tool['description'], contains('at most 20 notes'));
    expect(find.text('Changes to 2 notes'), findsOneWidget);
    expect(store.writes, 0);

    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('chat-change-set-2-0')),
        matching: find.text('Review')));
    await tester.pumpAndSettle();
    expect(find.text('AI change set'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('change-0')),
        matching: find.text('Accept')));
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('change-1')),
        matching: find.text('Reject')));
    await tester.pump();
    expect(find.textContaining('1 accepted, which change 1 file and add 1 link'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('change-save')));
    await tester.pumpAndSettle();

    expect(store.files['plan.org'], endsWith('See also [[id:ideas][Ideas]].\n'));
    expect(store.files['ideas.org'], notes['ideas.org']);
    expect(find.text('1 saved, 0 refused, 1 rejected.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('change-undo')));
    await tester.pumpAndSettle();
    expect(store.files['plan.org'], notes['plan.org']);
    expect(find.text('The change set is undone.'), findsOneWidget);
  });

  testWidgets('"Ask AI" from the graph and from a node', (tester) async {
    await tester.pumpWidget(AiSettingsHost(
      store: MemoryAiSettingsStore(),
      keys: keysWithAnthropic(),
      child: MaterialApp(
        home: GraphScreen(
          graph: ValueNotifier<RoamGraph>(graph),
          readNote: (path) async => notes[path],
          nodeMemory: MemoryNodeMemory('plan'),
          computeLayout: layoutHere,
          computeAlgorithms: algorithmsHere,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(tester.widget<ChatScreen>(find.byType(ChatScreen)).startNode?.id,
        'plan');

    await tester.pageBack();
    await tester.pumpAndSettle();
    // The test window is a tablet in landscape: the node is in the side
    // pane (#16).
    expect(find.byType(NodeScreen), findsOneWidget);
    await tester.tap(find.byTooltip('AI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.startNode?.id, 'plan');
    // A link in an answer opens the node on a page above the chat, not in
    // the side pane behind it.
    chat.openNode!(tester.element(find.byType(ChatScreen)), 'ideas');
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen, skipOffstage: true), findsNothing);
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text('Ideas')),
        findsOneWidget);
  });

  group('review of #67', () {
    testWidgets('a hidden note is not named to the AI', (tester) async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Hi.'},
        ]),
      ]);
      await openChat(tester, server, startNode: graph.nodes['diary']);
      expect(find.textContaining('This note is hidden from AI'), findsOneWidget);
      await ask(tester, 'What is in it?');
      final sent = jsonEncode([for (final r in server.requests) r.body]);
      expect(sent, isNot(contains('My diary')));
      expect(sent, isNot(contains('diary')));
    });

    testWidgets('after an error, a new question waits for "Send again"',
        (tester) async {
      final server = FakeServer([
        for (var i = 0; i < 3; i++) const SocketException('offline'),
      ]);
      await openChat(tester, server);
      await ask(tester, 'First?');
      final send = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send));
      expect(send.onPressed, isNull);
      expect(find.text('Send again'), findsOneWidget);
    });

    testWidgets('the tools follow a rescan and new hidden tags',
        (tester) async {
      final server = FakeServer([
        for (var i = 0; i < 2; i++) ...[
          anthropicReply([
            {
              'type': 'tool_use',
              'id': 't$i',
              'name': 'org_roam_find',
              'input': {'search': ''},
            },
          ], stop: 'tool_use'),
          anthropicReply([
            {'type': 'text', 'text': 'Done $i.'},
          ]),
        ],
      ]);
      final notifier = ValueNotifier(graph);
      final store = MemoryAiSettingsStore();
      await tester.pumpWidget(AiSettingsHost(
        store: store,
        keys: keysWithAnthropic(),
        child: MaterialApp(
          home: ChatScreen(
            graph: notifier,
            readNote: (path) async => notes[path],
            post: server.post,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // A scan brings a new note.
      notifier.value = graphOf({
        ...notes,
        'new.org': ':PROPERTIES:\n:ID: new\n:END:\n#+title: New plan\n'
            '#+filetags: :work:\n',
      });
      await ask(tester, 'All notes?');
      final first = jsonEncode(server.requests[1].body);
      expect(first, contains('New plan'));
      // Now "work" is hidden too.
      await AiSettingsScope.change(
          tester.element(find.byType(ChatScreen)),
          const AiSettings(hiddenTags: ['private', 'work']));
      await tester.pumpAndSettle();
      await ask(tester, 'And now?');
      final second = jsonEncode(server.requests[3].body['messages'].last);
      expect(second, isNot(contains('New plan')));
    });
  });
}

/// A [FakeServer] that holds the request at [gateAt] until [gate] is
/// completed, to see the screen while it waits.
class _GatedServer extends FakeServer {
  _GatedServer(super.replies, {required this.gateAt});

  final int gateAt;
  final gate = Completer<void>();

  @override
  Future<HttpReply> post(
      Uri url, Map<String, String> headers, String body) async {
    if (requests.length == gateAt) await gate.future;
    return super.post(url, headers, body);
  }
}
