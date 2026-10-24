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
  AgentChanges({this.messageId = '', this.prompt = '', DateTime? time})
      : time = time ?? DateTime.now();

  /// Unique for the message, so the log can group its changes (#99).
  final String messageId;

  /// The first words of the message.
  final String prompt;

  /// When the message was sent.
  final DateTime time;

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
      final folderKey = editor.store.historyKey(path);
      bool sameFolder() => editor.store.historyKey(path) == folderKey;
      if (key.isNotEmpty && folderKey != key) {
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
        final existing = await editor.read(path);
        if (!sameFolder()) {
          outcome[path] = UndoOutcome.otherFolder;
          continue;
        }
        if (existing != null || create == null) {
          outcome[path] = existing != null
              ? UndoOutcome.changedSince : UndoOutcome.failed;
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
      if (!sameFolder()) {
        outcome[path] = UndoOutcome.otherFolder;
        continue;
      }
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
        await editor.history.keep(folderKey, now.text, DateTime.now());
        if (!sameFolder()) {
          outcome[path] = UndoOutcome.otherFolder;
          continue;
        }
      }
      final restored = [
        for (final c in changes)
          if (c.path == path && c.removed.isNotEmpty) c.removed,
      ].join('\n');
      final result = original == null
          ? await editor.store.delete(path, now)
          // The text from before may have other aliases (#97).
          : await editor.save(path, now, original,
              restored: restored, aliasesMayChange: true);
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

/// "Undone." or which notes stayed, for a snack bar.
String undoMessage(Map<String, UndoOutcome> outcome) {
  final kept = outcome.values.where((o) =>
      o != UndoOutcome.restored &&
      o != UndoOutcome.deleted &&
      o != UndoOutcome.recreated);
  return kept.isEmpty
      ? 'Undone.'
      : 'Undone, except ${kept.length} '
          '${kept.length == 1 ? 'note' : 'notes'} changed since or not '
          'writable; those stay as they are.';
}

/// Runs [AgentChanges.undoAll] and, once nothing failed, logs that the
/// message is undone, so "Recent AI changes" shows it so (#99).
Future<Map<String, UndoOutcome>> undoAndLog(
    AgentChanges changes, NoteEditor editor, AgentLog log,
    {Future<CreateResult> Function(String fileName, String text)? create,
    DateTime? now}) async {
  final outcome = await changes.undoAll(editor, create: create);
  if (changes.messageId.isNotEmpty && !changes.canUndo) {
    await log.record(AgentLogEntry.undo(changes.messageId, now ?? DateTime.now()));
  }
  return outcome;
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
    this.messageId = '',
    this.prompt = '',
    this.noteKey = '',
    this.nodeId = '',
    this.title = '',
    this.before,
    this.after,
    this.removed = '',
    this.linksAdded = 0,
    this.full = true,
  });

  /// The line that says the changes of message [messageId] were undone.
  AgentLogEntry.undo(this.messageId, this.time)
      : folder = '',
        path = '',
        tool = undoTool,
        oldHash = null,
        newHash = null,
        prompt = '',
        noteKey = '',
        nodeId = '',
        title = '',
        before = null,
        after = null,
        removed = '',
        linksAdded = 0,
        full = true;

  /// A change of the log as it is written, for [AgentLog.read]. Lines of
  /// the first format (decision 59) have hashes only: [full] is false, and
  /// they cannot be undone.
  factory AgentLogEntry.fromJson(Map<String, Object?> json) {
    String text(String key) => json[key] as String? ?? '';
    return AgentLogEntry(
      time: DateTime.parse(text('time')).toLocal(),
      folder: text('folder'),
      path: text('path'),
      tool: text('tool'),
      oldHash: json['oldHash'] as String?,
      newHash: json['newHash'] as String?,
      messageId: text('message'),
      prompt: text('prompt'),
      noteKey: text('noteKey'),
      nodeId: text('nodeId'),
      title: text('title'),
      before: json['before'] as String?,
      after: json['after'] as String?,
      removed: text('removed'),
      linksAdded: (json['linksAdded'] as num?)?.toInt() ?? 0,
      full: json['v'] == 2,
    );
  }

  /// The [tool] of an undo line.
  static const undoTool = 'undo';

  bool get isUndo => tool == undoTool;

  final DateTime time;

  /// The folder (its URI) the file is in.
  final String folder;
  final String path;
  final String tool;

  /// The SHA-256 of the file before; null for a created file.
  final String? oldHash;

  /// The SHA-256 of the file after; null for a deleted one.
  final String? newHash;

  /// The message the change was made for, and its first words (#99).
  final String messageId;
  final String prompt;

  /// What undo needs: [AgentChange]'s fields.
  final String noteKey;
  final String nodeId;
  final String title;
  final String? before;
  final String? after;
  final String removed;
  final int linksAdded;

  /// Whether the line has what undo needs.
  final bool full;

  /// The entry for one change of [changes].
  factory AgentLogEntry.of(
          AgentChanges changes, AgentChange change, String folder, DateTime time) =>
      AgentLogEntry(
        time: time,
        folder: folder,
        path: change.path,
        tool: change.tool,
        oldHash: change.before == null
            ? null
            : contentHash(utf8.encode(change.before!)),
        newHash:
            change.after == null ? null : contentHash(utf8.encode(change.after!)),
        messageId: changes.messageId,
        prompt: changes.prompt,
        noteKey: change.noteKey,
        nodeId: change.nodeId,
        title: change.title,
        before: change.before,
        after: change.after,
        removed: change.removed,
        linksAdded: change.linksAdded,
      );

  AgentChange get change => AgentChange(
        tool: tool,
        path: path,
        noteKey: noteKey,
        nodeId: nodeId,
        title: title,
        before: before,
        after: after,
        removed: removed,
        linksAdded: linksAdded,
      );

  Map<String, Object?> toJson() => isUndo
      ? {
          'v': 2,
          'time': time.toUtc().toIso8601String(),
          'tool': tool,
          'message': messageId,
        }
      : {
          'v': 2,
          'time': time.toUtc().toIso8601String(),
          'folder': folder,
          'path': path,
          'tool': tool,
          'oldHash': oldHash,
          'newHash': newHash,
          'message': messageId,
          'prompt': prompt,
          'noteKey': noteKey,
          'nodeId': nodeId,
          'title': title,
          'before': before,
          'after': after,
          if (removed.isNotEmpty) 'removed': removed,
          'linksAdded': linksAdded,
        };
}

