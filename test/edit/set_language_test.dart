import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/set_language.dart';
import 'package:roam_graph_mobile/search/search_screen.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'delete_fixtures.dart';
import 'hand_delete_test.dart' show showPage;

/// The synthetic notes of hand delete, one of them with a language.
final languageNotes = {
  ...deleteNotes,
  'b.org': deleteNotes['b.org']!
      .replaceFirst('#+title: Beta\n', '#+title: Beta\n#+language: en\n'),
};

void main() {
  test('adds the keyword in one note, replaces it in the other; one undo '
      'restores both', () async {
    final f = DeleteFixture(languageNotes);
    final report = await setNotesLanguage(
      editor: f.editor,
      log: f.log,
      graph: f.graph.value,
      nodes: [f.graph.value.nodes['a']!, f.graph.value.nodes['b']!],
      code: 'de',
    );
    expect(report.failures, isEmpty);
    expect(f.store.files['a.org'],
        startsWith(':PROPERTIES:\n:ID: a\n:END:\n#+title: Alpha\n'
            '#+language: de\nSee [[id:b][Beta]].\n'));
    expect(f.store.files['b.org'], contains('#+title: Beta\n#+language: de\n'));
    expect(f.store.files['b.org'], isNot(contains('#+language: en')));
    expect(report.changes.files, ['a.org', 'b.org']);
    final entries = await f.log.read();
    expect({for (final e in entries) e.messageId}, hasLength(1));
    await undoAndLog(report.changes, f.editor, f.log);
    expect(f.store.files, languageNotes);
  });

  test('a heading node sets its file\'s keyword, once per file', () async {
    final f = DeleteFixture(languageNotes);
    final nodes = f.graph.value.nodes;
    final report = await setNotesLanguage(
      editor: f.editor,
      log: f.log,
      graph: f.graph.value,
      nodes: [nodes['h']!, nodes['c']!, nodes['a']!],
      code: 'fr',
    );
    expect(report.changes.files, ['a.org']);
    expect(f.store.files['a.org'],
        contains('#+title: Alpha\n#+language: fr\n'));
    expect(RegExp('#\\+language').allMatches(f.store.files['a.org']!),
        hasLength(1));
    // Already so: nothing written.
    final again = await setNotesLanguage(
        editor: f.editor,
        log: f.log,
        graph: f.graph.value,
        nodes: [f.graph.value.nodes['a']!],
        code: 'fr');
    expect(again.changes.isEmpty, isTrue);
    expect(again.unchanged, ['Alpha']);
  });

  test('the message names a count only when files were changed (review of '
      '#176)', () async {
    final f = DeleteFixture(languageNotes);
    final nodes = f.graph.value.nodes;
    Future<LanguageReport> set(List<String> ids, String code) =>
        setNotesLanguage(
            editor: f.editor,
            log: f.log,
            graph: f.graph.value,
            nodes: [for (final id in ids) nodes[id]!],
            code: code);
    expect(languageMessage(await set(['a'], 'de')),
        'Set #+language: de in 1 note.');
    expect(languageMessage(await set(['a', 'b'], 'en')),
        'Set #+language: en in 1 note.\nAlready so: Beta.');
    expect(languageMessage(await set(['a', 'b'], 'en')),
        'Already so: Alpha, Beta.');
    f.store.files.remove('l.org');
    expect(languageMessage(await set(['l'], 'en')),
        'Linking: the file cannot be read as text.');
    expect(languageMessage(await set(['a', 'b'], 'fr')),
        'Set #+language: fr in 2 notes.');
  });

  testWidgets('"Set language…" next to "Delete…" in the search selection',
      (tester) async {
    final f = DeleteFixture(languageNotes);
    await showPage(
      tester,
      SearchScreen(
        graph: f.graph,
        readNote: (path) async => f.store.files[path],
        writer: f.writer,
        nodeMemory: MemoryNodeMemory(),
      ),
    );
    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete…'), findsOneWidget);
    await tester.tap(find.byTooltip('Set language…'));
    await tester.pumpAndSettle();
    expect(find.text('Set the language of 2 notes'), findsOneWidget);
    expect(find.byKey(const ValueKey('language-heading-files')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('language-de')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(f.store.files['a.org'], contains('#+language: de\n'));
    expect(f.store.files['b.org'], contains('#+language: de\n'));
    expect(find.text('Set #+language: de in 2 notes.'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(f.store.files, languageNotes);
    expect(find.byTooltip('Set language…'), findsNothing);
  });

  testWidgets('a heading in the selection: a line names its file',
      (tester) async {
    final f = DeleteFixture(languageNotes);
    await showPage(
      tester,
      SearchScreen(
        graph: f.graph,
        readNote: (path) async => f.store.files[path],
        writer: f.writer,
        nodeMemory: MemoryNodeMemory(),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Branch');
    await tester.pumpAndSettle();
    await tester.longPress(find.descendant(
        of: find.byKey(const ValueKey('hits')), matching: find.text('Branch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Set language…'));
    await tester.pumpAndSettle();
    expect(find.text('A heading has no language of its own, so the language '
        'is set for its file: a.org.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('language-code')), 'it');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(f.store.files['a.org'], contains('#+title: Alpha\n#+language: it\n'));
  });
}
