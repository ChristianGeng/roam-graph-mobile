// Prints the graph the app's parser builds from a roam folder, as JSON.
//
//   dart run tool/roam_graph_dump.dart [--plain-org-roam] ROAM_DIR
//
// --plain-org-roam: the link types of a plain Emacs with org-roam, as for
// the sample files (CI); without it, those of my Emacs, as the app.
//
// It reads the same files the app reads (lib/folder/org_files.dart) and
// prints the format tool/org_roam_parity.py compares with an org-roam
// database. Run it with the Dart that comes with Flutter, from the repo.

import 'dart:convert';
import 'dart:io';

import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';

void main(List<String> arguments) {
  final plain = arguments.contains('--plain-org-roam');
  final args = [for (final a in arguments) if (a != '--plain-org-roam') a];
  if (args.length != 1) {
    stderr.writeln(
        'Usage: dart run tool/roam_graph_dump.dart [--plain-org-roam] ROAM_DIR');
    exit(2);
  }
  final root = Directory(args.single).absolute;
  if (!root.existsSync()) {
    stderr.writeln('No such folder: ${root.path}');
    exit(2);
  }
  final prefix = root.path.endsWith('/') ? root.path : '${root.path}/';
  final files = <RoamFileData>[];
  for (final entity in root.listSync(recursive: true, followLinks: true)) {
    if (entity is! File || !entity.path.startsWith(prefix)) continue;
    final path = entity.path.substring(prefix.length);
    if (!isRoamFile(path)) continue;
    final text = utf8.decode(entity.readAsBytesSync(), allowMalformed: true);
    files.add(parseRoamFile(path, text,
        linkTypes: plain ? plainOrgRoamLinkTypes : defaultLinkTypes));
  }
  final graph = RoamGraph.fromFiles(files);
  stdout.writeln(
    const JsonEncoder.withIndent(' ').convert(graph.toNormalizedJson()),
  );
}
