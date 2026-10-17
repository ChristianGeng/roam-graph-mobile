import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/ai_edit_screen.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';

import '../ai/ai_chat_test.dart' show FakeServer, anthropicReply;
import '../ai/ai_settings_test.dart' show MemoryAiSettingsStore, MemoryKeyStore;
import '../ai/ai_visibility_test.dart' show graphOf, notes;
import 'note_editor_test.dart' show MemoryNoteStore;

/// What the AI sees of ideas.org's body.
const shownIdeas = 'Open text.\n'
    '* (hidden)\n'
    '* Health\n:PROPERTIES:\n:ID: health\n:END:\nTagged below.\n'
    '** (hidden)\n'
    '* Public part\nSee [[id:doctor][(hidden 1)]] and '
    '[[id:diary][(hidden 2)]].\n';

void main() {
  final graph = graphOf(notes);
  const private = AiVisibility({'private'});

  test('hidden parts go out as placeholders and come back in place', () {
    final body = notes['ideas.org']!.substring(
        notes['ideas.org']!.indexOf('Open text.'));
    final split = private.splitHidden(body, private.hiddenIds(graph),
        numberLinks: true);
    expect(split.text, shownIdeas);
    // Without numbers, as every other tool shows it.
    expect(private.splitHidden(body, private.hiddenIds(graph)).text,
        private.filterText(body, private.hiddenIds(graph)));
    expect(split.parts, hasLength(2));
    expect(split.restore(split.text), body);
    expect(
        split.restore(shownIdeas.replaceFirst('Open text.', 'New text.')),
        body.replaceFirst('Open text.', 'New text.'));
    // Dropped, added or moved to another level: not known where it goes.
    expect(split.restore(shownIdeas.replaceFirst('* (hidden)\n', '')), isNull);
    expect(split.restore('$shownIdeas* (hidden)\n'), isNull);
    expect(
        split.restore(shownIdeas.replaceFirst('** (hidden)', '*** (hidden)')),
        isNull);
  });

  test('each hidden link comes back as it was', () {
    const body = 'See [[id:doctor][Dr A]] and [[id:doctor::notes][Dr B]].\n';
    final split = private.splitHidden(body, {'doctor'}, numberLinks: true);
    expect(split.text,
        'See [[id:doctor][(hidden 1)]] and [[id:doctor][(hidden 2)]].\n');
    expect(
        split.restore(split.text.replaceFirst('See', 'Ask')),
        body.replaceFirst('See', 'Ask'));
  });

  test('a code fence around the answer goes', () {
    expect(withoutFence('```org\nA\nB\n```\n'), 'A\nB');
    expect(withoutFence('  A\n'), 'A');
  });

  Future<(MemoryNoteStore, FakeServer)> open(
      WidgetTester tester, List<Object> replies, {String id = 'ideas'}) async {
    final store = MemoryNoteStore(Map.of(notes));
    final server = FakeServer(replies);
    final writer = NoteWriter(
      create: (name, text) async => Created(name),
      allowWriting: () async {},
      editor: NoteEditor(store: store, history: MemoryEditHistory()),
    );
    await tester.pumpWidget(AiSettingsHost(
      store: MemoryAiSettingsStore(
          const AiSettings(hiddenTags: ['private'])),
      keys: MemoryKeyStore()..keys['anthropic'] = 'sk-test',
      child: MaterialApp(
        home: AiEditScreen(
          writer: writer,
          node: graph.nodes[id]!,
          graph: graph,
          post: server.post,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (store, server);
  }

  Future<void> ask(WidgetTester tester, String instruction) async {
    await tester.enterText(
        find.byKey(const ValueKey('ai-edit-instruction')), instruction);
    await tester.tap(find.byKey(const ValueKey('ai-edit-ask')));
    await tester.pumpAndSettle();
  }

  testWidgets('the AI\'s text is saved only after the diff; hidden parts stay',
      (tester) async {
    final (store, server) = await open(tester, [
      anthropicReply([
        {
          'type': 'text',
          'text': shownIdeas.replaceFirst('Open text.', 'Open, fixed text.'),
        },
      ]),
    ]);
    await ask(tester, 'Fix the text');
    // Only what the AI may see was sent, with no tools.
    final sent = jsonEncode(server.requests.single.body);
    expect(sent, isNot(contains('Salary')));
    expect(sent, isNot(contains('Doctor')));
    expect(sent, contains('Fix the text'));
    expect(server.requests.single.body['tools'], isEmpty);

    expect(find.text('AI edit of Ideas'), findsOneWidget);
    expect(store.files['ideas.org'], notes['ideas.org']);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.files['ideas.org'],
        notes['ideas.org']!.replaceFirst('Open text.', 'Open, fixed text.'));
  });

  testWidgets('a dropped hidden part changes nothing', (tester) async {
    final (store, _) = await open(tester, [
      anthropicReply([
        {'type': 'text', 'text': 'Only this.\n'},
      ]),
    ]);
    await ask(tester, 'Shorten it');
    expect(find.byKey(const ValueKey('ai-edit-error')), findsOneWidget);
    expect(find.textContaining('dropped or moved a part hidden'),
        findsOneWidget);
    expect(store.files, notes);
  });

  testWidgets('a file changed meanwhile is not overwritten', (tester) async {
    late MemoryNoteStore store;
    (store, _) = await open(tester, [
      anthropicReply([
        {'type': 'text', 'text': 'New plan.\n'},
      ]),
    ], id: 'plan');
    await ask(tester, 'Rewrite');
    store.files['plan.org'] = '${store.files['plan.org']}From the laptop.\n';
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.files['plan.org'], endsWith('From the laptop.\n'));
    expect(store.files['plan.org'], isNot(contains('New plan.')));
    expect(find.byKey(const ValueKey('ai-edit-error')), findsOneWidget);
  });

  testWidgets('a hidden note is not sent', (tester) async {
    final (_, server) = await open(tester, [], id: 'diary');
    await ask(tester, 'Anything');
    expect(server.requests, isEmpty);
    expect(find.text('This note is hidden from AI; nothing was sent.'),
        findsOneWidget);
  });
}
