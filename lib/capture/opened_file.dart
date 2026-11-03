/// Files opened with Roam Graph through Android's "Open with" (#243): an
/// Org file becomes the note it is in the notes folder, or a read-only
/// view of a file from elsewhere; a recording goes the way of a voice
/// memo (#221).
///
/// Pure Dart (no Flutter), like `text_files.dart`.
library;

import '../graph/org_roam_parser.dart';
import '../graph/roam_graph.dart';
import 'audio_info.dart';

/// What a file opened with the app is taken as.
enum OpenedKind {
  /// An Org file (`.org`, by its name).
  org,

  /// A recording, as for a shared voice memo (#221).
  audio,

  /// Neither: the app says so.
  other,
}

/// What [name] (with the MIME type the sending app gave) is opened as.
/// Org files are known by their name only, because file managers send
/// them as `text/plain` or `application/octet-stream`.
OpenedKind openedKind(String name, String? mimeType) {
  if (isAudioFile(name, mimeType)) return OpenedKind.audio;
  if (name.toLowerCase().endsWith('.org')) return OpenedKind.org;
  return OpenedKind.other;
}

/// Where an opened Org file goes.
sealed class OpenedRoute {
  const OpenedRoute();
}

/// The file is a note of the notes folder: [id] is its file node, or the
/// first of its nodes when it has no file node.
class InNotes extends OpenedRoute {
  const InNotes(this.id, this.file);

  final String id;

  /// The note's path, relative to `roam/`.
  final String file;
}

/// The file is not a note of the notes folder, or a different version of
/// one: it is shown read-only.
class OutsideNotes extends OpenedRoute {
  const OutsideNotes({this.unknownIds = false});

  /// True when the file has IDs and the index knows none of them: it may
  /// be a note that arrived after the last scan.
  final bool unknownIds;
}

/// The values of the `:ID:` properties in [text], in order.
List<String> orgIds(String text) => [
      for (final match in RegExp(r'^[ \t]*:ID:[ \t]+(\S+)[ \t]*$',
              multiLine: true, caseSensitive: false)
          .allMatches(text))
        match[1]!,
    ];

String _normalized(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

/// Decides whether the Org file [text] is a note of the notes folder.
///
/// A content URI from a file manager does not say where the file is in a
/// way the app can compare with the folder it was given, so the file is
/// matched by what is in it: an `:ID:` of the file that the index knows,
/// and the note with that ID ([readNote], relative to `roam/`) holds the
/// same text, apart from line ends and trailing white space. A copy
/// elsewhere with other text, or a file without a known ID, is
/// [OutsideNotes].
Future<OpenedRoute> routeOpenedOrg(
  RoamGraph graph,
  String text,
  Future<String?> Function(String path) readNote,
) async {
  final ids = orgIds(text);
  final wanted = _normalized(text);
  final checked = <String>{};
  var known = false;
  for (final id in ids) {
    final node = graph.nodes[id];
    if (node == null) continue;
    known = true;
    if (!checked.add(node.file)) continue;
    final there = await readNote(node.file);
    if (there == null || _normalized(there) != wanted) continue;
    final fileNode = graph.nodes.values
        .where((n) => n.file == node.file && n.level == 0)
        .firstOrNull;
    return InNotes(fileNode?.id ?? node.id, node.file);
  }
  return OutsideNotes(unknownIds: ids.isNotEmpty && !known);
}

/// The path a file opened from outside the notes folder has in its own
/// read-only graph.
String openedPath(String name) => 'opened/$name';

/// The ID of the file node made up for an opened file without one.
String openedFileId(String name) => 'opened:$name';

/// [text], the Org file [name] opened from outside the notes folder,
/// parsed as the index parses notes. A file without a file node (not an
/// org-roam note, or one with heading nodes only) gets one made up, so
/// the node view can show the whole file.
RoamFileData viewedFile(String name, String text) {
  final path = openedPath(name);
  final data = parseRoamFile(path, text);
  if (data.nodes.any((n) => n.level == 0)) return data;
  final dot = name.lastIndexOf('.');
  final title = data.title.isNotEmpty
      ? data.title
      : (dot > 0 ? name.substring(0, dot) : name);
  return RoamFileData(
    path: path,
    nodes: [
      RoamNode(
          id: openedFileId(name),
          file: path,
          level: 0,
          title: title,
          line: 1),
      ...data.nodes,
    ],
    links: data.links,
    citations: data.citations,
    title: title,
  );
}
