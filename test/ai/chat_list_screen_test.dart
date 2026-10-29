import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart' show ChatSession, HttpReply;
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart' show RoamTools;
import 'package:roam_graph_mobile/ai/ai_visibility.dart' show AiVisibility;
import 'package:roam_graph_mobile/ai/chat_list_screen.dart';
import 'package:roam_graph_mobile/ai/chat_screen.dart';
import 'package:roam_graph_mobile/ai/chat_store.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/platform/chat_background.dart';

import 'ai_chat_test.dart' show FakeServer, anthropic;
import 'ai_settings_test.dart' show MemoryAiSettingsStore;
import 'ai_visibility_test.dart' show graphOf, notes;
import 'chat_screen_test.dart' show ask, keysWithAnthropic;
import 'chat_background_test.dart' show FakeNotifier;
import 'chat_store_test.dart' show GatedServer, answer;

/// The file of a saved chat.
String chatFile(
  String title, {
  required String lastUsed,
  bool unseen = false,
  String? startTitle,
}) =>
    jsonEncode({
      'version': 1,
      'title': title,
      'created': lastUsed,
      'lastUsed': lastUsed,
      'provider': 'anthropic',
      'providerName': 'Anthropic',
      'model': 'claude-sonnet-5-5',
      'startNode': startTitle == null ? null : 'ideas',
      'startNodeTitle': startTitle,
      'unseen': unseen,
      'usage': {'input': 10, 'cached': 0, 'output': 5},
      'transcript': [
        {'type': 'user', 'text': 'Question of $title'},
        {
          'type': 'assistant',
          'text': 'Answer of $title',
          'model': 'claude-sonnet-5-5',
          'toolCalls': <Object?>[],
          'searches': <Object?>[],
          'paused': false,
        },
      ],
    });

/// Pumps until nothing is scheduled, at most 50 frames. A focused text field
/// keeps a cursor timer going, so pumpAndSettle could wait for ever.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  var n = 0;
  while (tester.binding.hasScheduledFrame && n < 50) {
    await tester.pump(const Duration(milliseconds: 100));
    n++;
  }
}

