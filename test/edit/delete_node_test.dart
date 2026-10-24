import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/delete_node.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';

import 'delete_fixtures.dart';

void main() {
  late DeleteFixture f;
  setUp(() => f = DeleteFixture());
  tearDown(() => f.graph.dispose());

  test(
    'file, child nodes and two sets of backlinks are removed as one step',
    () async {
      final plan = await f.prepare(['a']);
      expect(plan.gone, {'a', 'h', 'c'});
      expect(plan.linkingNotes, 2);
      final report = await f.deleter.apply(plan);
      expect(report.failures, isEmpty);
      expect(f.store.files.containsKey('a.org'), isFalse);
      expect(f.store.files['b.org'], contains('See Alpha and Branch.'));
      expect(f.store.files['l.org'], contains('Alpha, Child, [[id:b][Beta]].'));
      final messages = recentMessages(await f.log.read());
      expect(messages, hasLength(1));
      expect(messages.single.changes.files, hasLength(3));
      await undoAndLog(
        messages.single.changes,
        f.editor,
        f.log,
        create: f.writer.create,
      );
      expect(f.store.files, deleteNotes);
      expect(recentMessages(await f.log.read()).single.undone, isTrue);
    },
  );

  test('hand delete converts bracket, angle and plain Org links', () async {
    f.store.files['b.org'] = '${deleteNotes['b.org']}<id:a> and id:a.\n';
    f.store.notify?.call();
    await f.deleter.apply(await f.prepare(['a']));
    expect(f.store.files['b.org'], endsWith('a and a.\n'));
    await f.changes.undoAll(f.editor, create: f.writer.create);
    expect(f.store.files['b.org'], '${deleteNotes['b.org']}<id:a> and id:a.\n');
  });

  test('Leave the links leaves all other files byte for byte', () async {
    await f.deleter.apply(await f.prepare(['a']), turnLinksIntoText: false);
    expect(f.store.files, {
      'b.org': deleteNotes['b.org'],
      'l.org': deleteNotes['l.org'],
    });
    await f.changes.undoAll(f.editor, create: f.writer.create);
    expect(f.store.files, deleteNotes);
  });

  test(
    'heading subtree removal preserves the rest of a CRLF file exactly',
    () async {
      f.store.files.updateAll((_, text) => text.replaceAll('\n', '\r\n'));
      final original = Map.of(f.store.files);
      final before = original['a.org']!;
      final expected =
          before.substring(0, before.indexOf('* Branch')) +
          before.substring(before.indexOf('* Keep'));
      await f.deleter.apply(await f.prepare(['h']));
      expect(f.store.files['a.org'], expected);
      expect(
        f.store.files['b.org'],
        contains('[[id:a][Alpha]] and Branch.\r\n'),
      );
      expect(f.store.files['l.org'], contains('[[id:a][Alpha]], Child,'));
      await f.changes.undoAll(f.editor, create: f.writer.create);
      expect(f.store.files, original);
    },
  );

  test('undo leaves a newer linking note intact and identifies it', () async {
    await f.deleter.apply(await f.prepare(['a']));
    final outside = '${f.store.files['b.org']}From the laptop.\n';
    f.store.files['b.org'] = outside;
    final result = await f.changes.undoAll(f.editor, create: f.writer.create);
    expect(result['b.org'], UndoOutcome.changedSince);
    expect(f.changes.first('b.org').title, 'Beta');
    expect(f.store.files['b.org'], outside);
    expect(f.store.files['a.org'], deleteNotes['a.org']);
    expect(f.store.files['l.org'], deleteNotes['l.org']);
  });

  test('undo never replaces a file recreated since deletion', () async {
    await f.deleter.apply(await f.prepare(['a']));
    f.store.files['a.org'] = 'New file with the same name.\n';
    final result = await f.changes.undoAll(f.editor, create: f.writer.create);
    expect(result['a.org'], UndoOutcome.changedSince);
    expect(f.store.files['a.org'], 'New file with the same name.\n');
  });

  test(
    'subfolder file and heading nodes are refused with their path',
    () async {
      final nested = DeleteFixture({'sub/a.org': deleteNotes['a.org']!});
      addTearDown(nested.graph.dispose);
      for (final id in ['a', 'h']) {
        await expectLater(
          nested.prepare([id]),
          throwsA(
            isA<DeleteError>().having(
              (e) => e.message,
              'message',
              contains('sub/a.org is in a subfolder'),
            ),
          ),
        );
      }
      expect(nested.store.writes, 0);
    },
  );

  test('a target changed while confirmation was open is not deleted', () async {
    final plan = await f.prepare(['a']);
    f.store.files['a.org'] = '${deleteNotes['a.org']}Outside.\n';
    final report = await f.deleter.apply(plan);
    expect(report.deleted, isEmpty);
    expect(report.failures.single, contains('changed since it was read'));
    expect(f.store.files['b.org'], deleteNotes['b.org']);
    expect(f.store.files['a.org'], endsWith('Outside.\n'));
    expect(f.changes.isEmpty, isTrue);
    expect(await f.editor.versions('a.org'), isEmpty);
  });

  test(
    'hash checks protect file deletion, subtree saves and undo saves',
    () async {
      f.store.raceOn = 'a.org';
      final report = await f.deleter.apply(await f.prepare(['a']));
      expect(report.deleted, isEmpty);
      expect(f.store.files['a.org'], endsWith('Outside.\n'));
      f.store.raceOn = 'a.org';
      expect((await f.deleter.apply(await f.prepare(['h']))).deleted, isEmpty);
      expect(f.graph.value.nodes, contains('h'));
      await f.deleter.apply(await f.prepare(['h']));
      f.store.raceOn = 'a.org';
      final undo = await f.changes.undoAll(f.editor, create: f.writer.create);
      expect(undo['a.org'], UndoOutcome.changedSince);
      expect(f.store.files['a.org'], endsWith('Outside.\n'));
    },
  );

  test(
    'two selected files skip mutual links and share one undo group',
    () async {
      final report = await f.deleter.apply(await f.prepare(['a', 'b']));
      expect(report.deleted.map((n) => n.id), ['a', 'b']);
      expect(f.changes.changes, hasLength(3));
      expect(f.store.files.keys, ['l.org']);
      expect(f.store.files['l.org'], contains('Alpha, Child, Beta.'));
      await f.changes.undoAll(f.editor, create: f.writer.create);
      expect(f.store.files, deleteNotes);
    },
  );

  test('overlapping file and heading selections remove a file once', () async {
    final plan = await f.prepare(['h', 'c', 'a']);
    expect(plan.files, hasLength(1));
    await f.deleter.apply(plan);
    expect(f.changes.changes.where((c) => c.deleted), hasLength(1));
    await f.changes.undoAll(f.editor, create: f.writer.create);
    expect(f.store.files, deleteNotes);
  });

  test('overlapping heading selections remove a subtree once', () async {
    final plan = await f.prepare(['h', 'c']);
    await f.deleter.apply(plan);
    await f.changes.undoAll(f.editor, create: f.writer.create);
    expect(f.store.files, deleteNotes);
  });

  test('hand deletion includes notes hidden from AI', () async {
    final hidden = DeleteFixture({
      'a.org': deleteNotes['a.org']!.replaceFirst(
        '#+title: Alpha',
        '#+title: Alpha\n#+filetags: :private:',
      ),
    });
    addTearDown(hidden.graph.dispose);
    expect(
      (await hidden.deleter.apply(await hidden.prepare(['a']))).deleted,
      hasLength(1),
    );
    expect(hidden.store.files, isEmpty);
  });

  test('a folder change while confirming refuses the deletion', () async {
    final plan = await f.prepare(['a']);
    f.store.folder = 'another';
    final report = await f.deleter.apply(plan);
    expect(report.failures.single, contains('another folder'));
    expect(f.store.writes, 0);
  });

  test('undo rechecks the folder after reading a deleted file name', () async {
    await f.deleter.apply(await f.prepare(['a']), turnLinksIntoText: false);
    f.store.afterRead = () => f.store.folder = 'another';
    final outcome = await f.changes.undoAll(f.editor, create: f.writer.create);
    expect(outcome['a.org'], UndoOutcome.otherFolder);
    expect(f.store.files.containsKey('a.org'), isFalse);
  });

  test('a subtree save cannot switch folders while keeping history', () async {
    final editor = NoteEditor(
      store: f.store,
      history: SwitchingHistory(() => f.store.folder = 'another'),
    );
    final deleter = NodeDeleter(
      editor: editor,
      record: (_, _, _, _, _) async {},
    );
    final plan = await deleter.prepare(f.graph.value, [
      f.graph.value.nodes['h']!,
    ]);
    expect((await deleter.apply(plan)).deleted, isEmpty);
    expect(f.store.writes, 0);
  });

  test(
    'folder changes while history is kept cannot redirect deletion',
    () async {
      final editor = NoteEditor(
        store: f.store,
        history: SwitchingHistory(() => f.store.folder = 'another'),
      );
      final deleter = NodeDeleter(
        editor: editor,
        record: (_, _, _, _, _) async {},
      );
      final plan = await deleter.prepare(f.graph.value, [
        f.graph.value.nodes['a']!,
      ]);
      expect((await deleter.apply(plan)).deleted, isEmpty);
      expect(f.store.writes, 0);
    },
  );
}

class SwitchingHistory extends MemoryEditHistory {
  SwitchingHistory(this.switchFolder);
  final void Function() switchFolder;
  @override
  Future<DateTime> keep(String key, String text, DateTime time) async {
    final at = await super.keep(key, text, time);
    switchFolder();
    return at;
  }
}
