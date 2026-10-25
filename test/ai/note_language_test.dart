import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/agent_tools.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart' show ToolError;
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/ai/edit_tools.dart';
import 'package:roam_graph_mobile/ai/note_from_answer.dart';
import 'package:roam_graph_mobile/ai/note_language.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/capture/new_node.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/change_set.dart';
import 'package:roam_graph_mobile/edit/edit_proposal.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

import '../edit/note_editor_test.dart' show MemoryNoteStore;
import 'ai_chat_test.dart' show FakeServer, anthropicReply;
import 'ai_visibility_test.dart' show graphOf;
import 'chat_screen_test.dart' show ask, openChat;

String note(String id, String title,
        {String? language, String body = '', String tags = ''}) =>
    ':PROPERTIES:\n:ID: $id\n:END:\n#+title: $title\n'
    '${language == null ? '' : '#+language: $language\n'}'
    '${tags.isEmpty ? '' : '#+filetags: $tags\n'}$body';

/// Synthetic notes: a German start note with neighbours, a start note
/// without a language whose neighbours are mostly German, and one whose
/// neighbours have no majority.
final languageNotes = {
  'pilz.org': note('pilz', 'Pilzsuche',
      language: 'de',
      body: 'Siehe [[id:stein][Steinpilz]] und [[id:pfiff][Pfifferling]].\n'
          '* Saison\n:PROPERTIES:\n:ID: saison\n:END:\nHerbst.\n'),
  'stein.org': note('stein', 'Steinpilz',
      body: 'Zurück zu [[id:pilz][Pilzsuche]].\n'),
  'pfiff.org': note('pfiff', 'Pfifferling',
      language: 'en', body: 'Gelb.\n'),
  'hub.org': note('hub', 'Hub',
      body: '[[id:d1][D1]] [[id:d2][D2]] [[id:e1][E1]] [[id:none][None]]\n'),
  'd1.org': note('d1', 'D1', language: 'de'),
  'd2.org': note('d2', 'D2', language: 'de'),
  'd3.org': note('d3', 'D3', language: 'de', body: '[[id:hub][Hub]]\n'),
  'e1.org': note('e1', 'E1', language: 'en'),
  'none.org': note('none', 'None'),
  'split.org': note('split', 'Split', body: '[[id:d1][D1]] [[id:e1][E1]]\n'),
  'lone.org': note('lone', 'Lone', body: '[[id:d1][D1]]\n'),
  'secret.org': note('secret', 'Secret',
      language: 'fr', tags: ':private:', body: '[[id:lone][Lone]]\n'),
};

