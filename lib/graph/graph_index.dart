import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'indexer.dart' as indexer;
import 'org_roam_parser.dart';
import 'roam_db.dart';
import 'roam_graph.dart';

/// org-roam's `org-roam-directory` on the laptop. The database stores
/// absolute paths below it, as org-roam does, so queries return the same
/// paths as on the laptop (decision 23).
const laptopRoamDirectory = '/home/cgeng_local/work/cgeng/org/roam';

/// Keeps the graph's database up to date with the files.
///
/// An interface so the screen can be tested without a database.
abstract interface class GraphIndex {
  /// The folder (its URI) whose files the index holds, or null if none.
  Future<String?> indexedFolder();

  /// The files of [listing] that are new or changed and must be read.
  Future<List<String>> filesToRead(indexer.Listing listing);

  /// Stores what changed and returns the graph. [contents] holds the bytes
  /// of the files read; null for a file that could not be read. [folder] is
  /// the folder the files are from.
  ///
  /// With [replace], or when the index holds another folder, the index is
  /// rebuilt from [contents], in one transaction. In a rebuild of the same
  /// folder, a file that could not be read keeps what is stored for it.
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents, {
    required String folder,
    bool replace = false,
  });

  /// The files whose text has the words of [query], best first (#98).
  Future<List<TextHit>> searchText(String query, {int limit = 30});
}

/// The marker kept next to the database: the indexed folder, and the
/// parser that indexed it ([parserFingerprint]).
String folderMarker(String folder, [String? fingerprint]) =>
    '$folder\n${fingerprint ?? parserFingerprint()}';

/// The folder a marker names, if the index was made by this parser; null
/// otherwise, so that an index from an older parser is rebuilt.
String? markedFolder(String marker, [String? fingerprint]) {
  final newline = marker.indexOf('\n');
  if (newline < 0) return null;
  if (marker.substring(newline + 1) != (fingerprint ?? parserFingerprint())) {
    return null;
  }
  return marker.substring(0, newline);
}

/// [GraphIndex] in an org-roam database in the app's private storage. The
/// work runs on another isolate, so the screen does not stutter. Calls run
/// one after another, in the order they are made.
class SqliteGraphIndex implements GraphIndex {
  const SqliteGraphIndex({this.databasePath, this.root = laptopRoamDirectory});

  /// Where the database is; by default `org-roam.db` in the app's support
  /// folder. The indexed folder is kept next to it, in `org-roam.db.folder`,
  /// since org-roam's schema has no place for it.
  final String? databasePath;
  final String root;

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

  /// Runs [work] on another isolate with the open database and its path.
  Future<T> _run<T>(T Function(RoamDatabase db, String path) work) =>
      _queued(() async {
        final path = await _path();
        final root = this.root;
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
  Future<String?> indexedFolder() => _queued(() async {
        final file = File('${await _path()}.folder');
        return file.existsSync() ? markedFolder(file.readAsStringSync()) : null;
      });

  @override
  Future<List<String>> filesToRead(indexer.Listing listing) =>
      _run((db, _) => indexer.filesToRead(db, listing));

  @override
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents, {
    required String folder,
    bool replace = false,
  }) =>
      _run((db, path) {
        final marker = File('$path.folder');
        final sameFolder =
            marker.existsSync() &&
            markedFolder(marker.readAsStringSync()) == folder;
        // The marker is removed before the database changes and written
        // again after it commits. If the app stops in between, there is no
        // marker, and the next update rebuilds the whole index.
        if (!sameFolder || replace) {
          if (marker.existsSync()) marker.deleteSync();
        }
        final graph = indexer.updateIndex(db, listing, contents,
            replace: replace || !sameFolder, keepUnreadable: sameFolder);
        marker.writeAsStringSync(folderMarker(folder));
        return graph;
      });

  @override
  Future<List<TextHit>> searchText(String query, {int limit = 30}) =>
      _run((db, _) => db.searchText(query, limit: limit));
}
