import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'indexer.dart' as indexer;
import 'org_roam_parser.dart';
import 'roam_db.dart';
import 'roam_graph.dart';

/// What the index holds: the folder (its URI) the files are from, and the
/// root its stored paths start with ([databaseRoot]).
typedef IndexedFolder = ({String folder, String root});

/// The folder the database's absolute paths start with (decision 160).
///
/// org-roam stores every file with its absolute path below
/// `org-roam-directory`, so the app does too (decision 23): with the same
/// root as on the computer that runs Emacs, the paths match org-roam's own
/// database and the MCP tools.
///
/// - [setting] ("Notes folder on the computer with Emacs"), when it is set.
/// - Otherwise, on the desktop ([desktop]), the notes folder itself:
///   [folderUri], the chosen folder's path, plus `roam` when the graph is
///   its `roam/` subfolder ([roamPrefix] `roam/`).
/// - Otherwise (Android, whose folder has no path) a neutral root made
///   from the folder's name: `/notes/<folder name>`, plus `/roam` as
///   above; never a path of the device.
///
/// Backslashes become slashes, as in Emacs on Windows, and a slash at the
/// end goes.
String databaseRoot({
  required String setting,
  required String folderUri,
  required String folderName,
  required String roamPrefix,
  required bool desktop,
}) {
  final set = cleanRoot(setting);
  if (set != null) return set;
  final roam = roamPrefix.isEmpty ? '' : '/roam';
  if (desktop) {
    final folder = cleanRoot(folderUri);
    if (folder != null) return '$folder$roam';
  }
  final name = folderName.replaceAll(RegExp(r'[\\/]'), '_').trim();
  return '/notes/${name.isEmpty ? 'notes' : name}$roam';
}

/// [path] as a root of the database's paths: trimmed, with slashes for
/// backslashes and without a slash at the end; null when nothing is left
/// (not set).
String? cleanRoot(String path) {
  var root = path.trim().replaceAll('\\', '/');
  while (root.endsWith('/')) {
    root = root.substring(0, root.length - 1);
  }
  return root.isEmpty ? null : root;
}

/// Keeps the graph's database up to date with the files.
///
/// An interface so the screen can be tested without a database.
abstract interface class GraphIndex {
  /// The folder (its URI) whose files the index holds, with the root of
  /// its stored paths, or null if none.
  Future<IndexedFolder?> indexedFolder();

  /// The files of [listing] that are new or changed and must be read;
  /// [root] is the root of the stored paths.
  Future<List<String>> filesToRead(indexer.Listing listing,
      {required String root});

  /// Stores what changed and returns the graph. [contents] holds the bytes
  /// of the files read; null for a file that could not be read. [folder] is
  /// the folder the files are from, and [root] the folder the stored paths
  /// start with ([databaseRoot]).
  ///
  /// With [replace], or when the index holds another folder or another
  /// root, the index is rebuilt from [contents], in one transaction. In a
  /// rebuild of the same folder and root, a file that could not be read
  /// keeps what is stored for it.
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents, {
    required String folder,
    required String root,
    bool replace = false,
  });

  /// The files whose text has the words of [query], best first (#98).
  Future<List<TextHit>> searchText(String query, {int limit = 30});
}

/// The marker kept next to the database: the indexed folder, the root of
/// the stored paths, and the parser that indexed it ([parserFingerprint]),
/// one per line.
String folderMarker(String folder, String root, [String? fingerprint]) =>
    '$folder\n$root\n${fingerprint ?? parserFingerprint()}';

/// The folder and root a marker names, if the index was made by this
/// parser; null otherwise, so that an index from an older parser is
/// rebuilt. A marker from before the root was kept (decision 160) has two
/// lines and counts as no index, so it is rebuilt once.
IndexedFolder? markedFolder(String marker, [String? fingerprint]) {
  final lines = marker.split('\n');
  if (lines.length != 3) return null;
  if (lines[2] != (fingerprint ?? parserFingerprint())) return null;
  return (folder: lines[0], root: lines[1]);
}

/// [GraphIndex] in an org-roam database in the app's private storage. The
/// work runs on another isolate, so the screen does not stutter. Calls run
/// one after another, in the order they are made.
class SqliteGraphIndex implements GraphIndex {
  const SqliteGraphIndex({this.databasePath});

  /// Where the database is; by default `org-roam.db` in the app's support
  /// folder. The indexed folder and root are kept next to it, in
  /// `org-roam.db.folder`, since org-roam's schema has no place for them.
  final String? databasePath;

  /// The end of the queue of calls, shared by all instances.
  static Future<void> _last = Future.value();

  Future<String> _path() async =>
      databasePath ?? '${(await getApplicationSupportDirectory()).path}/org-roam.db';

  /// Runs [work] after every call made before it.
  Future<T> _queued<T>(Future<T> Function() work) {
    final result = _last.then((_) => work());
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Runs [work] on another isolate with the database open with [root], and
  /// its path.
  Future<T> _run<T>(String root, T Function(RoamDatabase db, String path) work) =>
      _queued(() async {
        final path = await _path();
        return Isolate.run(() {
          final db = RoamDatabase.open(path, root: root);
          try {
            return work(db, path);
          } finally {
            db.close();
          }
        });
      });

  @override
  Future<IndexedFolder?> indexedFolder() => _queued(() async {
        final file = File('${await _path()}.folder');
        return file.existsSync() ? markedFolder(file.readAsStringSync()) : null;
      });

  @override
  Future<List<String>> filesToRead(indexer.Listing listing,
          {required String root}) =>
      _run(root, (db, _) => indexer.filesToRead(db, listing));

  @override
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents, {
    required String folder,
    required String root,
    bool replace = false,
  }) =>
      _run(root, (db, path) {
        final marker = File('$path.folder');
        // Another root is another index: its stored paths start with the
        // old root, so every file is read again and stored below the new
        // one (decision 160).
        final sameFolder =
            marker.existsSync() &&
            markedFolder(marker.readAsStringSync()) ==
                (folder: folder, root: root);
        // The marker is removed before the database changes and written
        // again after it commits. If the app stops in between, there is no
        // marker, and the next update rebuilds the whole index.
        if (!sameFolder || replace) {
          if (marker.existsSync()) marker.deleteSync();
        }
        final graph = indexer.updateIndex(db, listing, contents,
            replace: replace || !sameFolder, keepUnreadable: sameFolder);
        marker.writeAsStringSync(folderMarker(folder, root));
        return graph;
      });

  @override
  Future<List<TextHit>> searchText(String query, {int limit = 30}) =>
      // The text table keeps paths relative to roam/; no root is needed.
      _run('', (db, _) => db.searchText(query, limit: limit));
}
