import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/agent_tools.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';

import '../edit/note_editor_test.dart' show MemoryNoteStore;
import 'ai_visibility_test.dart' show graphOf, notes;

/// A store where the laptop changes [path] just before the next write.
class RacingStore extends MemoryNoteStore {
  RacingStore(super.files);

  String? raceOn;

  /// Runs once, and is awaited, just before the next write: another chat
  /// writes to the notes meanwhile (#201).
  Future<void> Function()? beforeReplace;

  @override
  Future<SaveResult> replace(
      String path, NoteVersion base, String text) async {
    if (beforeReplace case final hook?) {
      beforeReplace = null;
      await hook();
    }
    if (path == raceOn) {
      files[path] = '${files[path]}From the laptop.\n';
      raceOn = null;
    }
    return super.replace(path, base, text);
  }

  @override
  Future<SaveResult> delete(String path, NoteVersion base) {
    if (path == raceOn) {
      files[path] = '${files[path]}From the laptop.\n';
      raceOn = null;
    }
    return super.delete(path, base);
  }
}

/// The notes, and one with nothing hidden in it, to edit.
final start = {
  ...notes,
  'open.org': ':PROPERTIES:\n:ID: open\n:END:\n#+title: Open\n'
      'Some words. [[id:plan][Plan]] and [[id:plan][again]].\n',
  'tree.org': ':PROPERTIES:\n:ID: tree\n:END:\n#+title: Tree\nTop text.\n'
      '* Branch\n:PROPERTIES:\n:ID: branch\n:END:\nBranch text, see '
      '[[id:open][Open]].\n',
  'sub/deep.org': ':PROPERTIES:\n:ID: deep\n:END:\n#+title: Deep\n',
  'twin.org': ':PROPERTIES:\n:ID: twin\n:END:\n#+title: Twin\n'
      'See [[id:child][the child]].\n'
      '* Child\n:PROPERTIES:\n:ID: child\n:END:\nChild text.\n',
};

