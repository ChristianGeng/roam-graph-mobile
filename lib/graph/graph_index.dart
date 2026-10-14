import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'indexer.dart' as indexer;
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
  /// the folder the files are from. With [replace], the index is rebuilt
  /// from [contents] alone, in one transaction.
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents, {
    required String folder,
    bool replace = false,
  });
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
        return file.existsSync() ? file.readAsStringSync() : null;
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
        final graph =
            indexer.updateIndex(db, listing, contents, replace: replace);
        // Written after the database commits. If the app stops in between,
        // the next start sees another folder and rebuilds, which is safe.
        File('$path.folder').writeAsStringSync(folder);
        return graph;
      });
}
