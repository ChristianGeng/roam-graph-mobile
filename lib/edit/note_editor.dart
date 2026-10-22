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

  /// Deletes the note if the file is still [base] (#82: undoing a note
  /// the AI created), then indexes the folder again. [Saved] when it was
  /// deleted; [ChangedMeanwhile] if it changed since.
  Future<SaveResult> delete(String path, NoteVersion base);

  /// The key the old versions of [path] are kept under: the path within
  /// this folder, so notes of the same name in another folder do not mix.
  String historyKey(String path);
}

/// An old version of a note, kept before an edit replaced it.
class KeptVersion {
  const KeptVersion(this.key, this.time, this.text);

  /// The note's key in the history: its folder and path.
  final String key;
  final DateTime time;
  final String text;
}

/// The old versions of notes, kept before each edit (decision 10, rule 3),
/// by a key that names the folder and the note.
abstract interface class EditHistory {
  /// Keeps [text], the note [key] before an edit at about [time], and
  /// returns the time it is kept under: [time], or a little later if a
  /// version is kept at that time already. Removes nothing.
  Future<DateTime> keep(String key, String text, DateTime time);

  /// Drops the version kept at [time], when the edit was not saved.
  Future<void> forget(String key, DateTime time);

  /// Keeps only the newest [keptVersionsPerNote], after an edit was saved.
  Future<void> prune(String key);

  /// The kept versions of [key], newest first.
  Future<List<KeptVersion>> versions(String key);
}

/// How many old versions are kept per note.
const keptVersionsPerNote = 20;

/// [EditHistory] in the app's support folder, `edit-history/`: one folder
/// per note, named by the hash of its key, with a file `key` naming it and
/// one file per version, named by its time in microseconds. The folder
/// belongs to the app and is never synced.
class FileEditHistory implements EditHistory {
  const FileEditHistory({this.root});

  /// The folder to use; the app's support folder if null.
  final Directory? root;

  Future<Directory> _dir(String key) async {
    final base = root ??
        Directory('${(await getApplicationSupportDirectory()).path}'
            '/edit-history');
    final hash = contentHash(utf8.encode(key)).substring(0, 32);
    return Directory('${base.path}/$hash');
  }

  File _file(Directory dir, DateTime time) =>
      File('${dir.path}/${time.microsecondsSinceEpoch}.org');

  @override
  Future<DateTime> keep(String key, String text, DateTime time) async {
    final dir = await _dir(key);
    await dir.create(recursive: true);
    await File('${dir.path}/key').writeAsString(key);
    var at = time;
    while (await _file(dir, at).exists()) {
      at = at.add(const Duration(microseconds: 1));
    }
    await _file(dir, at).writeAsString(text);
    return at;
  }