void main() {
  const private = AiVisibility({'private'});
  late RacingStore store;
  late AgentLog log;
  late AgentWriter agent;
  late NoteEditor editor;

  AgentWriter make({int limit = 30}) => AgentWriter(
        writer: NoteWriter(
          create: (name, text) async {
            if (store.files.containsKey(name)) return const FileExists();
            store.files[name] = text;
            return Created(name);
          },
          allowWriting: () async {},
          editor: editor,
        ),
        visibleGraph: () => private.visibleGraph(graphOf(store.files)),
        hiddenIds: () => private.hiddenIds(graphOf(store.files)),
        visibility: private,
        folder: () => 'content://tree/org',
        limit: limit,
        log: log,
        now: () => DateTime(2026, 10, 17, 12),
        random: Random(1),
      );

  setUp(() {
    store = RacingStore(Map.of(start));
    editor = NoteEditor(store: store, history: MemoryEditHistory());
    log = MemoryAgentLog();
    agent = make();
  });

  Future<String> call(String name, Map<String, Object?> input) =>
      agent.run(ToolCall('c', name, input));

  String idIn(String result) =>
      RegExp(r'with ID (\S+) ').firstMatch(result)!.group(1)!;

  test('two new notes linked to an existing one, without any confirmation',
      () async {
    agent.startMessage();
    final morel = idIn(await call('create_node', {
      'title': 'Morel',
      'text': 'A spring mushroom.',
      'tags': ['mushroom'],
    }));
    final chanterelle = idIn(await call('create_node', {
      'title': 'Chanterelle',
      'text': 'Found near [[id:plan][Plan]].',
    }));
    expect(await call('add_link', {'from_id': 'plan', 'to_id': morel}),
        'Linked "Plan" to "Morel".');
    expect(await call('add_link', {'from_id': 'plan', 'to_id': chanterelle}),
        'Linked "Plan" to "Chanterelle".');

    // Three files: two new, one changed; all in capture's format.
    final created = store.files.keys.where((k) => !start.containsKey(k));
    expect(created, hasLength(2));
    // Two notes in one second still get different file names.
    expect(created.toSet(), hasLength(2));
    final morelFile = store.files.entries
        .firstWhere((e) => e.value.contains('#+title: Morel'))
        .value;
    expect(morelFile, startsWith(':PROPERTIES:\n:ID:       $morel\n:END:\n'));
    expect(morelFile, contains('#+filetags: :mushroom:'));
    expect(store.files['plan.org'],
        '${notes['plan.org']}See also: [[id:$morel][Morel]], '
        '[[id:$chanterelle][Chanterelle]]\n');
    // The index sees the links.
    final graph = graphOf(store.files);
    expect(
        graph.links.where((l) => l.source == 'plan').map((l) => l.dest),
        containsAll([morel, chanterelle]));
    expect(agent.changes.summary, '2 notes created, 1 changed, 3 links added');
    expect((log as MemoryAgentLog).entries, hasLength(4));
    expect((log as MemoryAgentLog).entries.first.oldHash, isNull);

    // A link that is there already changes nothing.
    expect(await call('add_link', {'from_id': 'plan', 'to_id': morel}),
        contains('already'));
  });

  test('a file changed between read and write is refused, and reported',
      () async {
    store.raceOn = 'plan.org';
    final result = await call('append_to_node', {'id': 'plan', 'text': 'x'});
    expect(result, startsWith('Error: plan.org changed since it was read'));
    expect(store.files['plan.org'], endsWith('From the laptop.\n'));
    expect(store.files['plan.org'], isNot(contains('\nx\n')));
    expect(agent.changes.isEmpty, isTrue);
    // The model can try again, on the new version.
    expect(await call('append_to_node', {'id': 'plan', 'text': 'x'}),
        'Added the text to "Plan".');
    expect(store.files['plan.org'], endsWith('From the laptop.\nx\n'));
  });

  test('two chats changing the same note cannot overwrite each other (#201)',
      () async {
    // The agent of a second chat, on the same notes.
    final other = make();
    store.beforeReplace = () async {
      // The second chat writes while the first is between read and write.
      expect(
          await other.run(ToolCall('o', 'append_to_node',
              {'id': 'plan', 'text': 'From chat two.'})),
          'Added the text to "Plan".');
    };
    final result =
        await call('append_to_node', {'id': 'plan', 'text': 'From chat one.'});
    expect(result, startsWith('Error: plan.org changed since it was read'));
    // Nothing of the second chat is lost, nothing of the first is written.
    expect(store.files['plan.org'], endsWith('From chat two.\n'));
    expect(store.files['plan.org'], isNot(contains('From chat one.')));
    expect(agent.changes.isEmpty, isTrue);
    expect(other.changes.changes, hasLength(1));

    // The first chat reads again, and then both texts are there.
    expect(
        await call(
            'append_to_node', {'id': 'plan', 'text': 'From chat one.'}),
        'Added the text to "Plan".');
    expect(store.files['plan.org'],
        endsWith('From chat two.\nFrom chat one.\n'));
  });

  test('"Undo all" restores every file, unless it changed since', () async {
    final changes = agent.startMessage();
    final morel = idIn(await call('create_node', {'title': 'Morel'}));
    await call('add_link', {'from_id': 'plan', 'to_id': morel});
    expect(
        await call('edit_node_text',
            {'id': 'open', 'old': 'Some words.', 'new': 'Other words.'}),
        'Changed the text of "Open".');
    final created = changes.createdFiles.single;
    expect(await changes.undoAll(editor), {
      'open.org': UndoOutcome.restored,
      'plan.org': UndoOutcome.restored,
      created: UndoOutcome.deleted,
    });
    expect(store.files, start);

    // A file the laptop changed after the agent stays as it is.
    final again = agent.startMessage();
    await call('append_to_node', {'id': 'plan', 'text': 'Agent.'});
    store.files['plan.org'] = '${store.files['plan.org']}Laptop.\n';
    expect(await again.undoAll(editor), {'plan.org': UndoOutcome.changedSince});
    expect(store.files['plan.org'], endsWith('Agent.\nLaptop.\n'));
  });

  test('the limit of changes per message holds', () async {
    agent = make(limit: 2);
    agent.startMessage();
    await call('append_to_node', {'id': 'plan', 'text': 'one'});
    await call('append_to_node', {'id': 'plan', 'text': 'two'});
    expect(await call('append_to_node', {'id': 'plan', 'text': 'three'}),
        startsWith('Error: the limit of 2 changes'));
    expect(store.files['plan.org'], isNot(contains('three')));
    // A new message starts counting again.
    agent.startMessage();
    expect(await call('append_to_node', {'id': 'plan', 'text': 'three'}),
        'Added the text to "Plan".');
  });

  test('hidden notes cannot be changed or linked', () async {
    expect(await call('append_to_node', {'id': 'diary', 'text': 'x'}),
        'Error: There is no note with the ID diary that you may see.');
    expect(await call('add_link', {'from_id': 'plan', 'to_id': 'doctor'}),
        contains('no note with the ID doctor'));
    expect(
        await call('create_node',
            {'title': 'T', 'text': 'See [[id:diary][the diary]].'}),
        contains('no notes you may see: diary'));
    expect(await call('create_node', {'title': 'T', 'tags': ['private']}),
        contains('hides a note'));
    // Ideas has a hidden heading, Plan a link to a hidden note: their
    // text is not replaced, since the AI never saw all of it.
    expect(
        await call('edit_node_text',
            {'id': 'ideas', 'old': 'Open text.', 'new': 'Closed.'}),
        contains('parts hidden from you'));
    expect(
        await call('edit_node_text',
            {'id': 'plan', 'old': 'See ', 'new': 'Read '}),
        contains('parts hidden from you'));
    expect(store.files, start);
  });

  test('the property drawer and the head never change', () async {
    expect(
        await call('edit_node_text',
            {'id': 'open', 'old': ':ID: open', 'new': ':ID: other'}),
        contains('"old" is not in the note\'s text'));
    expect(
        await call('edit_node_text', {
          'id': 'open',
          'old': 'Some ',
          'new': ':PROPERTIES:\n:ID: x\n:END:\nSome ',
        }),
        contains('alter an :ID: or a property drawer'));
    expect(
        await call('edit_node_text',
            {'id': 'open', 'old': 'Some ', 'new': '#+title: Other\nSome '}),
        contains('#+title: and #+filetags: lines stay'));
    expect(
        await call('append_to_node', {'id': 'open', 'text': '#+filetags: :x:'}),
        contains('cannot be added'));
    expect(store.files, start);
  });

  test('edit_node_text needs text that occurs once', () async {
    expect(
        await call('edit_node_text',
            {'id': 'open', 'old': '[[id:plan]', 'new': '[[id:ideas]'}),
        contains('occurs 2 times'));
    expect(
        await call('edit_node_text',
            {'id': 'open', 'old': '[[id:plan][again]]', 'new': 'again'}),
        'Changed the text of "Open".');
    expect(store.files['open.org'], endsWith('[[id:plan][Plan]] and again.\n'));
  });

  test("a new note's text may not set title, tags or an :ID:", () async {
    expect(
        await call('create_node',
            {'title': 'T', 'text': '#+filetags: :private:\nText.'}),
        contains('#+title: and #+filetags: lines go in title and tags'));
    expect(
        await call('create_node', {
          'title': 'T',
          'text': '* H\n:PROPERTIES:\n:ID: plan\n:END:\n',
        }),
        contains('may not hold property drawers'));
    expect(store.files, start);
  });

  test('add_link puts the link in the node itself, not in a child node',
      () async {
    // Branch, a heading node below Tree, links to Open; Tree does not.
    expect(await call('add_link', {'from_id': 'tree', 'to_id': 'open'}),
        'Linked "Tree" to "Open".');
    expect(store.files['tree.org'],
        start['tree.org']!.replaceFirst('Top text.\n',
            'Top text.\nSee also: [[id:open][Open]]\n'));
    final graph = graphOf(store.files);
    expect(
        graph.links.where((l) => l.dest == 'open').map((l) => l.source),
        containsAll(['tree', 'branch']));
  });

  test('undo does not touch the note of the same path in another folder',
      () async {
    final changes = agent.startMessage();
    await call('append_to_node', {'id': 'plan', 'text': 'x'});
    final other = NoteEditor(
        store: OtherFolderStore(store.files), history: MemoryEditHistory());
    expect(await changes.undoAll(other), {'plan.org': UndoOutcome.otherFolder});
    expect(store.files['plan.org'], endsWith('\nx\n'));
    // Not a failure to retry: that note is not this change's.
    expect(changes.canUndo, isFalse);
  });

  test('delete_node: the note goes, links to it become text, undo (#93)',
      () async {
    final changes = agent.startMessage();
    expect(await call('delete_node', {'id': 'plan'}),
        'Deleted the note "Plan" (plan.org). Links to it in 1 note became '
        'their text: Open.');
    expect(store.files.containsKey('plan.org'), isFalse);
    expect(store.files['open.org'], contains('Some words. Plan and again.'));
    // A note hidden from AI keeps its link; it is not changed.
    expect(store.files['diary.org'], start['diary.org']);
    expect(changes.summary, '1 changed, 1 deleted');
    expect((log as MemoryAgentLog).entries.first.newHash, isNull);

    expect(await changes.undoAll(editor, create: agent.writer.create), {
      'plan.org': UndoOutcome.recreated,
      'open.org': UndoOutcome.restored,
    });
    expect(store.files, start);
  });

  test('delete_node: a heading node goes with its subtree', () async {
    final changes = agent.startMessage();
    expect(await call('delete_node', {'id': 'branch'}),
        'Deleted the heading "Branch" with its subtree.');
    expect(store.files['tree.org'],
        ':PROPERTIES:\n:ID: tree\n:END:\n#+title: Tree\nTop text.\n');
    expect(graphOf(store.files).nodes.containsKey('branch'), isFalse);
    await changes.undoAll(editor, create: agent.writer.create);
    expect(store.files, start);
  });

  test('delete_node: a link to a heading in its own file becomes text',
      () async {
    final changes = agent.startMessage();
    expect(await call('delete_node', {'id': 'child'}),
        'Deleted the heading "Child" with its subtree. Links to it in 1 note '
        'became their text: Twin.');
    expect(store.files['twin.org'],
        ':PROPERTIES:\n:ID: twin\n:END:\n#+title: Twin\nSee the child.\n');
    expect(await changes.undoAll(editor, create: agent.writer.create),
        {'twin.org': UndoOutcome.restored});
    expect(store.files, start);
  });

  test('a note with hidden parts in it cannot be deleted', () async {
    // Ideas has a heading tagged private.
    expect(await call('delete_node', {'id': 'ideas'}),
        contains('parts hidden from you'));
    expect(store.files, start);
  });

  test('delete_node refuses hidden notes, subfolders and changed files',
      () async {
    expect(await call('delete_node', {'id': 'diary'}),
        contains('no note with the ID diary'));
    expect(await call('delete_node', {'id': 'deep'}),
        contains('is in a subfolder'));
    store.raceOn = 'plan.org';
    expect(await call('delete_node', {'id': 'plan'}),
        contains('changed since it was read; nothing was deleted'));
    expect(store.files['plan.org'], endsWith('From the laptop.\n'));
    expect(agent.changes.isEmpty, isTrue);
  });

  group('Recent AI changes (#99)', () {
    final later = DateTime(2026, 10, 20);

    test('a message is undone from the log, after its chat is gone',
        () async {
      agent.startMessage(prompt: '  Tidy up   the\nnotes please ');
      final id = idIn(await call('create_node', {'title': 'New', 'text': 'x'}));
      await call('add_link', {'from_id': 'open', 'to_id': id});
      await call('delete_node', {'id': 'branch'});
      await call('delete_node', {'id': 'twin'});
      agent.startMessage(prompt: 'Second');
      await call('append_to_node', {'id': 'plan', 'text': 'Later.'});

      final messages = recentMessages(await log.read(), now: later);
      expect([for (final m in messages) m.changes.prompt],
          ['Second', 'Tidy up the notes please']);
      final first = messages.last;
      expect(first.undoable, isTrue);
      expect(first.changes.summary,
          '1 note created, 2 changed, 1 deleted, 1 link added');

      await undoAndLog(messages.first.changes, editor, log,
          create: agent.writer.create);
      final outcome = await undoAndLog(first.changes, editor, log,
          create: agent.writer.create);
      expect(outcome.values.toSet(), {
        UndoOutcome.deleted,
        UndoOutcome.restored,
        UndoOutcome.recreated,
      });
      expect(store.files, start);
      // Both are marked undone in the log.
      expect([
        for (final m in recentMessages(await log.read(), now: later)) m.undone
      ], [true, true]);
    });

    test('a note changed since stays, and is named in the outcome', () async {
      agent.startMessage(prompt: 'Add');
      await call('append_to_node', {'id': 'plan', 'text': 'Agent.'});
      await call('append_to_node', {'id': 'open', 'text': 'Agent.'});
      store.files['plan.org'] = '${store.files['plan.org']}Laptop.\n';
      final message = recentMessages(await log.read(), now: later).single;
      final outcome = await undoAndLog(message.changes, editor, log);
      expect(outcome['plan.org'], UndoOutcome.changedSince);
      expect(outcome['open.org'], UndoOutcome.restored);
      expect(store.files['plan.org'], endsWith('Agent.\nLaptop.\n'));
      expect(store.files['open.org'], start['open.org']);
    });

    test('old lines are shown without undo; old messages not at all', () {
      final old = AgentLogEntry.fromJson({
        'time': '2026-10-16T10:00:00Z',
        'folder': 'content://tree/org',
        'path': 'plan.org',
        'tool': 'append_to_node',
        'oldHash': 'a',
        'newHash': 'b',
      });
      final shown = recentMessages([old], now: later).single;
      expect(shown.undoable, isFalse);
      expect(shown.changes.files, ['plan.org']);
      expect(recentMessages([old], now: DateTime(2026, 11, 20)), isEmpty);
    });

    test('the file log keeps the newest 1000 lines', () async {
      final dir = Directory.systemTemp.createTempSync('agent-log');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = FileAgentLog(path: '${dir.path}/agent-changes.jsonl');
      for (var i = 0; i < FileAgentLog.keep + 5; i++) {
        await file.record(AgentLogEntry.undo('m$i', DateTime(2026)));
      }
      File('${dir.path}/agent-changes.jsonl')
          .writeAsStringSync('{"cut', mode: FileMode.append);
      final entries = await file.read();
      expect(entries, hasLength(FileAgentLog.keep - 1));
      expect(entries.first.messageId, 'm6');
      expect(
          File('${dir.path}/agent-changes.jsonl').readAsLinesSync(),
          hasLength(FileAgentLog.keep));
    });

    test('no line is lost when the log is trimmed while the agent writes',
        () async {
      final dir = Directory.systemTemp.createTempSync('agent-log');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = FileAgentLog(path: '${dir.path}/agent-changes.jsonl');
      for (var i = 0; i < FileAgentLog.keep + 5; i++) {
        await file.record(AgentLogEntry.undo('m$i', DateTime(2026)));
      }
      // Not awaited one by one: the read and the appends overlap.
      final reading = file.read();
      final writing = [
        for (var i = 0; i < 5; i++)
          file.record(AgentLogEntry.undo('new$i', DateTime(2026))),
      ];
      await Future.wait([reading, ...writing]);
      final lines =
          File('${dir.path}/agent-changes.jsonl').readAsLinesSync();
      for (var i = 0; i < 5; i++) {
        expect(lines.where((l) => l.contains('"new$i"')), hasLength(1));
      }
    });

    test('the file log is cut between messages', () async {
      final dir = Directory.systemTemp.createTempSync('agent-log');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = FileAgentLog(path: '${dir.path}/agent-changes.jsonl');
      AgentLogEntry change(String message) => AgentLogEntry(
            time: DateTime(2026),
            folder: 'f',
            path: 'a.org',
            tool: 'append_to_node',
            oldHash: 'a',
            newHash: 'b',
            messageId: message,
          );
      // Three lines of message "big", then the rest of the log.
      for (var i = 0; i < 3; i++) {
        await file.record(change('big'));
      }
      for (var i = 0; i < FileAgentLog.keep - 2; i++) {
        await file.record(change('m$i'));
      }
      final entries = await file.read();
      expect(entries.map((e) => e.messageId), isNot(contains('big')));
      expect(entries, hasLength(FileAgentLog.keep - 2));
    });
  });

  test('rename_node, set_tags and set_aliases change only the head (#97)',
      () async {
    final changes = agent.startMessage();
    expect(await call('rename_node', {'id': 'open', 'title': 'Opened'}),
        'Renamed "Open" to "Opened".');
    expect(await call('set_tags', {'id': 'open', 'tags': ['fungi', ':x:']}),
        'Set the tags of "Opened": fungi x.');
    expect(
        await call('set_aliases', {
          'id': 'open',
          'aliases': ['Open note', 'Op'],
        }),
        'Set the aliases of "Opened": Open note, Op.');
    expect(
        store.files['open.org'],
        ':PROPERTIES:\n:ID: open\n:ROAM_ALIASES: "Open note" Op\n:END:\n'
        '#+title: Opened\n#+filetags: :fungi:x:\n'
        'Some words. [[id:plan][Plan]] and [[id:plan][again]].\n');
    expect(await call('set_tags', {'id': 'open', 'tags': ['private']}),
        contains('hides a note'));
    await changes.undoAll(editor, create: agent.writer.create);
    expect(store.files, start);
  });
}

/// The same files, seen as another folder.
class OtherFolderStore extends MemoryNoteStore {
  OtherFolderStore(super.files);

  @override
  String historyKey(String path) => 'other\n$path';
}
