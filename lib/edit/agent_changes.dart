/// What the AI agent changed for one message (#82), so the chat can show
/// a summary and undo all of it, and a log of every change in the app's
/// own folder.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../capture/capture_screen.dart';
import 'note_editor.dart';

/// One write of the agent: a note created, changed or deleted.
class AgentChange {
  AgentChange({
    required this.tool,
    required this.path,
    this.noteKey = '',
    required this.nodeId,
    required this.title,
    required this.before,
    required this.after,
    this.linksAdded = 0,
    this.removed = '',
  });

  /// A part of the note the change removed on purpose, such as a heading
  /// with its subtree (#93): undo puts it back, with its drawers.
  final String removed;

  /// The tool that made it: `create_node`, `append_to_node`, ….
  final String tool;

  /// The file, relative to `roam/`.
  final String path;

  /// The folder and path ([NoteStore.historyKey]) when the change was
  /// made: undo only touches the file in that folder.
  final String noteKey;

  /// The node the change was for.
  final String nodeId;
  final String title;

  /// The file before the change; null when the change created it.
  final String? before;

  /// The file after the change; null when the change deleted it (#93).
  final String? after;

  /// How many `id:` links the change added.
  final int linksAdded;

  bool get created => before == null;
  bool get deleted => after == null;
}

/// What undoing did to one file.
enum UndoOutcome {
  restored,
  deleted,

  /// A note the agent deleted is written again (#93).
  recreated,
  changedSince,
  otherFolder,
  failed,
}

/// The changes the agent made for one message, in order.
class AgentChanges {
  final changes = <AgentChange>[];

  /// Set once "Undo all" ran: what became of each file.
  Map<String, UndoOutcome>? undone;

  /// Whether "Undo all" can run (again): not yet run, or a file failed,
  /// which a retry may still undo.
  bool get canUndo =>
      undone == null || undone!.values.contains(UndoOutcome.failed);

  bool get isEmpty => changes.isEmpty;
  int get length => changes.length;

  /// The files, each once, in the order first changed.
  List<String> get files => {for (final c in changes) c.path}.toList();

  /// The files the agent created.
  Set<String> get createdFiles => {
        for (final c in changes)
          if (c.created) c.path,
      };

  /// The files the agent deleted, and did not create first (#93).
  Set<String> get deletedFiles => {
        for (final path in files)
          if (after(path) == null && before(path) != null) path,
      };

  /// The files the agent changed that existed before, and still exist.
  Set<String> get changedFiles => {for (final c in changes) c.path}
      .difference(createdFiles)
      .difference(deletedFiles);

  int get linksAdded => changes.fold(0, (n, c) => n + c.linksAdded);

  /// The file as it was before the first change of this message; null if
  /// the agent created it.
  String? before(String path) =>
      changes.firstWhere((c) => c.path == path).before;

  /// The file after the last change of this message; null if deleted.
  String? after(String path) =>
      changes.lastWhere((c) => c.path == path).after;

  /// The first change of [path], for its node and title.
  AgentChange first(String path) => changes.firstWhere((c) => c.path == path);

  /// "3 notes created, 5 changed, 9 links added", leaving out what is 0.
  String get summary {
    String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    final parts = [
      if (createdFiles.isNotEmpty)
        count(createdFiles.length, 'note created', 'notes created'),
      if (changedFiles.isNotEmpty) '${changedFiles.length} changed',
      if (deletedFiles.isNotEmpty) '${deletedFiles.length} deleted',
      if (linksAdded > 0) count(linksAdded, 'link added', 'links added'),
    ];
    return parts.isEmpty ? 'No changes' : parts.join(', ');
  }