/// Where agent changes are logged. An interface so tests need no files.
abstract interface class AgentLog {
  Future<void> record(AgentLogEntry entry);

  /// Every line, oldest first.
  Future<List<AgentLogEntry>> read();
}

/// The changes of one message, as the log has them (#99).
class LoggedMessage {
  LoggedMessage(this.changes, {required this.undoable, required this.undone});

  final AgentChanges changes;

  /// Every line has what undo needs.
  final bool undoable;

  /// "Undo" ran for it, in the chat or here.
  bool undone;

  DateTime get time => changes.time;
}

/// How long changes are shown in "Recent AI changes".
const recentDays = 30;

/// The log's messages of the last [recentDays] days, newest first. Lines
/// without a message (the first format) are each their own message.
List<LoggedMessage> recentMessages(List<AgentLogEntry> entries,
    {DateTime? now}) {
  final since =
      (now ?? DateTime.now()).subtract(const Duration(days: recentDays));
  final undone = {
    for (final e in entries)
      if (e.isUndo) e.messageId,
  };
  final groups = <String, List<AgentLogEntry>>{};
  for (final (i, e) in entries.indexed) {
    if (e.isUndo) continue;
    groups.putIfAbsent(e.messageId.isEmpty ? '#$i' : e.messageId, () => [])
        .add(e);
  }
  final messages = [
    for (final MapEntry(key: id, value: lines) in groups.entries)
      if (!lines.last.time.isBefore(since))
        LoggedMessage(
          AgentChanges(
            messageId: lines.first.messageId,
            prompt: lines.first.prompt,
            time: lines.first.time,
          )..changes.addAll([for (final e in lines) e.change]),
          undoable: lines.first.messageId.isNotEmpty &&
              lines.every((e) => e.full),
          undone: undone.contains(id),
        ),
  ];
  // Newest first; of the same time, the one logged later first.
  final order = {for (final (i, m) in messages.indexed) m: i};
  messages.sort((a, b) {
    final byTime = b.time.compareTo(a.time);
    return byTime != 0 ? byTime : order[b]!.compareTo(order[a]!);
  });
  return messages;
}

