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
  /// The files of [listing] that are new or changed and must be read.
  Future<List<String>> filesToRead(indexer.Listing listing);

  /// Stores what changed and returns the graph. [contents] holds the bytes
  /// of the files read; null for a file that could not be read.
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents,
  );

  /// Forgets everything, so the next update rebuilds the index.
  Future<void> clear();
}

/// [GraphIndex] in an org-roam database in the app's private storage. The
/// work runs on another isolate, so the screen does not stutter.
class SqliteGraphIndex implements GraphIndex {
  const SqliteGraphIndex({this.databasePath, this.root = laptopRoamDirectory});

  /// Where the database is; by default `org-roam.db` in the app's support
  /// folder.
  final String? databasePath;
  final String root;

  Future<String> _path() async =>
      databasePath ?? '${(await getApplicationSupportDirectory()).path}/org-roam.db';

  Future<T> _run<T>(T Function(RoamDatabase db) work) async {
    final path = await _path();
    final root = this.root;
    return Isolate.run(() {
      final db = RoamDatabase.open(path, root: root);
      try {
        return work(db);
      } finally {
        db.close();
      }
    });
  }

  @override
  Future<List<String>> filesToRead(indexer.Listing listing) =>
      _run((db) => indexer.filesToRead(db, listing));

  @override
  Future<RoamGraph> update(
    indexer.Listing listing,
    Map<String, Uint8List?> contents,
  ) =>
      _run((db) => indexer.updateIndex(db, listing, contents));

  @override
  Future<void> clear() => _run((db) => db.clear());
}
