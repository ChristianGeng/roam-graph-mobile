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

import 'ai_chat_test.dart' show FakeServer, anthropic;
import 'ai_settings_test.dart' show MemoryAiSettingsStore;
import 'ai_visibility_test.dart' show graphOf, notes;
import 'chat_screen_test.dart' show ask, keysWithAnthropic;
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
  debugPrint('settle start');
  await tester.pump();
  var n = 0;
  while (tester.binding.hasScheduledFrame && n < 50) {
    await tester.pump(const Duration(milliseconds: 100));
    debugPrint('L59');
    n++;
  }
  debugPrint('settle end $n');
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
    store = ChatStore(storage);
  });

  Future<void> openList(
    WidgetTester tester,
    FakeServer server, {
    NoteWriter? writer,
    AiSettings settings = const AiSettings(),
  }) async {
    await store.load();
    debugPrint('L87');
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
            post: server.post,
            agentLog: MemoryAgentLog(),
            getModels: (url, headers) async => const HttpReply(404, ''),
          ),
        ),
      ),
    ));
    await settle(tester);
    debugPrint('L105');
  }

  Finder row(String id) => find.byKey(ValueKey('chat-row-$id'));

  testWidgets('the rows: order, title, note, model, time and the dot',
      (tester) async {
    await openList(tester, FakeServer([]));
    debugPrint('L112');
    // The last used first.
    final fresh = tester.getTopLeft(find.text('Fresh chat')).dy;
    final newer = tester.getTopLeft(find.text('Newer chat')).dy;
    final older = tester.getTopLeft(find.text('Older chat')).dy;
    expect(fresh, lessThan(newer));
    debugPrint('L117');
    expect(newer, lessThan(older));
    debugPrint('L118');
    expect(find.textContaining('Note: Ideas'), findsOneWidget);
    debugPrint('L119');
    expect(find.textContaining('Anthropic · claude-sonnet-5-5'), findsNWidgets(3));
    debugPrint('L120');
    expect(find.textContaining('2026-10-0'), findsNWidgets(3));
    debugPrint('L121');
    // A dot on the chat with a new answer.
    expect(find.byKey(const ValueKey('chat-dot-fresh')), findsOneWidget);
    debugPrint('L123');
    expect(find.byKey(const ValueKey('chat-dot-newer')), findsNothing);
    debugPrint('L124');
    expect(find.byKey(const ValueKey('chat-damaged')), findsNothing);
    debugPrint('L125');
  });

  testWidgets('a damaged file is named in the list, not a crash',
      (tester) async {
    storage.files['broken'] = 'not json';
    await openList(tester, FakeServer([]));
    debugPrint('L131');
    expect(find.text('One saved chat could not be read and was skipped.'),
        findsOneWidget);
    expect(find.text('Newer chat'), findsOneWidget);
    debugPrint('L134');
  });

  testWidgets('no chats: the list says how to start', (tester) async {
    storage.files.clear();
    await openList(tester, FakeServer([]));
    debugPrint('L139');
    expect(find.byKey(const ValueKey('chat-none')), findsOneWidget);
    debugPrint('L140');
  });

  testWidgets('a spinner while a chat works, a dot when the answer came',
      (tester) async {
    final server = GatedServer([answer('Done.')]);
    await openList(tester, server);
    debugPrint('L146');
    // Ask in the chat list's chat "Newer chat" without opening it.
    final chat = store.chats.firstWhere((c) => c.id == 'newer');
    chat.attach(_sessionOn(server));
    final done = chat.send('Another question');
    await tester.pump();
    debugPrint('L151');
    expect(find.byKey(const ValueKey('chat-spinner-newer')), findsOneWidget);
    debugPrint('L152');
    expect(find.byKey(const ValueKey('chat-dot-newer')), findsNothing);
    debugPrint('L153');

    server.gate.complete();
    await done;
    debugPrint('L156');
    await settle(tester);
    debugPrint('L157');
    expect(find.byKey(const ValueKey('chat-spinner-newer')), findsNothing);
    debugPrint('L158');
    expect(find.byKey(const ValueKey('chat-dot-newer')), findsOneWidget);
    debugPrint('L159');
  });

  testWidgets('a waiting chat shows "Waiting"', (tester) async {
    final server = GatedServer([answer('Done.'), answer('Done too.')]);
    await openList(tester, server);
    debugPrint('L164');
    store.maxParallel = 1;
    final one = store.chats.firstWhere((c) => c.id == 'newer');
    final two = store.chats.firstWhere((c) => c.id == 'older');
    one.attach(_sessionOn(server));
    two.attach(_sessionOn(server));
    final doneOne = one.send('First');
    final doneTwo = two.send('Second');
    await tester.pump();
    debugPrint('L172');
    expect(find.byKey(const ValueKey('chat-spinner-newer')), findsOneWidget);
    debugPrint('L173');
    expect(find.byKey(const ValueKey('chat-wait-older')), findsOneWidget);
    debugPrint('L174');
    expect(find.textContaining('Waiting'), findsOneWidget);
    debugPrint('L175');

    server.gate.complete();
    await Future.wait([doneOne, doneTwo]);
    debugPrint('L178');
    await settle(tester);
    debugPrint('L179');
    expect(find.textContaining('Waiting'), findsNothing);
    debugPrint('L180');
  });

  testWidgets('rename from the row\'s menu', (tester) async {
    await openList(tester, FakeServer([]));
    debugPrint('L184');
    await tester.tap(find.byKey(const ValueKey('chat-menu-newer')));
    debugPrint('L185');
    await settle(tester);
    debugPrint('L186');
    await tester.tap(find.text('Rename'));
    debugPrint('L187');
    await settle(tester);
    debugPrint('L188');
    await tester.enterText(
        find.byKey(const ValueKey('chat-rename-field')), 'Mushrooms');
    await tester.tap(find.byKey(const ValueKey('chat-rename-ok')));
    debugPrint('L191');
    await settle(tester);
    debugPrint('L192');
    expect(find.text('Mushrooms'), findsOneWidget);
    debugPrint('L193');
    expect(find.text('Newer chat'), findsNothing);
    debugPrint('L194');
    await store.flush();
    debugPrint('L195');
    expect(jsonDecode(storage.files['newer']!)['title'], 'Mushrooms');
    debugPrint('L196');
  });

  testWidgets('swipe to delete, with Undo in a snack bar', (tester) async {
    await openList(tester, FakeServer([]));
    debugPrint('L200');
    await tester.drag(row('newer'), const Offset(-800, 0));
    debugPrint('L201');
    await settle(tester);
    debugPrint('L202');
    expect(find.text('Newer chat'), findsNothing);
    debugPrint('L203');
    expect(find.text('Chat deleted.'), findsOneWidget);
    debugPrint('L204');
    await store.flush();
    debugPrint('L205');
    expect(storage.files.containsKey('newer'), isFalse);
    debugPrint('L206');

    await tester.tap(find.text('Undo'));
    debugPrint('L208');
    await settle(tester);
    debugPrint('L209');
    expect(find.text('Newer chat'), findsOneWidget);
    debugPrint('L210');
    await store.flush();
    debugPrint('L211');
    expect(storage.files.containsKey('newer'), isTrue);
    debugPrint('L212');
  });

  testWidgets('delete from the menu', (tester) async {
    await openList(tester, FakeServer([]));
    debugPrint('L216');
    await tester.tap(find.byKey(const ValueKey('chat-menu-older')));
    debugPrint('L217');
    await settle(tester);
    debugPrint('L218');
    await tester.tap(find.text('Delete'));
    debugPrint('L219');
    await settle(tester);
    debugPrint('L220');
    expect(find.text('Older chat'), findsNothing);
    debugPrint('L221');
    await store.flush();
    debugPrint('L222');
    expect(storage.files.keys, unorderedEquals(['newer', 'fresh']));
    debugPrint('L223');
  });

  testWidgets('an old chat opens with its transcript and goes on',
      (tester) async {
    final server = FakeServer([answer('Second answer.')]);
    await openList(tester, server);
    debugPrint('L229');
    await tester.tap(find.text('Newer chat'));
    debugPrint('L230');
    await settle(tester);
    debugPrint('L231');
    expect(find.byType(ChatScreen), findsOneWidget);
    debugPrint('L232');
    expect(find.text('Question of Newer chat'), findsOneWidget);
    debugPrint('L233');
    expect(find.text('Answer of Newer chat', findRichText: true), findsOneWidget);
    debugPrint('L234');
    expect(find.text('Anthropic · claude-sonnet-5-5'), findsOneWidget);
    debugPrint('L235');

    await ask(tester, 'And then?');
    debugPrint('L237');
    // The saved transcript went with the new message.
    final messages = server.requests.single.body['messages'] as List;
    expect(messages, hasLength(3));
    debugPrint('L240');
    expect(jsonEncode(messages.first), contains('Question of Newer chat'));
    debugPrint('L241');
    expect(find.text('Second answer.', findRichText: true), findsOneWidget);
    debugPrint('L242');

    await store.flush();
    debugPrint('L244');
    final saved = jsonDecode(storage.files['newer']!) as Map;
    expect((saved['transcript'] as List), hasLength(4));
    debugPrint('L246');
    expect(saved['title'], 'Newer chat');
    debugPrint('L247');
    expect(jsonEncode(saved), isNot(contains('sk-test')));
    debugPrint('L248');
  });

  testWidgets('opening a chat with a dot takes the dot away', (tester) async {
    await openList(tester, FakeServer([]));
    debugPrint('L252');
    await tester.tap(find.text('Fresh chat'));
    debugPrint('L253');
    await settle(tester);
    debugPrint('L254');
    await tester.pageBack();
    debugPrint('L255');
    await settle(tester);
    debugPrint('L256');
    expect(find.byKey(const ValueKey('chat-dot-fresh')), findsNothing);
    debugPrint('L257');
    await store.flush();
    debugPrint('L258');
    expect(jsonDecode(storage.files['fresh']!)['unseen'], false);
    debugPrint('L259');
  });

  testWidgets('closing the chat screen while a request runs: the answer '
      'arrives in the store and shows when opened again', (tester) async {
    storage.files.clear();
    final server = GatedServer([answer('It is done.')]);
    await openList(tester, server);
    debugPrint('L266');
    await tester.tap(find.byKey(const ValueKey('chat-new')));
    debugPrint('L267');
    await settle(tester);
    debugPrint('L268');
    await tester.enterText(
        find.byKey(const ValueKey('chat-input')), 'Slow question');
    await tester.tap(find.byTooltip('Send'));
    debugPrint('L271');
    await tester.pump();
    debugPrint('L272');
    expect(server.arrived, 1);
    debugPrint('L273');

    // Back to the list while the request is still out.
    await tester.pageBack();
    debugPrint('L276');
    await tester.pump();
    debugPrint('L277');
    await tester.pump(const Duration(seconds: 1));
    debugPrint('L278');
    expect(find.byType(ChatScreen), findsNothing);
    debugPrint('L279');
    expect(find.text('Slow question'), findsOneWidget);
    debugPrint('L280');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    debugPrint('L281');

    server.gate.complete();
    await settle(tester);
    debugPrint('L284');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    debugPrint('L285');
    final chat = store.chats.single;
    expect(chat.unseen, isTrue);
    debugPrint('L287');
    expect(find.byKey(ValueKey('chat-dot-${chat.id}')), findsOneWidget);
    debugPrint('L288');

    await tester.tap(find.text('Slow question'));
    debugPrint('L290');
    await settle(tester);
    debugPrint('L291');
    expect(find.text('It is done.', findRichText: true), findsOneWidget);
    debugPrint('L292');
    expect(chat.unseen, isFalse);
    debugPrint('L293');
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
    debugPrint('L306');
    await tester.tap(find.text('Newer chat'));
    debugPrint('L307');
    await settle(tester);
    debugPrint('L308');
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    debugPrint('L309');
    await settle(tester);
    debugPrint('L310');
    await tester.tap(find.text('Save chat as note'));
    debugPrint('L311');
    await settle(tester);
    debugPrint('L312');

    expect(find.byType(CaptureScreen), findsOneWidget);
    debugPrint('L314');
    // Nothing is written before I save.
    expect(written, isEmpty);
    debugPrint('L316');
    final title =
        tester.widget<TextField>(find.byKey(const ValueKey('capture-title')));
    expect(title.controller!.text, 'Newer chat');
    debugPrint('L319');
    await tester.tap(find.byTooltip('Save'));
    debugPrint('L320');
    await settle(tester);
    debugPrint('L321');
    final (name, text) = written.single;
    expect(name, endsWith('-newer_chat.org'));
    debugPrint('L323');
    expect(text, contains('#+title: Newer chat'));
    debugPrint('L324');
    expect(text, contains('#+filetags: :chat:'));
    debugPrint('L325');
    expect(text, contains('* Question: Question of Newer chat'));
    debugPrint('L326');
    expect(text, contains('* Answer\nAnswer of Newer chat'));
    debugPrint('L327');
  });

  testWidgets('the size of a long chat is shown with a hint',
      (tester) async {
    storage.files['long'] = jsonEncode({
      ...(jsonDecode(chatFile('Long chat',
          lastUsed: '2026-10-04T10:00:00.000Z')) as Map<String, Object?>),
      'transcript': [
        {'type': 'user', 'text': 'x' * 120000},
      ],
    });
    await openList(tester, FakeServer([]));
    debugPrint('L339');
    await tester.tap(find.text('Newer chat'));
    debugPrint('L340');
    await settle(tester);
    debugPrint('L341');
    expect(find.byKey(const ValueKey('chat-long')), findsNothing);
    debugPrint('L342');
    expect(find.textContaining('Size of this chat: about 42 characters'),
        findsOneWidget);
    await tester.pageBack();
    debugPrint('L345');
    await settle(tester);
    debugPrint('L346');
    await tester.tap(find.byKey(const ValueKey('chat-tile-long')));
    debugPrint('L347');
    await settle(tester);
    debugPrint('L348');
    expect(find.byKey(const ValueKey('chat-long')), findsOneWidget);
    debugPrint('L349');
  });

  testWidgets('the limit is a field under Agent and limits', (tester) async {
    await openList(tester, FakeServer([]));
    debugPrint('L353');
    await tester.tap(find.byTooltip('AI settings'));
    debugPrint('L354');
    await settle(tester);
    debugPrint('L355');
    await tester.tap(find.byKey(const ValueKey('ai-agent')));
    debugPrint('L356');
    await settle(tester);
    debugPrint('L357');
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('max-parallel-chats')), 200);
    final field = tester
        .widget<TextField>(find.byKey(const ValueKey('max-parallel-chats')));
    expect(field.controller!.text, '3');
    debugPrint('L362');
    await tester.pageBack();
    debugPrint('L363');
    await settle(tester);
    debugPrint('L364');
    await tester.tap(find.byKey(const ValueKey('ai-privacy')));
    debugPrint('L365');
    await settle(tester);
    debugPrint('L366');
    expect(find.byKey(const ValueKey('keep-chats')), findsOneWidget);
    debugPrint('L367');
    expect(find.text('90 days'), findsOneWidget);
    debugPrint('L368');
  });
}

ChatSession _sessionOn(FakeServer server) => ChatSession(
      tools: RoamTools(graphOf(notes),
          readNote: (path) async => notes[path],
          visibility: const AiVisibility({'private'})),
      config: anthropic,
      post: server.post,
    );