  @override
  Future<void> forget(String key, DateTime time) async {
    final file = _file(await _dir(key), time);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> prune(String key) async {
    final dir = await _dir(key);
    if (!await dir.exists()) return;
    for (final old in (await _versionFiles(dir)).skip(keptVersionsPerNote)) {
      await old.delete();
    }
  }

  @override
  Future<List<KeptVersion>> versions(String key) async {
    final dir = await _dir(key);
    if (!await dir.exists()) return const [];
    return [
      for (final file in await _versionFiles(dir))
        KeptVersion(key, _timeOf(file)!, await file.readAsString()),
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
  Future<DateTime> keep(String key, String text, DateTime time) async {
    final list = _kept.putIfAbsent(key, () => []);
    var at = time;
    while (list.any((v) => v.time == at)) {
      at = at.add(const Duration(microseconds: 1));
    }
    list
      ..add(KeptVersion(key, at, text))
      ..sort((a, b) => b.time.compareTo(a.time));
    return at;
  }

  @override
  Future<void> forget(String key, DateTime time) async =>
      _kept[key]?.removeWhere((v) => v.time == time);

  @override
  Future<void> prune(String key) async {
    final list = _kept[key];
    if (list != null && list.length > keptVersionsPerNote) {
      list.removeRange(keptVersionsPerNote, list.length);
    }
  }

  @override
  Future<List<KeptVersion>> versions(String key) async =>
      List.of(_kept[key] ?? const []);
}

final _aliases = RegExp(r'^[ \t]*:ROAM_ALIASES:', caseSensitive: false);
final _drawerStart = RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);

/// The property drawers of [text], in order, each with the line right
/// before it: the heading (or planning line) it belongs to, or "" at the
/// top of the file. Org attaches a drawer to that line only, so a drawer
/// moved under another heading, or text put between a heading and its
/// drawer, gives another node its `:ID:` or none.
///
/// With [todoKeywords], a drawer's heading counts without its TODO keyword
/// (one of [todoKeywords]) and its progress cookies, and a planning line
/// between them is skipped: the heading's state, its cookies and its
/// `CLOSED:` time may change (#150), but its stars, title and tags stay,
/// and the drawer stays under it.
List<String> propertyDrawers(String text, {Set<String>? todoKeywords}) {
  final drawers = <String>[];
  StringBuffer? current;
  var previous = '';
  var previousIsHeading = false;
  for (final line in const LineSplitter().convert(text)) {
    if (current == null) {
      if (_drawerStart.hasMatch(line)) {
        current = StringBuffer(previous)
          ..write('\n')
          ..write(line);
      }
    } else {
      current
        ..write('\n')
        ..write(line);
      if (_drawerEnd.hasMatch(line)) {
        drawers.add(current.toString());
        current = null;
      }
    }
    if (todoKeywords == null) {
      previous = line;
    } else if (_heading.firstMatch(line) case final heading?) {
      previous = _withoutStateAndCookies(heading, todoKeywords);
      previousIsHeading = true;
      continue;
    } else if (!(previousIsHeading && _planning.hasMatch(line))) {
      previous = line;
    }
    previousIsHeading = false;
  }
  return drawers;
}

final _heading = RegExp(r'^(\*+)[ \t]+(.*)$');
final _cookie = RegExp(r'\[\d*(/\d*|%)\]');

/// A heading line's stars and title (with its tags) without the leading
/// keyword, when it is one of [keywords], and without progress cookies;
/// spaces collapsed.
String _withoutStateAndCookies(RegExpMatch heading, Set<String> keywords) {
  var rest = heading[2]!;
  final first = rest.split(RegExp(r'[ \t]')).first;
  if (keywords.contains(first)) rest = rest.substring(first.length);
  rest = rest.replaceAll(_cookie, '').trim().split(RegExp(r'[ \t]+')).join(' ');
  return '${heading[1]} $rest';
}
final _planning =
    RegExp(r'^[ \t]*(SCHEDULED|DEADLINE|CLOSED):');

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

  /// The kept versions of the note [path], newest first.
  Future<List<KeptVersion>> versions(String path) =>
      history.versions(store.historyKey(path));

  /// Replaces the note [path], read as [base], with [text]. Keeps [base]
  /// first; drops it again if nothing was written.
  ///
  /// [removed] is a part of the note that the edit deletes on purpose,
  /// such as a heading node with its subtree (#93): its drawers may go,
  /// every other drawer must stay as it is. [restored] is such a part
  /// put back, by undo: its drawers may come back.
  /// With [aliasesMayChange], the `:ROAM_ALIASES:` lines of the drawers
  /// may change, be added or go (#97); every other drawer line stays.
  /// With [todoKeywords], the heading line above a drawer may change its
  /// TODO keyword among these and its progress cookies, and get or lose a
  /// planning line (#150: `CLOSED:`); its title, tags and the drawer itself
  /// stay as they are.
  Future<SaveResult> save(String path, NoteVersion base, String text,
      {String removed = '',
      String restored = '',
      bool aliasesMayChange = false,
      Set<String>? todoKeywords}) async {
    if (text == base.text) return const NothingToSave();
    List<String> drawers(String t) => [
          for (final d
              in propertyDrawers(t, todoKeywords: todoKeywords))
            aliasesMayChange
                ? d.split('\n').where((l) => !_aliases.hasMatch(l)).join('\n')
                : d,
        ];
    final before = drawers(base.text), after = drawers(text);
    for (final drawer in drawers(removed)) {
      before.remove(drawer);
    }
    for (final drawer in drawers(restored)) {
      after.remove(drawer);
    }
    if (before.length != after.length ||
        [for (var i = 0; i < before.length; i++) before[i] != after[i]]
            .any((changed) => changed)) {
      return const LockedPartChanged();
    }
    final key = store.historyKey(path);
    final time = await history.keep(key, base.text, _now());
    final SaveResult result;
    try {
      result = await store.replace(path, base, text);
    } catch (e) {
      await history.forget(key, time);
      return SaveFailed('$e');
    }
    if (result is Saved || result is SavedNotIndexed) {
      await history.prune(key);
    } else {
      await history.forget(key, time);
    }
    return result;
  }
}
