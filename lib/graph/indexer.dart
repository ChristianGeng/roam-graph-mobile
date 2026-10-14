/// Keeps the org-roam database up to date with the org files (#5).
///
/// Reads only files that are new or changed: first by modification time,
/// then by content hash, as org-roam does. Pure Dart, so the laptop tools
/// use it too.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'org_roam_parser.dart';
import 'roam_db.dart';
import 'roam_graph.dart';

/// The files to index: path relative to `roam/`, and modification time in
/// milliseconds.
typedef Listing = Map<String, int>;

/// The files of [listing] that must be read: not stored yet, or stored
/// with a different modification time.
List<String> filesToRead(RoamDatabase db, Listing listing) {
  final stored = db.storedFiles();
  return [
    for (final MapEntry(key: path, value: mtime) in listing.entries)
      if (stored[path]?.mtime != mtime) path,
  ];
}

/// Brings the database up to [listing]. [contents] holds the bytes of the
/// files read, null for a file that could not be read; a file that cannot
/// be read keeps what is stored for it.
///
/// Returns the graph as stored, plus the files org-roam would skip.
RoamGraph updateIndex(
  RoamDatabase db,
  Listing listing,
  Map<String, Uint8List?> contents,
) {
  final failed = <RoamFileData>[];
  final duplicates = <String, List<String>>{};
  db.transaction(() {
    final stored = db.storedFiles();
    for (final path in stored.keys) {
      if (!listing.containsKey(path)) db.removeFile(path);
    }
    for (final MapEntry(key: path, value: bytes) in contents.entries) {
      if (bytes == null) continue;
      final mtime = listing[path] ?? 0;
      final hash = sha1.convert(bytes).toString();
      if (stored[path]?.hash == hash) {
        db.touchFile(path, mtime);
        continue;
      }
      final file = parseRoamFile(
        path,
        utf8.decode(bytes, allowMalformed: true),
        root: db.root,
      );
      if (file.error != null) {
        // org-roam stores nothing for a file it fails on.
        db.removeFile(path);
        failed.add(file);
      } else {
        final found = db.putFile(file, hash: hash, mtime: mtime);
        for (final MapEntry(key: id, value: other) in found.entries) {
          duplicates[id] = [other, path];
        }
      }
    }
  });
  // IDs used twice are reported while the files are read; the database
  // keeps only the first node, as org-roam does.
  return db.loadGraph(extra: failed, duplicateIds: duplicates);
}
