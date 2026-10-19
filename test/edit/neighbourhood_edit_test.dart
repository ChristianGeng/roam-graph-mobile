import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/ai_edit_screen.dart';
import 'package:roam_graph_mobile/edit/neighbourhood_edit.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';

import '../ai/ai_chat_test.dart' show FakeServer, anthropicReply;
import '../ai/ai_settings_test.dart' show MemoryAiSettingsStore, MemoryKeyStore;
import '../ai/ai_visibility_test.dart' show graphOf;
import 'note_editor_test.dart' show MemoryNoteStore;

/// Synthetic notes: Topic, two notes that link to it (one of them a
/// heading in a file without its own ID), two it links to (one through a
/// heading), a hidden note that links to it, and one outside.
const notes = {
  'topic.org': ':PROPERTIES:\n:ID: topic\n:END:\n#+title: Topic\n'
      'Topic links to [[id:c][C]].\n'
      '* Part\n:PROPERTIES:\n:ID: part\n:END:\nAlso [[id:d2][D two]].\n'
      '* Secret :private:\nHidden words.\n',
  'a.org': ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n'
      'A mentions [[id:topic][the topic]].\n',
  'b.org': '#+title: B file\n* B heading\n:PROPERTIES:\n:ID: b\n:END:\n'
      'See [[id:topic][Topic]].\n',
  'c.org': ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\nC text.\n',
  'd.org': ':PROPERTIES:\n:ID: d\n:END:\n#+title: D\n'
      '* D two\n:PROPERTIES:\n:ID: d2\n:END:\nD two text.\n',
  'diary.org': ':PROPERTIES:\n:ID: diary\n:END:\n#+title: Diary\n'
      '#+filetags: :private:\nAbout [[id:topic][Topic]].\n',
  'other.org': ':PROPERTIES:\n:ID: other\n:END:\n#+title: Other\n'
      'Nothing here.\n',
};

const private = AiVisibility({'private'});

Map<String, Object?> textReply(String text) => anthropicReply([
      {'type': 'text', 'text': text},
    ]);

String planReply(List<String> ids, {String summary = 'Remove the links.'}) =>
    jsonEncode({
      'summary': summary,
      'notes': [
        for (final id in ids) {'id': id, 'change': 'Remove the link to Topic.'},
      ],
    });

const newTexts = '=== ID: a ===\nA mentions the topic.\n=== end ===\n'
    '=== ID: b ===\nSee Topic.\n=== end ===\n';

