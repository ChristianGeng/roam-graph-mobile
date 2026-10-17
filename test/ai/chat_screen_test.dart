import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/chat_screen.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph_view/graph_screen_test.dart'
    show MemoryNodeMemory, algorithmsHere, layoutHere;
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
}) async {
  await tester.pumpWidget(AiSettingsHost(
    store: MemoryAiSettingsStore(),
    keys: keys ?? keysWithAnthropic(),
    child: MaterialApp(
      home: ChatScreen(
        graph: ValueNotifier(graph),
        readNote: (path) async => notes[path],
        startNode: startNode,
        writer: writer,
        openNode: (_, id) => opened?.call(id),
        post: server.post,
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

  testWidgets('an error, then "Send again"', (tester) async {
    final server = FakeServer([
      const SocketException('offline'),
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

  testWidgets('an answer becomes a new node through the capture screen',
      (tester) async {
    final server = FakeServer([
      anthropicReply([
        {
          'type': 'text',
          'text': '# Jack and ALSA\nJACK runs on top of [[id:plan][Plan]].',
        },
      ]),
    ]);
    final written = <(String, String)>[];
    final writer = NoteWriter(
      create: (name, text) async {
        written.add((name, text));
        return Created(name);
      },
      allowWriting: () async {},
    );
    String? opened;
    await openChat(tester, server,
        startNode: graph.nodes['ideas'],
        writer: writer,
        opened: (id) => opened = id);
    await ask(tester, 'Write a note on JACK.');
    await tester.tap(find.text('Save as new node'));
    await tester.pumpAndSettle();

    expect(find.byType(CaptureScreen), findsOneWidget);
    // Nothing is written before I save.
    expect(written, isEmpty);
    final title = tester.widget<TextField>(
        find.byKey(const ValueKey('capture-title')));
    expect(title.controller!.text, 'Jack and ALSA');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final (name, text) = written.single;
    expect(name, endsWith('-jack_and_alsa.org'));
    expect(text, contains('#+title: Jack and ALSA'));
    expect(text, contains('JACK runs on top of [[id:plan][Plan]].'));
    // Linked to the note the chat came from.
    expect(text, contains('[[id:ideas][Ideas]]'));
    expect(opened, isNotNull);
    expect(jsonEncode([for (final r in server.requests) r.body]),
        isNot(contains('My diary')));
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
      final server = FakeServer([const SocketException('offline')]);
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