/// [AgentLog] in `agent-changes.jsonl` in the app's support folder, one
/// JSON object per line. The old texts are in the edit history (decision
/// 51), keyed by folder and path, so a change can be undone later from
/// the hashes here, also after the chat is closed.
class FileAgentLog implements AgentLog {
  const FileAgentLog({this.path});

  final String? path;

  /// The most lines kept: [read] drops older ones.
  static const keep = 1000;

  Future<File> _file() async => File(path ??
      '${(await getApplicationSupportDirectory()).path}/agent-changes.jsonl');

  /// [record] and [read] run one after the other, also from two screens:
  /// a trim in [read] must not drop a line appended meanwhile.
  static Future<void> _queue = Future.value();

  static Future<T> _serial<T>(Future<T> Function() work) {
    final run = _queue.then((_) => work());
    _queue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<void> record(AgentLogEntry entry) => _serial(() => _record(entry));

  @override
  Future<List<AgentLogEntry>> read() => _serial(_read);

  Future<void> _record(AgentLogEntry entry) async {
    try {
      await (await _file()).writeAsString('${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append, flush: true);
    } on Exception {
      // The log helps later; it must not stop a change that was saved.
    }
  }

  /// Reads the log; when it has more than [keep] lines, the oldest are
  /// dropped from the file, through a temporary file.
  Future<List<AgentLogEntry>> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final lines = [
        for (final line in await file.readAsLines())
          if (line.trim().isNotEmpty) line,
      ];
      final parsed = <AgentLogEntry?>[
        for (final line in lines) _parse(line),
      ];
      if (lines.length > keep) {
        // Cut between messages: the rest of a message cut in half goes
        // too, so no message is undone from its middle.
        var cut = lines.length - keep;
        String id(int i) => parsed[i]?.messageId ?? '';
        while (cut < lines.length &&
            id(cut).isNotEmpty &&
            id(cut) == id(cut - 1) &&
            !(parsed[cut]?.isUndo ?? false)) {
          cut++;
        }
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(
            lines.sublist(cut).map((l) => '$l\n').join(),
            flush: true);
        await temp.rename(file.path);
        return [...parsed.sublist(cut).nonNulls];
      }
      return [...parsed.nonNulls];
    } on Exception {
      return const [];
    }
  }
}

AgentLogEntry? _parse(String line) {
  try {
    return AgentLogEntry.fromJson(jsonDecode(line) as Map<String, Object?>);
  } on Object {
    // A line cut short by a crash is skipped.
    return null;
  }
}

/// [AgentLog] in memory, for tests.
class MemoryAgentLog implements AgentLog {
  final entries = <AgentLogEntry>[];

  @override
  Future<void> record(AgentLogEntry entry) async => entries.add(entry);

  /// Through JSON, as the file log reads its lines.
  @override
  Future<List<AgentLogEntry>> read() async => [
        for (final e in entries)
          AgentLogEntry.fromJson(
              jsonDecode(jsonEncode(e.toJson())) as Map<String, Object?>),
      ];
}
