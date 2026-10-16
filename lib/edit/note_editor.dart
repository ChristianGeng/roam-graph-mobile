/// Changes to existing notes, under the rules of decision 10 (#34, #35):
/// an edit is saved only over the version it was made on, the file is
/// replaced through a temporary file, the old version is kept, and the
/// `:ID:` and the property drawers stay as they are.
///
/// The transport is behind [NoteStore]: today the Syncthing folder
/// (`lib/folder/folder_screen.dart`), later perhaps git.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// The SHA-256 of a file's bytes, in hex: what an edit was made on.
String contentHash(List<int> bytes) => sha256.convert(bytes).toString();

/// A note as read for editing: its text, and the hash of its bytes.
class NoteVersion {
  const NoteVersion(this.text, this.hash);

  /// The version of a file with [bytes]; null if they are not UTF-8, since
  /// such a file could not be written back unchanged.
  static NoteVersion? of(List<int> bytes) {
    try {
      return NoteVersion(utf8.decode(bytes), contentHash(bytes));
    } on FormatException {
      return null;
    }
  }

  final String text;
  final String hash;
}

/// What saving an edit did.
sealed class SaveResult {
  const SaveResult();
}

/// The file was replaced and the folder indexed again.
class Saved extends SaveResult {
  const Saved(this.path);

  /// Relative to `roam/`.
  final String path;
}

/// The file was replaced, but indexing the folder afterwards failed; the
/// change shows with the next scan.
class SavedNotIndexed extends SaveResult {
  const SavedNotIndexed(this.path, this.message);

  final String path;
  final String message;
}

/// The text is the same as the file's; nothing was written.
class NothingToSave extends SaveResult {
  const NothingToSave();
}

/// The file changed since it was read, on the laptop or through
/// Syncthing; nothing was written. [current] is the file as it is now,
/// null if it cannot be read.
class ChangedMeanwhile extends SaveResult {
  const ChangedMeanwhile(this.current);

  final NoteVersion? current;
}

/// The file is no longer there; nothing was written.
class NoteGone extends SaveResult {
  const NoteGone();
}

/// The edit changes an `:ID:` or a property drawer, which stay as they are
/// (decision 10, rule 5); nothing was written.
class LockedPartChanged extends SaveResult {
  const LockedPartChanged();
}

/// The app may only read the folder: it was chosen before v2.
class NoWriteAccessToEdit extends SaveResult {
  const NoWriteAccessToEdit();
}

class SaveFailed extends SaveResult {
  const SaveFailed(this.message);

  final String message;
}

/// Reads and replaces notes, by path relative to `roam/`.
abstract interface class NoteStore {
  /// The note as it is now; null if it is gone or not UTF-8.
  Future<NoteVersion?> read(String path);

  /// Replaces the note with [text] if the file is still [base]; checked
  /// just before writing. Then indexes the folder again.
  Future<SaveResult> replace(String path, NoteVersion base, String text);
}

/// An old version of a note, kept before an edit replaced it.
class KeptVersion {
  const KeptVersion(this.path, this.time, this.text);

  final String path;
  final DateTime time;
  final String text;
}

/// The old versions of notes, kept before each edit (decision 10, rule 3).
abstract interface class EditHistory {
  /// Keeps [text], the note [path] before an edit at [time].
  Future<void> keep(String path, String text, DateTime time);

  /// Drops the version kept at [time], when the edit was not saved.
  Future<void> forget(String path, DateTime time);

  /// The kept versions of [path], newest first.
  Future<List<KeptVersion>> versions(String path);
}

/// How many old versions are kept per note.
const keptVersionsPerNote = 20;

/// [EditHistory] in the app's support folder, `edit-history/`: one folder
/// per note, named by the hash of its path, with a file `path` naming the
/// note and one file per version, named by its time in microseconds. Only
/// the newest [keptVersionsPerNote] are kept. The folder belongs to the app
/// and is never synced.
class FileEditHistory implements EditHistory {
  const FileEditHistory({this.root});

  /// The folder to use; the app's support folder if null.
  final Directory? root;

