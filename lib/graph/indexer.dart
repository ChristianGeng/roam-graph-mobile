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

/// The files of [listing] that must be read: not stored yet, stored with a
/// different modification time, or without a modification time (0), whose
/// content can only be checked by its hash.
List<String> filesToRead(RoamDatabase db, Listing listing) {
  final stored = db.storedFiles();
  return [
    for (final MapEntry(key: path, value: mtime) in listing.entries)
      if (mtime == 0 || stored[path]?.mtime != mtime) path,
  ];
}

/// Brings the database up to [listing]. [contents] holds the bytes of the
/// files read, null for a file that could not be read; a file that cannot
/// be read keeps what is stored for it.
///
/// With [replace], what was stored before is dropped first, in the same
/// transaction: a full rebuild, which leaves the old index in place if it
/// fails. [contents] should then hold every file of [listing]. A file that
/// could not be read still keeps what is stored for it, unless
/// [keepUnreadable] is false: when the stored rows are another folder's.
///
/// Returns the graph as stored, plus the files org-roam would skip.
RoamGraph updateIndex(
  RoamDatabase db,
  Listing listing,
  Map<String, Uint8List?> contents, {
  bool replace = false,
  bool keepUnreadable = true,
  List<String> linkTypes = defaultLinkTypes,
}) {
  final failed = <RoamFileData>[];
  final duplicates = <String, List<String>>{};
  db.transaction(() {
    if (replace && !keepUnreadable) {
      db.clear();
    } else if (replace) {
      for (final path in db.storedFiles().keys) {
        final unreadable =
            contents.containsKey(path) && contents[path] == null;
        if (!unreadable) db.removeFile(path);
      }
    }
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
        linkTypes: linkTypes,
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