void main() {
  final graph = graphOf(notes);

  NoteEditor editorOf(MemoryNoteStore store) =>
      NoteEditor(store: store, history: MemoryEditHistory());

  test('the scope is the note, its backlinks and its forward links', () async {
    final store = MemoryNoteStore(Map.of(notes));
    final scope = await neighbourhoodOf(graph.nodes['topic']!,
        editor: editorOf(store),
        graph: graph,
        visibility: private,
        maxFiles: 20);
    expect([for (final n in scope.notes) n.node.id],
        ['topic', 'a', 'b', 'c', 'd']);
    expect([for (final n in scope.notes) n.relation], [
      Relation.note,
      Relation.linksHere,
      Relation.linksHere,
      Relation.linkedFrom,
      Relation.linkedFrom,
    ]);
    expect(scope.leftOut, 0);
    // The hidden heading goes out as a placeholder.
    expect(scope.notes.first.hidden.text, contains('* (hidden)'));
    expect(scope.notes.first.hidden.text, isNot(contains('Hidden words')));

    final message = neighbourhoodMessage('Remove the links', scope);
    expect(message, contains('ID: b\nTitle: B heading\nFile: b.org'));
    expect(message, contains('=== Note 2: links here ==='));
    expect(message, isNot(contains('Diary')));
    expect(message, isNot(contains('About')));
    expect(message, isNot(contains('Hidden words')));
    expect(message, isNot(contains('Nothing here')));
  });

  test('the note and then the backlinks come first under the limit',
      () async {
    final store = MemoryNoteStore(Map.of(notes));
    final scope = await neighbourhoodOf(graph.nodes['topic']!,
        editor: editorOf(store),
        graph: graph,
        visibility: private,
        maxFiles: 3);
    expect([for (final n in scope.notes) n.node.id], ['topic', 'a', 'b']);
    expect(scope.leftOut, 2);
  });

  test('a note that got a hidden tag meanwhile is left out', () async {
    final store = MemoryNoteStore(Map.of(notes)
      ..['a.org'] = notes['a.org']!
          .replaceFirst('#+title: A\n', '#+title: A\n#+filetags: :private:\n'));
    final scope = await neighbourhoodOf(graph.nodes['topic']!,
        editor: editorOf(store),
        graph: graph,
        visibility: private,
        maxFiles: 20);
    expect([for (final n in scope.notes) n.node.id], ['topic', 'b', 'c', 'd']);
  });

  test('whether a note has neighbours', () {
    expect(hasNeighbours(graph.nodes['topic']!, graph, private), isTrue);
    expect(hasNeighbours(graph.nodes['other']!, graph, private), isFalse);
    // Topic links to it.
    expect(hasNeighbours(graph.nodes['c']!, graph, private), isTrue);
  });

  group('answers', () {
    late Neighbourhood scope;
    setUp(() async {
      scope = await neighbourhoodOf(graph.nodes['topic']!,
          editor: editorOf(MemoryNoteStore(Map.of(notes))),
          graph: graph,
          visibility: private,
          maxFiles: 20);
    });

    test('a plan is read, also inside a code fence', () {
      final plan = parsePlan('```json\n${planReply(['a', 'b'])}\n```', scope);
      expect(plan.summary, 'Remove the links.');
      expect(plan.ids, {'a', 'b'});
      expect(plan.changes.first.change, 'Remove the link to Topic.');
    });

    test('a plan with a note outside the scope is refused', () {
      for (final id in ['other', 'diary', 'nothing']) {
        expect(
            () => parsePlan(planReply(['a', id]), scope),
            throwsA(isA<NeighbourhoodError>().having(
                (e) => e.message, 'message', contains('not one of the notes'))));
      }
      expect(() => parsePlan('No plan.', scope),
          throwsA(isA<NeighbourhoodError>()));
      expect(
          () => parsePlan(planReply([], summary: 'Nothing to do.'), scope),
          throwsA(isA<NeighbourhoodError>().having(
              (e) => e.message, 'message', contains('Nothing to do.'))));
    });

    test('new texts only for notes in the plan', () {
      final plan = parsePlan(planReply(['a', 'b']), scope);
      expect(parseNewTexts(newTexts, plan),
          {'a': 'A mentions the topic.', 'b': 'See Topic.'});
      expect(
          () => parseNewTexts(
              '$newTexts=== ID: c ===\nC changed.\n=== end ===\n', plan),
          throwsA(isA<NeighbourhoodError>().having(
              (e) => e.message, 'message', contains('not in the plan'))));
      expect(() => parseNewTexts('$newTexts$newTexts', plan),
          throwsA(isA<NeighbourhoodError>()));
      expect(() => parseNewTexts('Done.', plan),
          throwsA(isA<NeighbourhoodError>()));
    });
  });

  group('the screen', () {
    late MemoryNoteStore store;
    late FakeServer server;
    late MemoryAgentLog log;
    String? result;

    Future<void> open(WidgetTester tester, List<Object> replies,
        {String id = 'topic'}) async {
      store = MemoryNoteStore(Map.of(notes));
      server = FakeServer(replies);
      log = MemoryAgentLog();
      result = null;
      final writer = NoteWriter(
        create: (name, text) async => Created(name),
        allowWriting: () async {},
        editor: editorOf(store),
      );
      await tester.pumpWidget(AiSettingsHost(
        store: MemoryAiSettingsStore(
            const AiSettings(hiddenTags: ['private'])),
        keys: MemoryKeyStore()..keys['anthropic'] = 'sk-test',
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                          builder: (_) => AiEditScreen(
                                writer: writer,
                                node: graph.nodes[id]!,
                                graph: graph,
                                post: server.post,
                                agentLog: log,
                              )));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> ask(WidgetTester tester) async {
      await tester.enterText(find.byKey(const ValueKey('ai-edit-instruction')),
          'Remove all links to this note');
      await tester.tap(find.byKey(const ValueKey('ai-edit-ask')));
      await tester.pumpAndSettle();
    }

    Future<void> tapVisible(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    Future<void> goAhead(WidgetTester tester) async {
      await tapVisible(tester, const ValueKey('ai-edit-go'));
      await tester.pumpAndSettle();
    }

    Future<void> saveAll(WidgetTester tester) async {
      await tester.tap(find.text('Accept all'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('change-save')));
      await tester.pumpAndSettle();
    }

    testWidgets('a note without linked notes has no choice', (tester) async {
      await open(tester, [], id: 'other');
      expect(find.byKey(const ValueKey('ai-edit-linked')), findsNothing);
    });

    testWidgets('plan, go ahead, review: saved only after "Save", logged, '
        'and undone as one', (tester) async {
      await open(tester, [
        textReply(planReply(['a', 'b'])),
        textReply(newTexts),
      ]);
      await ask(tester);
      // The plan: nothing is changed yet, and only one question was sent,
      // without what is hidden.
      expect(find.byKey(const ValueKey('ai-edit-plan')), findsOneWidget);
      expect(find.text('Remove the links.'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B heading'), findsOneWidget);
      expect(server.requests, hasLength(1));
      final sent = jsonEncode(server.requests.single.body);
      expect(sent, isNot(contains('Hidden words')));
      expect(sent, isNot(contains('About')));
      expect(server.requests.single.body['tools'], isEmpty);
      expect(store.files, notes);

      await goAhead(tester);
      expect(find.text('AI change set'), findsOneWidget);
      expect(find.text('The AI: Remove the links.'), findsOneWidget);
      // Nothing saved before "Save".
      expect(store.files, notes);

      await saveAll(tester);
      expect(store.files['a.org'],
          notes['a.org']!.replaceFirst('[[id:topic][the topic]]', 'the topic'));
      expect(store.files['b.org'],
          notes['b.org']!.replaceFirst('[[id:topic][Topic]]', 'Topic'));
      expect(store.files['topic.org'], notes['topic.org']);
      // In "Recent AI changes" as one message.
      final messages = recentMessages(log.entries);
      expect(messages, hasLength(1));
      expect(messages.single.changes.files, ['a.org', 'b.org']);
      expect(messages.single.changes.prompt, 'Remove all links to this note');
      expect(messages.single.undoable, isTrue);

      await tester.tap(find.byKey(const ValueKey('change-undo')));
      await tester.pumpAndSettle();
      expect(store.files, notes);
      expect(recentMessages(log.entries).single.undone, isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(result, 'The change set was undone.');
    });

    testWidgets('"Back" from the plan keeps the instruction', (tester) async {
      await open(tester, [textReply(planReply(['a']))]);
      await ask(tester);
      await tapVisible(tester, const ValueKey('ai-edit-back'));
      expect(find.byKey(const ValueKey('ai-edit-plan')), findsNothing);
      expect(find.text('Remove all links to this note'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-edit-ask')), findsOneWidget);
      expect(server.requests, hasLength(1));
      expect(store.files, notes);
    });

    testWidgets('a plan with a note outside the scope is refused',
        (tester) async {
      await open(tester, [textReply(planReply(['a', 'other']))]);
      await ask(tester);
      expect(find.byKey(const ValueKey('ai-edit-plan')), findsNothing);
      expect(find.textContaining('not one of the notes sent'), findsOneWidget);
    });

    testWidgets('a change to a note not in the plan is refused',
        (tester) async {
      await open(tester, [
        textReply(planReply(['a'])),
        textReply(newTexts),
      ]);
      await ask(tester);
      await goAhead(tester);
      expect(find.text('AI change set'), findsNothing);
      expect(find.textContaining('which is not in the plan'), findsOneWidget);
      expect(store.files, notes);
    });

    testWidgets('a dropped hidden heading changes nothing', (tester) async {
      await open(tester, [
        textReply(planReply(['topic'])),
        textReply('=== ID: topic ===\nTopic links to [[id:c][C]].\n'
            '=== end ===\n'),
      ]);
      await ask(tester);
      await goAhead(tester);
      expect(find.textContaining('dropped or moved a part hidden'),
          findsOneWidget);
      expect(store.files, notes);
    });

    testWidgets('a hidden heading comes back unchanged', (tester) async {
      await open(tester, [
        textReply(planReply(['topic'])),
        textReply('=== ID: topic ===\nTopic links to C.\n'
            '* Part\n:PROPERTIES:\n:ID: part\n:END:\nAlso [[id:d2][D two]].\n'
            '* (hidden)\n=== end ===\n'),
      ]);
      await ask(tester);
      await goAhead(tester);
      await saveAll(tester);
      expect(store.files['topic.org'],
          notes['topic.org']!.replaceFirst('[[id:c][C]]', 'C'));
      expect(store.files['topic.org'], contains('Hidden words.'));
    });

    testWidgets('a file changed meanwhile: no note of the set is saved',
        (tester) async {
      await open(tester, [
        textReply(planReply(['a', 'b'])),
        textReply(newTexts),
      ]);
      await ask(tester);
      await goAhead(tester);
      store.files['b.org'] = '${notes['b.org']!}Written on the laptop.\n';
      await saveAll(tester);
      expect(store.files['a.org'], notes['a.org']);
      expect(store.files['b.org'], endsWith('Written on the laptop.\n'));
      expect(find.byKey(const ValueKey('change-undo')), findsNothing);
      expect(log.entries, isEmpty);
    });

    testWidgets('a file that cannot be saved: the others are put back',
        (tester) async {
      await open(tester, [
        textReply(planReply(['a', 'topic'])),
        // The second file changes a heading's :ID:, which stays as it is.
        textReply('=== ID: a ===\nA mentions the topic.\n=== end ===\n'
            '=== ID: topic ===\nTopic links to [[id:c][C]].\n'
            '* Part\n:PROPERTIES:\n:ID: other-part\n:END:\n'
            'Also [[id:d2][D two]].\n* (hidden)\n=== end ===\n'),
      ]);
      await ask(tester);
      await goAhead(tester);
      await saveAll(tester);
      expect(store.files, notes);
      expect(find.textContaining('Saved, then put back'), findsOneWidget);
      expect(find.byKey(const ValueKey('change-undo')), findsNothing);
      expect(log.entries, isEmpty);
    });
  });
}