  Future<Directory> _dir(String path) async {
    final base = root ??
        Directory('${(await getApplicationSupportDirectory()).path}'
            '/edit-history');
    final key = contentHash(utf8.encode(path)).substring(0, 32);
    return Directory('${base.path}/$key');
  }

  @override
  Future<void> keep(String path, String text, DateTime time) async {
    final dir = await _dir(path);
    await dir.create(recursive: true);
    await File('${dir.path}/path').writeAsString(path);
    await File('${dir.path}/${time.microsecondsSinceEpoch}.org')
        .writeAsString(text);
    final kept = await _versionFiles(dir);
    for (final old in kept.skip(keptVersionsPerNote)) {
      await old.delete();
    }
  }

  @override
  Future<void> forget(String path, DateTime time) async {
    final file =
        File('${(await _dir(path)).path}/${time.microsecondsSinceEpoch}.org');
    if (await file.exists()) await file.delete();
  }

  @override
  Future<List<KeptVersion>> versions(String path) async {
    final dir = await _dir(path);
    if (!await dir.exists()) return const [];
    return [
      for (final file in await _versionFiles(dir))
        KeptVersion(path, _timeOf(file)!, await file.readAsString()),
    ];
  }

  /// The version files in [dir], newest first.
  static Future<List<File>> _versionFiles(Directory dir) async {
    final files = [
      await for (final entry in dir.list())
        if (entry is File && _timeOf(entry) != null) entry,
    ]..sort((a, b) => _timeOf(b)!.compareTo(_timeOf(a)!));
    return files;
  }

  static DateTime? _timeOf(File file) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('.org')) return null;
    final micros = int.tryParse(name.substring(0, name.length - 4));
    return micros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(micros);
  }
}

/// [EditHistory] in memory, for tests.
class MemoryEditHistory implements EditHistory {
  final Map<String, List<KeptVersion>> _kept = {};

  @override
  Future<void> keep(String path, String text, DateTime time) async {
    final list = _kept.putIfAbsent(path, () => [])
      ..insert(0, KeptVersion(path, time, text));
    if (list.length > keptVersionsPerNote) {
      list.removeRange(keptVersionsPerNote, list.length);
    }
  }

  @override
  Future<void> forget(String path, DateTime time) async =>
      _kept[path]?.removeWhere((v) => v.time == time);

  @override
  Future<List<KeptVersion>> versions(String path) async =>
      List.of(_kept[path] ?? const []);
}

final _drawerStart = RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);

/// The property drawers of [text], each as its lines, in order. The `:ID:`
/// lives in them.
List<String> propertyDrawers(String text) {
  final drawers = <String>[];
  StringBuffer? current;
  for (final line in const LineSplitter().convert(text)) {
    if (current == null) {
      if (_drawerStart.hasMatch(line)) current = StringBuffer(line);
    } else {
      current
        ..write('\n')
        ..write(line);
      if (_drawerEnd.hasMatch(line)) {
        drawers.add(current.toString());
        current = null;
      }
    }
  }
  return drawers;
}

/// Saves edits of existing notes under decision 10's rules.
class NoteEditor {
  NoteEditor({
    required this.store,
    required this.history,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final NoteStore store;
  final EditHistory history;
  final DateTime Function() _now;

  /// The note [path] as it is now, to edit; null if it cannot be edited.
  Future<NoteVersion?> read(String path) => store.read(path);

  /// Replaces the note [path], read as [base], with [text]. Keeps [base]
  /// first; drops it again if nothing was written.
  Future<SaveResult> save(String path, NoteVersion base, String text) async {
    if (text == base.text) return const NothingToSave();
    final before = propertyDrawers(base.text), after = propertyDrawers(text);
    if (before.length != after.length ||
        [for (var i = 0; i < before.length; i++) before[i] != after[i]]
            .any((changed) => changed)) {
      return const LockedPartChanged();
    }
    final time = _now();
    await history.keep(path, base.text, time);
    final SaveResult result;
    try {
      result = await store.replace(path, base, text);
    } catch (e) {
      await history.forget(path, time);
      return SaveFailed('$e');
    }
    if (result is! Saved && result is! SavedNotIndexed) {
      await history.forget(path, time);
    }
    return result;
  }
}
