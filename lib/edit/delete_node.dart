/// Shared deletion of file and heading nodes (#93, #171).
library;

import '../graph/roam_graph.dart';
import 'node_text.dart';
import 'note_editor.dart';
import 'unlink.dart';

class DeleteError implements Exception {
  const DeleteError(this.message);
  final String message;
}

typedef DeleteRead = Future<(NoteVersion, NodeLines)> Function(RoamNode node);
typedef DeleteSave = Future<void> Function(
  RoamNode node,
  NoteVersion base,
  String after,
  String removed,
);
typedef DeleteRecord = Future<void> Function(
  RoamNode node,
  String before,
  String? after,
  String removed,
  String key,
);

final _id = RegExp(
  r'^[ \t]*:ID:[ \t]+(\S+)[ \t]*$',
  multiLine: true,
  caseSensitive: false,
);

Set<String> _ids(String text) => {
  for (final m in _id.allMatches(text.replaceAll('\r\n', '\n'))) m[1]!,
};

/// A version captured before confirmation, and the exact proposed removal.
class DeleteFile {
  DeleteFile(
    this.node,
    this.base,
    this.key,
    this.after,
    this.removed,
    this.targets,
  );
  final RoamNode node;
  final NoteVersion base;
  final String key;
  final String? after;
  final String removed;
  final List<RoamNode> targets;
  late final Set<String> gone = _ids(removed);
}

class DeletePlan {
  DeletePlan(this.graph, this.targets, this.files);
  final RoamGraph graph;
  final List<RoamNode> targets;
  final List<DeleteFile> files;
  late final Set<String> gone = {for (final file in files) ...file.gone};
  late final int linkingNotes = {
    for (final link in graph.links)
      if (gone.contains(link.dest) && !gone.contains(link.source)) link.source,
  }.length;
}

class DeleteReport {
  final deleted = <RoamNode>[];
  final cleaned = <String>[];
  final left = <String>[];
  final failures = <String>[];
}

