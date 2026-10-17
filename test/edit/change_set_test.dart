import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/change_set.dart';
import 'package:roam_graph_mobile/edit/edit_proposal.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

import 'note_editor_test.dart' show MemoryNoteStore;

String note(String id, String title) =>
    ':PROPERTIES:\n:ID: $id\n:END:\n#+title: $title\nText of $title.\n';

final files = {
  'a.org': note('a', 'Audio'),
  'b.org': note('b', 'ALSA'),
  'c.org': note('c', 'JACK'),
  'p.org': '${note('p', 'Private')}#+filetags: :private:\n',
};

RoamGraph graphOf(Map<String, String> texts) => RoamGraph.fromFiles([
      for (final MapEntry(:key, :value) in texts.entries)
        parseRoamFile(key, value),
    ]);

EditProposal see(String id, String other) => EditProposal(
    nodeId: id, mode: EditMode.append, text: 'See [[id:$other][$other]].');

void main() {
  late MemoryNoteStore store;
  late NoteEditor editor;
  final graph = graphOf(files);
  final visible = graphOf(Map.of(files)..remove('p.org'));

  setUp(() {
    store = MemoryNoteStore(Map.of(files));
    editor = NoteEditor(store: store, history: MemoryEditHistory());
  });

  Future<ChangeSet> build(List<EditProposal> proposals, {int max = 20}) =>
      ChangeSet.build(proposals,
          editor: editor, visible: visible, graph: graph, maxFiles: max);

  test('three files: two accepted are saved, one rejected is not', () async {
    final set = await build([see('a', 'b'), see('b', 'c'), see('c', 'a')]);
    expect(set.entries.map((e) => e.linksAdded), [1, 1, 1]);
    set.entries[0].state = EntryState.accepted;
    set.entries[1].state = EntryState.accepted;
    set.entries[2].state = EntryState.rejected;
    await set.save(editor);

    expect(store.files['a.org'], endsWith('See [[id:b][b]].\n'));
    expect(store.files['b.org'], endsWith('See [[id:c][c]].\n'));
    expect(store.files['c.org'], files['c.org']);
    expect([for (final e in set.entries) e.state],
        [EntryState.saved, EntryState.saved, EntryState.rejected]);
  });

  test('a file changed between proposal and save is refused alone',
      () async {
    final set = await build([see('a', 'b'), see('b', 'c')]);
    for (final e in set.entries) {
      e.state = EntryState.accepted;
    }
    store.files['b.org'] = '${files['b.org']}From the laptop.\n';
    await set.save(editor);

    expect(set.entries[0].state, EntryState.saved);
    expect(set.entries[1].state, EntryState.refused);
    expect(set.entries[1].problem, contains('Changed'));
    expect(store.files['b.org'], endsWith('From the laptop.\n'));
  });

  test('undo restores every saved file, unless it changed since', () async {
    final set = await build([see('a', 'b'), see('b', 'c'), see('c', 'a')]);
    for (final e in set.entries) {
      e.state = EntryState.accepted;
    }
    await set.save(editor);
    store.files['c.org'] = '${store.files['c.org']}Later.\n';
    final problems = await set.undo(editor);

    expect(store.files['a.org'], files['a.org']);
    expect(store.files['b.org'], files['b.org']);
    expect(problems.keys, ['c.org']);
    expect(store.files['c.org'], endsWith('Later.\n'));
    expect([for (final e in set.entries) e.state],
        [EntryState.undone, EntryState.undone, EntryState.saved]);
  });

  test('an unknown id: is flagged', () async {
    final set = await build([see('a', 'nope')]);
    expect(set.entries.single.unknownIds, ['nope']);
  });

  test('a hidden note, two edits of one file, and too many files are '
      'refused', () async {
    await expectLater(build([see('p', 'a')]), throwsA(isA<ChangeSetError>()));
    await expectLater(build([see('a', 'b'), see('a', 'c')]),
        throwsA(isA<ChangeSetError>()));
    await expectLater(build([see('a', 'b'), see('b', 'c')], max: 1),
        throwsA(isA<ChangeSetError>()));
    expect(store.writes, 0);
  });

  test('an entry edited before accepting saves the edited text', () async {
    final set = await build([see('a', 'b')]);
    set.editEntry(set.entries.single, 'See [[id:c][JACK]].', graph);
    set.entries.single.state = EntryState.accepted;
    await set.save(editor);
    expect(store.files['a.org'], endsWith('See [[id:c][JACK]].\n'));
    expect(contentHash(utf8.encode(store.files['a.org']!)),
        set.entries.single.savedHash);
  });
}