  /// Undoes every file of this message: a changed file gets back its text
  /// from before the message, a created file is deleted, but only if the
  /// file is still as the agent left it. Each file is checked and written
  /// as every edit is (decision 10). A deleted note is written again with
  /// [create], if no file of its name is there meanwhile. Returns what
  /// happened to each file.
  Future<Map<String, UndoOutcome>> undoAll(NoteEditor editor,
      {Future<CreateResult> Function(String fileName, String text)?
          create}) async {
    // A retry keeps what is done, and tries only the files that failed.
    final outcome = <String, UndoOutcome>{...?undone};
    // Newest first, so a note that links to a created one is restored
    // before that one is deleted.
    for (final path in files.reversed) {
      final previous = outcome[path];
      if (previous != null && previous != UndoOutcome.failed) continue;
      final key = first(path).noteKey;
      if (key.isNotEmpty && editor.store.historyKey(path) != key) {
        outcome[path] = UndoOutcome.otherFolder;
        continue;
      }
      final last = after(path);
      final original = before(path);
      if (last == null) {
        // Deleted by the agent: created first, there is nothing to undo.
        if (original == null) {
          outcome[path] = UndoOutcome.deleted;
          continue;
        }
        if (await editor.read(path) != null || create == null) {
          outcome[path] = await editor.read(path) != null
              ? UndoOutcome.changedSince
              : UndoOutcome.failed;
          continue;
        }
        outcome[path] = switch (await create(path, original)) {
          Created() || WrittenNotIndexed() => UndoOutcome.recreated,
          FileExists() => UndoOutcome.changedSince,
          _ => UndoOutcome.failed,
        };
        continue;
      }
      final now = await editor.read(path);
      if (now == null) {
        outcome[path] = UndoOutcome.failed;
        continue;
      }
      if (now.hash != contentHash(utf8.encode(last))) {
        outcome[path] = UndoOutcome.changedSince;
        continue;
      }
      if (original == null) {
        // The created note is kept too, as every replaced text is.
        await editor.history
            .keep(editor.store.historyKey(path), now.text, DateTime.now());
      }
      final restored = [
        for (final c in changes)
          if (c.path == path && c.removed.isNotEmpty) c.removed,
      ].join('\n');
      final result = original == null
          ? await editor.store.delete(path, now)
          : await editor.save(path, now, original, restored: restored);
      outcome[path] = switch (result) {
        Saved() || SavedNotIndexed() || NothingToSave() =>
          original == null ? UndoOutcome.deleted : UndoOutcome.restored,
        ChangedMeanwhile() => UndoOutcome.changedSince,
        _ => UndoOutcome.failed,
      };
    }
    return undone = outcome;
  }
}

/// One line of the log of agent changes.
class AgentLogEntry {
  const AgentLogEntry({
    required this.time,
    required this.folder,
    required this.path,
    required this.tool,
    required this.oldHash,
    required this.newHash,
  });

  final DateTime time;

  /// The folder (its URI) the file is in.
  final String folder;
  final String path;
  final String tool;

  /// The SHA-256 of the file before; null for a created file.
  final String? oldHash;

  /// The SHA-256 of the file after; null for a deleted one.
  final String? newHash;

  Map<String, Object?> toJson() => {
        'time': time.toUtc().toIso8601String(),
        'folder': folder,
        'path': path,
        'tool': tool,
        'oldHash': oldHash,
        'newHash': newHash,
      };
}

/// Where agent changes are logged. An interface so tests need no files.
abstract interface class AgentLog {
  Future<void> record(AgentLogEntry entry);
}

/// [AgentLog] in `agent-changes.jsonl` in the app's support folder, one
/// JSON object per line. The old texts are in the edit history (decision
/// 51), keyed by folder and path, so a change can be undone later from
/// the hashes here, also after the chat is closed.
class FileAgentLog implements AgentLog {
  const FileAgentLog({this.path});

  final String? path;

  @override
  Future<void> record(AgentLogEntry entry) async {
    try {
      final file = File(path ??
          '${(await getApplicationSupportDirectory()).path}/agent-changes.jsonl');
      await file.writeAsString('${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append, flush: true);
    } on Exception {
      // The log helps later; it must not stop a change that was saved.
    }
  }
}

/// [AgentLog] in memory, for tests.
class MemoryAgentLog implements AgentLog {
  final entries = <AgentLogEntry>[];

  @override
  Future<void> record(AgentLogEntry entry) async => entries.add(entry);
}