void main() {
  final graph = graphOf(languageNotes);
  Future<String?> read(String path) async => languageNotes[path];
  Future<NoteLanguage> decide(String? id,
          {RoamGraph? on, String fallback = 'en'}) =>
      decideLanguage(on ?? graph, id == null ? null : graph.nodes[id],
          read: read, fallback: fallback);

  group('reading and writing #+language:', () {
    test('the first line counts; case and region as org has them', () {
      expect(languageOf(languageNotes['pilz.org']!), 'de');
      expect(languageOf(languageNotes['stein.org']!), isNull);
      expect(languageOf('#+LANGUAGE: PT-BR\n#+language: en\n'), 'pt-BR');
      expect(languageOf('#+language: Deutsch\n'), isNull);
      expect(languageCode(' de '), 'de');
      expect(languageCode('german'), isNull);
    });

    test('added after #+title:, replaced where it is, line endings kept',
        () {
      expect(withLanguage(note('a', 'A', tags: ':x:', body: 'Text.\n'), 'de'),
          note('a', 'A', language: 'de', tags: ':x:', body: 'Text.\n'));
      expect(withLanguage(note('a', 'A', language: 'en', body: 'T.\n'), 'de'),
          note('a', 'A', language: 'de', body: 'T.\n'));
      expect(withLanguage(':PROPERTIES:\r\n:ID: a\r\n:END:\r\n#+title: A\r\n'
              'Text.\r\n', 'fr'),
          ':PROPERTIES:\r\n:ID: a\r\n:END:\r\n#+title: A\r\n#+language: fr\r\n'
          'Text.\r\n');
      expect(withLanguage(':PROPERTIES:\n:ID: a\n:END:\nText.\n', 'de'),
          ':PROPERTIES:\n:ID: a\n:END:\n#+language: de\nText.\n');
    });

    test('a new node gets #+language: right after #+title: only when '
        'asked', () {
      expect(nodeFileText(id: 'x', title: 'T', tags: ['a'], language: 'de'),
          ':PROPERTIES:\n:ID:       x\n:END:\n#+title: T\n#+language: de\n'
          '#+filetags: :a:\n');
      expect(nodeFileText(id: 'x', title: 'T'), isNot(contains('#+language')));
    });

    test('an edit that adds or changes #+language: is told apart', () {
      expect(sameLanguageLines('a\n#+language: de\n', '#+language: de\nb\n'),
          isTrue);
      expect(sameLanguageLines('a\n', 'a\n#+language: de\n'), isFalse);
      expect(sameLanguageLines('#+language: de\n', '#+language: en\n'),
          isFalse);
    });
  });

  group('the rules of #172', () {
    test('rule 2: the note it starts from is German', () async {
      final language = await decide('pilz');
      expect((language.code, language.rule), ('de', 2));
      // A heading node takes its file's language.
      expect((await decide('saison')).code, 'de');
    });

    test('rule 3: 3 German and 1 English neighbour give German', () async {
      final language = await decide('hub');
      expect((language.code, language.rule), ('de', 3));
    });

    test('rule 3 without a majority, or with one marked neighbour, falls '
        'through to rule 4', () async {
      final split = await decide('split', fallback: 'fr');
      expect((split.code, split.rule), ('fr', 4));
      expect((await decide('lone', fallback: 'it')).code, 'it');
    });

    test('rule 3 reads the neighbour files at once, each once', () async {
      var open = 0, most = 0;
      final reads = <String>[];
      final language = await decideLanguage(graph, graph.nodes['hub'],
          read: (path) async {
            reads.add(path);
            most = max(most, ++open);
            await Future<void>.delayed(Duration.zero);
            open--;
            return languageNotes[path];
          },
          fallback: 'en');
      expect(language.code, 'de');
      expect(most, greaterThan(1));
      expect(reads, unorderedEquals(
          ['hub.org', 'd1.org', 'd2.org', 'd3.org', 'e1.org', 'none.org']));
    });

    test('rule 4: without a note to start from, the default', () async {
      final language = await decide(null, fallback: 'nl');
      expect((language.code, language.rule), ('nl', 4));
    });

    test('notes hidden from AI do not count', () async {
      const private = AiVisibility({'private'});
      final visible = private.visibleGraph(graph);
      // Lone's backlink from the French Secret is hidden: 1 marked.
      final lone = await decideLanguage(visible, visible.nodes['lone'],
          read: read, fallback: 'en');
      expect((lone.code, lone.rule), ('en', 4));
    });

    test('the prompt names the language for notes linked from the start '
        'note', () async {
      final prompt = languagePrompt(await decide('pilz'));
      expect(prompt, contains('Write new notes linked from "Pilzsuche" in '
          'German (de)'));
      expect(prompt, contains('do not translate'));
      expect(languagePrompt(await decide(null)),
          startsWith('Write new notes in English (en).'));
    });

    test('"Save as node" asks for the decided language', () {
      expect(agentSaveRequest(answer: 'x', isLast: true,
              language: 'German (de)'),
          contains('written in German (de)'));
      expect(noteRequestInstruction(startLinked: false,
              language: 'German (de)'),
          contains('written in German (de)'));
    });
  });

  group('the agent (#172)', () {
    const private = AiVisibility({'private'});
    late MemoryNoteStore store;
    late AgentWriter agent;

    AgentWriter make(String language) => AgentWriter(
          writer: NoteWriter(
            create: (name, text) async {
              store.files[name] = text;
              return Created(name);
            },
            allowWriting: () async {},
            editor: NoteEditor(store: store, history: MemoryEditHistory()),
          ),
          visibleGraph: () => private.visibleGraph(graphOf(store.files)),
          hiddenIds: () => private.hiddenIds(graphOf(store.files)),
          visibility: private,
          folder: () => 'folder',
          limit: 30,
          log: MemoryAgentLog(),
          language: language,
          now: () => DateTime(2026, 10, 25, 12),
          random: Random(1),
        );

    setUp(() {
      store = MemoryNoteStore(Map.of(languageNotes));
      agent = make('de');
      agent.startMessage();
    });

    Future<String> call(String name, Map<String, Object?> input) =>
        agent.run(ToolCall('c', name, input));

    String created() => store.files.entries
        .firstWhere((e) => !languageNotes.containsKey(e.key))
        .value;

    test('create_node writes #+language: de after #+title:', () async {
      await call('create_node', {'title': 'Morchel', 'text': 'Im Frühling.'});
      expect(created(), contains('#+title: Morchel\n#+language: de\n'));
    });

    test('a language in the request goes in the language argument',
        () async {
      await call('create_node',
          {'title': 'Morel', 'text': 'In spring.', 'language': 'en'});
      expect(created(), contains('#+title: Morel\n#+language: en\n'));
      expect(await call('create_node', {'title': 'X', 'language': 'Deutsch'}),
          startsWith('Error: Deutsch is no language code'));
      expect(
          await call('create_node',
              {'title': 'X', 'text': '#+language: fr\nTexte.'}),
          startsWith('Error: a #+language: line goes in language'));
    });

    test('edits keep #+language: as it is', () async {
      expect(
          await call('edit_node_text',
              {'id': 'pfiff', 'old': 'Gelb.', 'new': 'Gelb und duftend.'}),
          'Changed the text of "Pfifferling".');
      expect(store.files['pfiff.org'], contains('#+language: en\n'));
      expect(
          await call('append_to_node',
              {'id': 'stein', 'text': '#+language: de'}),
          startsWith('Error: a #+language: line cannot be added'));
      expect(
          await call('edit_node_text',
              {'id': 'stein', 'old': 'Zurück', 'new': '#+language: de\nZurück'}),
          startsWith('Error: #+language: lines stay as they are'));
      await call('rename_node', {'id': 'pfiff', 'title': 'Eierschwamm'});
      expect(store.files['pfiff.org'],
          contains('#+title: Eierschwamm\n#+language: en\n'));
      expect(store.files['stein.org'], languageNotes['stein.org']);
    });

    test('"Set the language German for all notes under Pilzsuche": '
        'set_language, one undo', () async {
      final log = <String>[
        for (final id in ['saison', 'stein', 'pfiff'])
          await call('set_language', {'id': id, 'language': 'de'}),
      ];
      expect(log, [
        'Nothing changed: the text is already so.',
        'Set the language of "Steinpilz" to de.',
        'Set the language of "Pfifferling" to de.',
      ]);
      expect(store.files['stein.org'],
          contains('#+title: Steinpilz\n#+language: de\n'));
      expect(store.files['pfiff.org'], contains('#+language: de\n'));
      expect(store.files['pfiff.org'], isNot(contains('#+language: en')));
      expect(await call('set_language', {'id': 'secret', 'language': 'de'}),
          startsWith('Error: There is no note with the ID secret'));
      await agent.changes.undoAll(agent.writer.editor!);
      expect(store.files, languageNotes);
    });
  });

  group('review mode keeps #+language: (review of #176)', () {
    // A #+language: line below the text is part of the body.
    final texts = {
      'body.org': note('body', 'Body',
          body: 'Text.\n#+language: de\nMore.\n'),
      'plain.org': note('plain', 'Plain', body: 'Text.\n'),
    };
    final graph = graphOf(texts);

    test('a replaced text may keep its #+language: line; an appended one '
        'may not hold one', () {
      final kept = proposalFrom({
        'node_id': 'body',
        'mode': 'replace',
        'text': 'New text.\n#+language: de\nMore.\n',
      }, graph);
      expect(kept.mode, EditMode.replace);
      expect(
          () => proposalFrom({
                'node_id': 'plain',
                'mode': 'append',
                'text': '#+language: de',
              }, graph),
          throwsA(isA<ToolError>()));
    });

    test('a change set refuses a replace that changes or adds the line, '
        'and takes one that keeps it', () async {
      final editor = NoteEditor(
          store: MemoryNoteStore(Map.of(texts)), history: MemoryEditHistory());
      Future<ChangeSet> build(String id, String text) => ChangeSet.build(
          [EditProposal(nodeId: id, mode: EditMode.replace, text: text)],
          editor: editor, visible: graph, graph: graph, maxFiles: 20);
      final set = await build('body', 'New text.\n#+language: de\nMore.\n');
      expect(set.entries.single.after, contains('New text.\n#+language: de'));
      await expectLater(build('body', 'New text.\n#+language: en\n'),
          throwsA(isA<ChangeSetError>()));
      await expectLater(build('plain', '#+language: de\nText.\n'),
          throwsA(isA<ChangeSetError>()));
    });
  });

  group('the chat (#172)', () {
    testWidgets('the system prompt names the language; create_node writes '
        'it', (tester) async {
      final server = FakeServer([
        anthropicReply([
          {
            'type': 'tool_use',
            'id': 'a1',
            'name': 'create_node',
            'input': {'title': 'Morchel', 'text': 'Im Frühling.'},
          },
        ], stop: 'tool_use'),
        anthropicReply([
          {'type': 'text', 'text': 'Fertig.'},
        ]),
      ]);
      final store = MemoryNoteStore(Map.of(languageNotes));
      final writer = NoteWriter(
        create: (name, text) async {
          store.files[name] = text;
          return Created(name);
        },
        allowWriting: () async {},
        editor: NoteEditor(store: store, history: MemoryEditHistory()),
      );
      await openChat(tester, server,
          writer: writer,
          startNode: graph.nodes['pilz'],
          graphNotifier: ValueNotifier(graph),
          readNote: (path) async => store.files[path]);
      await ask(tester, 'Schreib eine Notiz über Morcheln.');
      expect(jsonEncode(server.requests.first.body['system']),
          contains('Write new notes linked from \\"Pilzsuche\\" in German '
              '(de)'));
      final made = store.files.entries
          .firstWhere((e) => !languageNotes.containsKey(e.key))
          .value;
      expect(made, contains('#+title: Morchel\n#+language: de\n'));
    });

    testWidgets('"Save as node" in off mode writes #+language:',
        (tester) async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Steinpilze wachsen im Herbst.'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': '{"title": "Steinpilzzeit", "body": '
              '"Im Herbst."}'},
        ]),
      ]);
      final written = <String>[];
      await openChat(tester, server,
          writer: NoteWriter(
            create: (name, text) async {
              written.add(text);
              return Created(name);
            },
            allowWriting: () async {},
          ),
          startNode: graph.nodes['hub'],
          graphNotifier: ValueNotifier(graph),
          readNote: read);
      await ask(tester, 'Wann wachsen Steinpilze?');
      await tester.tap(find.text('Save as new node'));
      await tester.pumpAndSettle();
      expect(jsonEncode(server.requests.last.body['messages']),
          contains('written in German (de)'));
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(written.single,
          contains('#+title: Steinpilzzeit\n#+language: de\n'));
    });

    testWidgets('without a start note, "Language of new notes" decides',
        (tester) async {
      final server = FakeServer([
        anthropicReply([
          {'type': 'text', 'text': 'Oui.'},
        ]),
      ]);
      await openChat(tester, server,
          settings: const AiSettings(newNoteLanguage: 'fr'),
          graphNotifier: ValueNotifier(graph),
          readNote: read);
      await ask(tester, 'Bonjour.');
      expect(jsonEncode(server.requests.first.body['system']),
          contains('Write new notes in French (fr).'));
    });
  });
}
