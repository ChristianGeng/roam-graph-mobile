// Builds the app's org-roam database from a roam folder, on the laptop.
//
//   dart run tool/build_roam_db.dart [--plain-org-roam] ROAM_DIR OUT.db
//
// --plain-org-roam uses the link types of a plain Emacs with org-roam,
// with which the sample files' expected database was built (CI); without
// it, those of my Emacs, as the app does.
//
// Same code as the app, so OUT.db is what the phone stores. The stored
// paths start with ROAM_DIR as given, like org-roam's own paths. Run
// tool/org_roam_parity.py check-db to compare it with org-roam's database,
// or point the org-roam MCP server at OUT.db and run its queries.
//
// Running it again updates OUT.db: only new and changed files are read.

import 'dart:io';
import 'dart:typed_data';

import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/indexer.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_db.dart';

void main(List<String> arguments) {
  final plain = arguments.contains('--plain-org-roam');
  final args = [for (final a in arguments) if (a != '--plain-org-roam') a];
  if (args.length != 2) {
    stderr.writeln('Usage: dart run tool/build_roam_db.dart '
        '[--plain-org-roam] ROAM_DIR OUT.db');
    exit(2);
  }
  final root = Directory(args[0]).absolute;
  if (!root.existsSync()) {
    stderr.writeln('No such folder: ${root.path}');
    exit(2);
  }
  final rootPath = root.path.endsWith('/')
      ? root.path.substring(0, root.path.length - 1)
      : root.path;
  final files = <String, File>{};
  for (final entity in root.listSync(recursive: true, followLinks: true)) {
    if (entity is! File || !entity.path.startsWith('$rootPath/')) continue;
    final path = entity.path.substring(rootPath.length + 1);
    if (isRoamFile(path)) files[path] = entity;
  }
  final listing = {
    for (final MapEntry(key: path, value: file) in files.entries)
      path: file.lastModifiedSync().millisecondsSinceEpoch,
  };

  // A database made by another parser, or with the other link types, is
  // built again from all files, as the app does (graph_index.dart).
  final linkTypes = plain ? plainOrgRoamLinkTypes : defaultLinkTypes;
  final fingerprint = parserFingerprint(linkTypes);
  final marker = File('${args[1]}.parser');
  final rebuild =
      !marker.existsSync() || marker.readAsStringSync() != fingerprint;
  final db = RoamDatabase.open(args[1], root: rootPath);
  try {
    final toRead = rebuild ? listing.keys.toList() : filesToRead(db, listing);
    final contents = <String, Uint8List?>{
      for (final path in toRead) path: files[path]!.readAsBytesSync(),
    };
    final graph = updateIndex(db, listing, contents,
        replace: rebuild, linkTypes: linkTypes);
    marker.writeAsStringSync(fingerprint);
    final tables = db.dumpTables();
    stdout.writeln('Read ${toRead.length} of ${listing.length} files into '
        '${args[1]}:');
    for (final table in roamTables) {
      stdout.writeln('  ${table.padRight(10)} ${tables[table]!.length}');
    }
    if (graph.failedFiles.isNotEmpty) {
      stdout.writeln('Files org-roam skips:');
      for (final MapEntry(key: path, value: error)
          in graph.failedFiles.entries) {
        stdout.writeln('  $path: $error');
      }
    }
  } finally {
    db.close();
  }
}