void main() {
  final graph = graphOf(notes);

  late MemoryChatStorage storage;
  late ChatStore store;

  setUp(() {
    storage = MemoryChatStorage()
      ..files['older'] = chatFile('Older chat',
          lastUsed: '2026-10-01T10:00:00.000Z', startTitle: 'Ideas')
      ..files['newer'] =
          chatFile('Newer chat', lastUsed: '2026-10-02T10:00:00.000Z')
      ..files['fresh'] = chatFile('Fresh chat',
          lastUsed: '2026-10-03T10:00:00.000Z', unseen: true);
  });

  Future<void> openList(
    WidgetTester tester,
    FakeServer server, {
    NoteWriter? writer,
    AiSettings settings = const AiSettings(),
    String? openChatId,
    AnswerNotifier notifier = const NoAnswerNotifier(),
  }) async {
    // Made here, in the test's zone, so its writes run when frames are pumped.
    store = ChatStore(storage, notifier: notifier);
    await store.load();
    await tester.pumpWidget(AiSettingsHost(
      store: MemoryAiSettingsStore(settings),
      keys: keysWithAnthropic(),
      child: ChatStoreScope(
        store: store,
        child: MaterialApp(
          home: ChatListScreen(
            graph: ValueNotifier(graph),
            readNote: (path) async => notes[path],
            writer: writer,
            openChatId: openChatId,
            post: server.post,
            agentLog: MemoryAgentLog(),
            getModels: (url, headers) async => const HttpReply(404, ''),
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  /// Lets the files written so far land. The writes are microtasks in the
  /// test's fake async zone, so pumping runs them; awaiting the store's
  /// future would wait for ever there.
  Future<void> saved(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Finder row(String id) => find.byKey(ValueKey('chat-row-$id'));

  testWidgets('the rows: order, title, note, model, time and the dot',
      (tester) async {
    await openList(tester, FakeServer([]));
    // The last used first.
    final fresh = tester.getTopLeft(find.text('Fresh chat')).dy;
    final newer = tester.getTopLeft(find.text('Newer chat')).dy;
    final older = tester.getTopLeft(find.text('Older chat')).dy;
    expect(fresh, lessThan(newer));
    expect(newer, lessThan(older));
    expect(find.textContaining('Note: Ideas'), findsOneWidget);
    expect(find.textContaining('Anthropic · claude-sonnet-5-5'), findsNWidgets(3));
    expect(find.textContaining('2026-10-0'), findsNWidgets(3));
    // A dot on the chat with a new answer.
    expect(find.byKey(const ValueKey('chat-dot-fresh')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-dot-newer')), findsNothing);
    expect(find.byKey(const ValueKey('chat-damaged')), findsNothing);
  });

  testWidgets('a damaged file is named in the list, not a crash',
      (tester) async {
    storage.files['broken'] = 'not json';
    await openList(tester, FakeServer([]));
    expect(find.text('One saved chat could not be read and was skipped.'),
        findsOneWidget);
    expect(find.text('Newer chat'), findsOneWidget);
  });

  testWidgets('no chats: the list says how to start', (tester) async {
    storage.files.clear();
    await openList(tester, FakeServer([]));
    expect(find.byKey(const ValueKey('chat-none')), findsOneWidget);
  });

  testWidgets('a spinner while a chat works, a dot when the answer came',
      (tester) async {
    final server = GatedServer([answer('Done.')]);
    await openList(tester, server);
    // Ask in the chat list's chat "Newer chat" without opening it.
    final chat = store.chats.firstWhere((c) => c.id == 'newer');
    chat.attach(_sessionOn(server));
    final done = chat.send('Another question');
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-spinner-newer')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-dot-newer')), findsNothing);

    server.gate.complete();
    await done;
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-spinner-newer')), findsNothing);
    expect(find.byKey(const ValueKey('chat-dot-newer')), findsOneWidget);
  });

  testWidgets('a waiting chat shows "Waiting"', (tester) async {
    final server = GatedServer([answer('Done.'), answer('Done too.')]);
    await openList(tester, server);
    store.maxParallel = 1;
    final one = store.chats.firstWhere((c) => c.id == 'newer');
    final two = store.chats.firstWhere((c) => c.id == 'older');
    one.attach(_sessionOn(server));
    two.attach(_sessionOn(server));
    final doneOne = one.send('First');
    final doneTwo = two.send('Second');
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-spinner-newer')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-wait-older')), findsOneWidget);
    expect(find.textContaining('Waiting'), findsOneWidget);

    server.gate.complete();
    await Future.wait([doneOne, doneTwo]);
    await settle(tester);
    expect(find.textContaining('Waiting'), findsNothing);
  });

  testWidgets('rename from the row\'s menu', (tester) async {
    await openList(tester, FakeServer([]));
    await tester.tap(find.byKey(const ValueKey('chat-menu-newer')));
    await settle(tester);
    await tester.tap(find.text('Rename'));
    await settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('chat-rename-field')), 'Mushrooms');
    await tester.tap(find.byKey(const ValueKey('chat-rename-ok')));
    await settle(tester);
    expect(find.text('Mushrooms'), findsOneWidget);
    expect(find.text('Newer chat'), findsNothing);
    await saved(tester);
    expect(jsonDecode(storage.files['newer']!)['title'], 'Mushrooms');
  });

  testWidgets('swipe to delete, with Undo in a snack bar', (tester) async {
    await openList(tester, FakeServer([]));
    await tester.drag(row('newer'), const Offset(-800, 0));
    await settle(tester);
    expect(find.text('Newer chat'), findsNothing);
    expect(find.text('Chat deleted.'), findsOneWidget);
    await saved(tester);
    expect(storage.files.containsKey('newer'), isFalse);

    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('Newer chat'), findsOneWidget);
    await saved(tester);
    expect(storage.files.containsKey('newer'), isTrue);
  });

  testWidgets('delete from the menu', (tester) async {
    await openList(tester, FakeServer([]));
    await tester.tap(find.byKey(const ValueKey('chat-menu-older')));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.text('Older chat'), findsNothing);
    await saved(tester);
    expect(storage.files.keys, unorderedEquals(['newer', 'fresh']));
  });

  testWidgets('an old chat opens with its transcript and goes on',
      (tester) async {
    final server = FakeServer([answer('Second answer.')]);
    await openList(tester, server);
    await tester.tap(find.text('Newer chat'));
    await settle(tester);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Question of Newer chat'), findsOneWidget);
    expect(find.text('Answer of Newer chat', findRichText: true), findsOneWidget);
    expect(find.text('Anthropic · claude-sonnet-5-5'), findsOneWidget);

    await ask(tester, 'And then?');
    // The saved transcript went with the new message.
    final messages = server.requests.single.body['messages'] as List;
    expect(messages, hasLength(3));
    expect(jsonEncode(messages.first), contains('Question of Newer chat'));
    expect(find.text('Second answer.', findRichText: true), findsOneWidget);

    await saved(tester);
    final file = jsonDecode(storage.files['newer']!) as Map;
    expect((file['transcript'] as List), hasLength(4));
    expect(file['title'], 'Newer chat');
    expect(jsonEncode(file), isNot(contains('sk-test')));
  });

  testWidgets('opening a chat with a dot takes the dot away', (tester) async {
    await openList(tester, FakeServer([]));
    await tester.tap(find.text('Fresh chat'));
    await settle(tester);
    await tester.pageBack();
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-dot-fresh')), findsNothing);
    await saved(tester);
    expect(jsonDecode(storage.files['fresh']!)['unseen'], false);
  });

  testWidgets('closing the chat screen while a request runs: the answer '
      'arrives in the store and shows when opened again', (tester) async {
    storage.files.clear();
    final server = GatedServer([answer('It is done.')]);
    await openList(tester, server);
    await tester.tap(find.byKey(const ValueKey('chat-new')));
    await settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('chat-input')), 'Slow question');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(server.arrived, 1);

    // Back to the list while the request is still out.
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('Slow question'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    server.gate.complete();
    await settle(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final chat = store.chats.single;
    expect(chat.unseen, isTrue);
    expect(find.byKey(ValueKey('chat-dot-${chat.id}')), findsOneWidget);

    await tester.tap(find.text('Slow question'));
    await settle(tester);
    expect(find.text('It is done.', findRichText: true), findsOneWidget);
    expect(chat.unseen, isFalse);
  });

  testWidgets('"Save chat as note" opens "New node" with the chat',
      (tester) async {
    final written = <(String, String)>[];
    final writer = NoteWriter(
      create: (name, text) async {
        written.add((name, text));
        return Created(name);
      },
      allowWriting: () async {},
    );
    await openList(tester, FakeServer([]), writer: writer);
    await tester.tap(find.text('Newer chat'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    await settle(tester);
    await tester.tap(find.text('Save chat as note'));
    await settle(tester);

    expect(find.byType(CaptureScreen), findsOneWidget);
    // Nothing is written before I save.
    expect(written, isEmpty);
    final title =
        tester.widget<TextField>(find.byKey(const ValueKey('capture-title')));
    expect(title.controller!.text, 'Newer chat');
    await tester.tap(find.byTooltip('Save'));
    await settle(tester);
    final (name, text) = written.single;
    expect(name, endsWith('-newer_chat.org'));
    expect(text, contains('#+title: Newer chat'));
    expect(text, contains('#+filetags: :chat:'));
    expect(text, contains('* Question: Question of Newer chat'));
    expect(text, contains('* Answer\nAnswer of Newer chat'));
  });

  testWidgets('the size of a long chat is shown with a hint',
      (tester) async {
    storage.files['long'] = jsonEncode({
      ...(jsonDecode(chatFile('Long chat',
          lastUsed: '2026-10-04T10:00:00.000Z')) as Map<String, Object?>),
      'transcript': [
        // The context of a message is sent again with every message, but the
        // screen does not show it.
        {'type': 'user', 'text': 'Question', 'context': 'x' * 120000},
        {
          'type': 'assistant',
          'text': 'Answer',
          'model': 'claude-sonnet-5-5',
          'toolCalls': <Object?>[],
          'searches': <Object?>[],
          'paused': false,
        },
      ],
    });
    await openList(tester, FakeServer([]));
    await tester.tap(find.text('Newer chat'));
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-long')), findsNothing);
    expect(find.textContaining('Size of this chat: about 42 characters'),
        findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('chat-tile-long')));
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-long')), findsOneWidget);
  });

  testWidgets('the limit is a field under Agent and limits', (tester) async {
    await openList(tester, FakeServer([]));
    await tester.tap(find.byTooltip('AI settings'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-agent')));
    await settle(tester);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('max-parallel-chats')), 200,
        scrollable: find.byType(Scrollable).first);
    final field = tester
        .widget<TextField>(find.byKey(const ValueKey('max-parallel-chats')));
    expect(field.controller!.text, '3');
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-privacy')));
    await settle(tester);
    expect(find.byKey(const ValueKey('keep-chats')), findsOneWidget);
    expect(find.text('90 days'), findsOneWidget);
  });

  testWidgets('a tap on a notification opens its chat from the list',
      (tester) async {
    await openList(tester, FakeServer([]));
    expect(find.byType(ChatScreen), findsNothing);
    store.requestOpen('older');
    await settle(tester);
    expect(find.byType(ChatScreen), findsOneWidget);
    // The chat that was asked for, not another.
    expect(find.text('Question of Older chat'), findsOneWidget);
    // The request is taken.
    expect(store.takeOpenRequest(), isNull);
  });

  testWidgets('the list opens the chat of a notification at once',
      (tester) async {
    await openList(tester, FakeServer([]), openChatId: 'newer');
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Question of Newer chat'), findsOneWidget);
  });

  testWidgets('a notification for a chat that is gone opens the list only',
      (tester) async {
    await openList(tester, FakeServer([]), openChatId: 'missing');
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('Newer chat'), findsOneWidget);
  });

  testWidgets('the notification switch is on, and the refusal is told',
      (tester) async {
    await openList(tester, FakeServer([]),
        notifier: FakeNotifier(granted: false));
    await tester.tap(find.byTooltip('AI settings'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-agent')));
    await settle(tester);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('notify-answers')), 200,
        scrollable: find.byType(Scrollable).first);
    final tile = tester
        .widget<SwitchListTile>(find.byKey(const ValueKey('notify-answers')));
    expect(tile.value, isTrue);
    expect(find.byKey(const ValueKey('notify-denied')), findsOneWidget);
    // Off: the line goes with it.
    await tester.tap(find.byKey(const ValueKey('notify-answers')));
    await settle(tester);
    expect(find.byKey(const ValueKey('notify-denied')), findsNothing);
  });

  testWidgets('no refusal line when notifications are allowed',
      (tester) async {
    await openList(tester, FakeServer([]), notifier: FakeNotifier());
    await tester.tap(find.byTooltip('AI settings'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-agent')));
    await settle(tester);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('notify-answers')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('notify-denied')), findsNothing);
  });
}

ChatSession _sessionOn(FakeServer server) => ChatSession(
      tools: RoamTools(graphOf(notes),
          readNote: (path) async => notes[path],
          visibility: const AiVisibility({'private'})),
      config: anthropic,
      post: server.post,
    );
