/// Synthetic notes and a hash-checking store for hand-delete tests (#171).
library;

import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/delete_node.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

import '../ai/ai_visibility_test.dart' show graphOf;
import 'note_editor_test.dart' show MemoryNoteStore;

const deleteNotes = {
  'a.org':
      ':PROPERTIES:\n:ID: a\n:END:\n#+title: Alpha\n'
      'See [[id:b][Beta]].\n'
      '* Branch\n:PROPERTIES:\n:ID: h\n:END:\nBranch text.\n'
      '** Child\n:PROPERTIES:\n:ID: c\n:END:\nChild text.\n'
      '* Keep\nUnchanged tail.\n',
  'b.org':
      ':PROPERTIES:\n:ID: b\n:END:\n#+title: Beta\n'
      'See [[id:a][Alpha]] and [[id:h][Branch]].\n',
  'l.org':
      ':PROPERTIES:\n:ID: l\n:END:\n#+title: Linking\n'
      '[[id:a][Alpha]], [[id:c][Child]], [[id:b][Beta]].\n',
};

class DeleteStore extends MemoryNoteStore {
  DeleteStore(super.files);
  void Function()? notify;
  String folder = 'folder';
  String? raceOn;
  void Function()? afterRead;

  @override
  Future<NoteVersion?> read(String path) async {
    final version = await super.read(path);
    final callback = afterRead;
    afterRead = null;
    callback?.call();
    return version;
  }

  @override
  String historyKey(String path) => '$folder\n$path';

  void _race(String path) {
    if (raceOn == path) {
      files[path] = '${files[path]}Outside.\n';
      raceOn = null;
    }
  }

  @override
  Future<SaveResult> replace(String path, NoteVersion base, String text) async {
    _race(path);
    final result = await super.replace(path, base, text);
    notify?.call();
    return result;
  }

  @override
  Future<SaveResult> delete(String path, NoteVersion base) async {
    _race(path);
    final result = await super.delete(path, base);
    notify?.call();
    return result;
  }
}

class DeleteFixture {
  DeleteFixture([Map<String, String> notes = deleteNotes]) {
    store = DeleteStore(Map.of(notes));
    graph = ValueNotifier(graphOf(store.files));
    store.notify = () => graph.value = graphOf(store.files);
    editor = NoteEditor(store: store, history: history);
    writer = NoteWriter(
      editor: editor,
      changeLog: log,
      create: (path, text) async {
        if (store.files.containsKey(path)) return const FileExists();
        store.files[path] = text;
        store.notify?.call();
        return Created(path);
      },
      allowWriting: () async {},
    );
    deleter = NodeDeleter(
      editor: editor,
      record: (node, before, after, removed, key) async {
        final change = AgentChange(
          tool: 'hand_delete',
          path: node.file,
          nodeId: node.id,
          title: node.displayTitle,
          noteKey: key,
          before: before,
          after: after,
          removed: removed,
        );
        changes.changes.add(change);
        await log.record(
          AgentLogEntry.of(changes, change, store.folder, DateTime.now()),
        );
      },
    );
  }

  late final DeleteStore store;
  late final NoteEditor editor;
  late final NoteWriter writer;
  late final ValueNotifier<RoamGraph> graph;
  late final NodeDeleter deleter;
  final history = MemoryEditHistory();
  final log = MemoryAgentLog();
  final changes = AgentChanges(messageId: 'synthetic-delete', prompt: 'Delete');

  Future<DeletePlan> prepare(List<String> ids) => deleter.prepare(graph.value, [
    for (final id in ids) graph.value.nodes[id]!,
  ]);
}