/// The AI supplies its visibility checks, limit and existing save/log
/// callbacks. Hand deletion uses the same operations without AI filters.
class NodeDeleter {
  NodeDeleter({
    required this.editor,
    required this.record,
    this.read,
    this.save,
    this.checkGoing,
    this.canChange,
    this.bracketLinksOnly = false,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       folderKey = editor.store.historyKey('');

  final NoteEditor editor;
  final DeleteRead? read;
  final DeleteSave? save;
  final DeleteRecord record;
  final void Function(String text)? checkGoing;
  final bool Function()? canChange;
  final DateTime Function() now;
  final String folderKey;
  final bool bracketLinksOnly;

  Future<(NoteVersion, NodeLines)> _read(RoamNode node) async {
    if (read case final custom?) return custom(node);
    final base = await editor.read(node.file);
    if (base == null) throw DeleteError('${node.file} cannot be read as text.');
    final lines = NodeLines.find(base.text, node);
    if (lines == null) {
      throw DeleteError(
        'The note ${node.id} is no longer in ${node.file} '
        'with its :ID:. Search for it again.',
      );
    }
    return (base, lines);
  }

  /// One removal per file, including overlapping selections only once.
  Future<DeletePlan> prepare(RoamGraph graph, List<RoamNode> nodes) async {
    final groups = <String, List<RoamNode>>{};
    for (final node in nodes) {
      if (node.file.contains('/') || node.file.contains('\\')) {
        throw DeleteError(
          '${node.file} is in a subfolder; only notes directly '
          'in roam/ can be deleted here.',
        );
      }
      groups.putIfAbsent(node.file, () => []).add(node);
    }
    final files = <DeleteFile>[];
    for (final group in groups.values) {
      final node = group.where((n) => n.isFile).firstOrNull ?? group.first;
      final key = editor.store.historyKey(node.file);
      final (base, lines) = await _read(node);
      _checkFolder(node.file, key);
      if (node.isFile) {
        checkGoing?.call(base.text);
        files.add(DeleteFile(node, base, key, null, base.text, group));
        continue;
      }
      final ranges = <(int, int)>[];
      for (final target in group) {
        final found = NodeLines.find(base.text, target);
        if (found == null) throw DeleteError('${target.displayTitle} changed.');
        var end = found.end;
        // The final newline stays when a subtree ends the file (#93).
        if (end == found.lines.length && found.lines[end - 1].isEmpty) end--;
        ranges.add((found.start, end));
      }
      ranges.sort((a, b) => a.$1.compareTo(b.$1));
      final merged = <(int, int)>[];
      for (final range in ranges) {
        if (merged.isNotEmpty && range.$1 < merged.last.$2) {
          final last = merged.removeLast();
          merged.add((last.$1, range.$2 > last.$2 ? range.$2 : last.$2));
        } else {
          merged.add(range);
        }
      }
      final removed = [
        for (final (start, end) in merged)
          lines.lines.sublist(start, end).join(lines.newline),
      ].join(lines.newline);
      checkGoing?.call(removed);
      final remaining = List.of(lines.lines);
      for (final (start, end) in merged.reversed) {
        remaining.removeRange(start, end);
      }
      files.add(
        DeleteFile(
          node,
          base,
          key,
          remaining.join(lines.newline),
          removed,
          group,
        ),
      );
    }
    return DeletePlan(graph, nodes, files);
  }

  void _checkFolder(String path, String key) {
    if (editor.store.historyKey('') != folderKey ||
        editor.store.historyKey(path) != key) {
      throw const DeleteError(
        'another folder was opened in the app; '
        'nothing was deleted. Stop here.',
      );
    }
  }

  Future<void> _save(
    RoamNode node,
    NoteVersion base,
    String after,
    String key, {
    String removed = '',
  }) async {
    _checkFolder(node.file, key);
    if (save case final custom?) {
      await custom(node, base, after, removed);
      return;
    }
    final result = await editor.save(node.file, base, after, removed: removed);
    _saved(result, node.file);
    if (result is Saved || result is SavedNotIndexed) {
      await record(node, base.text, after, removed, key);
    }
  }

  static void _saved(SaveResult result, String path) {
    switch (result) {
      case Saved() || SavedNotIndexed() || NothingToSave():
        return;
      case ChangedMeanwhile():
        throw DeleteError(
          '$path changed since it was read; nothing '
          'was deleted. Read the note again and retry.',
        );
      case NoWriteAccessToEdit():
        throw const DeleteError(
          'the app may only read the folder. Tell me '
          'to choose the folder again in the app to allow writing.',
        );
      default:
        throw DeleteError('$path could not be deleted.');
    }
  }

  /// Failed files stay unchanged. Only successfully removed IDs are
  /// unlinked, and all resulting writes belong to the caller's one group.
  Future<DeleteReport> apply(
    DeletePlan plan, {
    bool turnLinksIntoText = true,
    bool stopOnError = false,
  }) async {
    final report = DeleteReport();
    final gone = <String>{};
    final deletedFiles = <String>{};
    for (final file in plan.files) {
      try {
        _checkFolder(file.node.file, file.key);
        if (file.after case final after?) {
          await _save(
            file.node,
            file.base,
            after,
            file.key,
            removed: file.removed,
          );
        } else {
          final time = await editor.history.keep(
            file.key,
            file.base.text,
            now(),
          );
          SaveResult result;
          try {
            _checkFolder(file.node.file, file.key);
            result = await editor.store.delete(file.node.file, file.base);
          } catch (_) {
            await editor.history.forget(file.key, time);
            rethrow;
          }
          if (result is! Saved && result is! SavedNotIndexed) {
            await editor.history.forget(file.key, time);
          }
          _saved(result, file.node.file);
          await record(file.node, file.base.text, null, '', file.key);
          deletedFiles.add(file.node.file);
        }
        gone.addAll(file.gone);
        report.deleted.addAll(file.targets);
      } on DeleteError catch (e) {
        if (stopOnError) rethrow;
        report.failures.add(e.message);
      }
    }
    if (turnLinksIntoText && gone.isNotEmpty) {
      final (changed, left) = await unlink(
        gone,
        plan.graph,
        except: deletedFiles,
      );
      report.cleaned.addAll(changed);
      report.left.addAll(left);
    }
    return report;
  }

  /// Turns links to removed nodes into text once per surviving file.
  /// Reads fresh versions, and still uses the store's hash check on save.
  Future<(List<String>, List<String>)> unlink(
    Set<String> gone,
    RoamGraph graph, {
    required Set<String> except,
  }) async {
    final files = <String, RoamNode>{};
    for (final link in graph.links) {
      if (!gone.contains(link.dest)) continue;
      final source = graph.nodes[link.source];
      if (source == null ||
          gone.contains(source.id) ||
          except.contains(source.file)) {
        continue;
      }
      final current = files[source.file];
      if (current == null || (!current.isFile && source.isFile)) {
        files[source.file] = source;
      }
    }
    final changed = <String>[], left = <String>[];
    for (final source in files.values) {
      if (!(canChange?.call() ?? true)) {
        left.add(source.displayTitle);
        continue;
      }
      try {
        final key = editor.store.historyKey(source.file);
        final base = (await _read(source)).$1;
        final after = withoutIdLinks(
          base.text,
          gone,
          bracketOnly: bracketLinksOnly,
        );
        if (after == base.text) continue;
        await _save(source, base, after, key);
        changed.add(source.displayTitle);
      } on DeleteError {
        left.add(source.displayTitle);
      }
    }
    return (changed, left);
  }
}
