/// Text files brought into the app (#220): shared from another app on
/// Android, dropped onto the window or chosen with "Open files…" on the
/// desktop.
///
/// Pure Dart (no Flutter), like `new_node.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'new_node.dart';

/// The largest file taken: 1 MB.
const maxFileBytes = 1024 * 1024;

/// The most files taken at once.
const maxFiles = 20;

/// The file name extensions of text files, in lower case.
const textFileExtensions = ['txt', 'md', 'markdown', 'org'];

/// The MIME types of text files. Other types, such as
/// `application/octet-stream`, count when the name has one of
/// [textFileExtensions].
const textMimeTypes = {
  'text/plain',
  'text/markdown',
  'text/x-markdown',
  'text/x-org',
  'text/org',
};

/// A file as it comes in, before it is checked.
class IncomingFile {
  const IncomingFile(
    this.name, {
    this.mimeType,
    this.bytes,
    this.size,
    this.error,
    this.path,
    this.durationMs,
    this.modified,
  });

  /// Where an audio file is on this device (#221): the app's copy of a
  /// shared file, or the dropped file. Audio is read from there when it
  /// is used, not with the share.
  final String? path;

  /// The length in milliseconds, where the sending side could tell it.
  final int? durationMs;

  /// When the file was changed, where known: the recording time of a
  /// voice memo.
  final DateTime? modified;

  /// The file name, without folders.
  final String name;

  /// The MIME type the sending app gave, if any.
  final String? mimeType;

  /// The content, or its first [maxFileBytes] + 1 bytes, which show that
  /// the file is too large; null when it was not read.
  final Uint8List? bytes;

  /// The size in bytes, where it is known without reading the file.
  final int? size;

  /// Why the file could not be read.
  final String? error;
}

/// A text file that was taken.
class TextFile {
  const TextFile(this.name, this.text, {this.latin1 = false});

  /// The file name, without folders.
  final String name;

  /// The text, as in the file.
  final String text;

  /// True when the file was not UTF-8 and was read as Latin-1.
  final bool latin1;

  /// The name without its extension.
  String get baseName {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// True for an Org file, which can also be imported as it is.
  bool get isOrg => name.toLowerCase().endsWith('.org');
}

/// What [readTextFiles] found.
class TextFiles {
  const TextFiles(this.files, this.refused);

  /// The files taken, in the order they came.
  final List<TextFile> files;

  /// The files refused, each with the reason.
  final List<({String name, String reason})> refused;

  /// What the user is told: the files refused and the files read as
  /// Latin-1. Empty when there is nothing to tell.
  List<String> get notes => [
        if (refused.isNotEmpty)
          'Not taken: ${[
            for (final r in refused) '${r.name} (${r.reason})',
          ].join(', ')}.',
        for (final file in files)
          if (file.latin1)
            '${file.name} is not UTF-8; it was read as Latin-1.',
      ];
}

/// [name] without the folders in front of it.
String fileBaseName(String name) {
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  return slash < 0 ? name : name.substring(slash + 1);
}

/// True if [name] has an extension of [textFileExtensions].
bool hasTextExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 &&
      textFileExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// True if the file is taken as a text file: by its name, or by its MIME
/// type.
bool isTextFile(String name, String? mimeType) =>
    hasTextExtension(name) ||
    textMimeTypes.contains(mimeType?.split(';').first.trim().toLowerCase());

/// Checks [incoming] against the limits and reads the text of each file
/// taken: UTF-8, or Latin-1 when the bytes are not UTF-8.
TextFiles readTextFiles(List<IncomingFile> incoming) {
  final files = <TextFile>[];
  final refused = <({String name, String reason})>[];
  for (final (index, file) in incoming.indexed) {
    final name = fileBaseName(file.name);
    final bytes = file.bytes;
    final size = file.size ?? bytes?.length;
    String? reason;
    if (index >= maxFiles) {
      reason = 'more than $maxFiles files at once';
    } else if (!isTextFile(name, file.mimeType)) {
      reason = 'not a text file: .txt, .md, .markdown or .org';
    } else if (file.error case final error?) {
      reason = 'could not be read: $error';
    } else if (size != null && size > maxFileBytes) {
      reason = 'larger than 1 MB';
    } else if (bytes == null) {
      reason = 'could not be read';
    }
    if (reason != null) {
      refused.add((name: name, reason: reason));
      continue;
    }
    try {
      files.add(TextFile(name, utf8.decode(bytes!)));
    } on FormatException {
      files.add(TextFile(name, latin1.decode(bytes!), latin1: true));
    }
  }
  return TextFiles(files, refused);
}

/// [text] with Windows and old Mac line ends as `\n`.
String unixLines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

final _drawerStart =
    RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
final _idLine = RegExp(r'^[ \t]*:ID:(?:[ \t]+(.*?))?[ \t]*$', caseSensitive: false);
final _keyword = RegExp(r'^[ \t]*#\+(\w+):[ \t]*(.*?)[ \t]*$');
final _comment = RegExp(r'^[ \t]*#(?: |$)');
final _orgHeading = RegExp(r'^(\*+)\s+(.+)$');
final _markdownHeading = RegExp(r'^#{1,6}\s+(.+)$');

/// A title without the `**` of bold, in pairs.
String _cleanTitle(String text) => text
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
    .trim();

/// [lines] without `:ID:` properties, and without the drawers that are
/// empty then: a new note must not have the IDs of another note.
List<String> _withoutIds(List<String> lines) {
  final out = <String>[];
  int? drawer;
  for (final line in lines) {
    if (drawer == null && _drawerStart.hasMatch(line)) {
      drawer = out.length;
      out.add(line);
    } else if (drawer != null && _drawerEnd.hasMatch(line)) {
      if (out.length == drawer + 1) {
        out.removeLast();
      } else {
        out.add(line);
      }
      drawer = null;
    } else if (drawer != null && _idLine.hasMatch(line)) {
      continue;
    } else {
      out.add(line);
    }
  }
  return out;
}

/// The title, tags and text a text file proposes for a new note (#220).
///
/// The title is the file's title line: `#+title:` at the top, or else a
/// Markdown or Org heading as the first line. Without one, it is the file
/// name without its extension, and the whole text is the note's text.
/// `#+filetags:` at the top become the tags. The note gets new IDs, so the
/// file's `:ID:` properties are left out.
({String title, List<String> tags, String body}) proposeFromFile(
    TextFile file) {
  final lines = _withoutIds(unixLines(file.text).split('\n'));
  // The top of an Org file: blank lines, comments and keywords.
  String? title;
  var tags = <String>[];
  final kept = <String>[];
  var i = 0;
  for (; i < lines.length; i++) {
    final line = lines[i];
    // `# text` is a comment in Org, but a heading in Markdown.
    if (line.trim().isEmpty || (file.isOrg && _comment.hasMatch(line))) {
      if (line.trim().isNotEmpty) kept.add(line);
      continue;
    }
    final keyword = _keyword.firstMatch(line);
    if (keyword == null) break;
    switch (keyword[1]!.toLowerCase()) {
      case 'title':
        // Several #+title: lines are joined, as org-roam does.
        title = [?title, keyword[2]!].join(' ').trim();
      case 'filetags':
        tags = parseTags(keyword[2]!);
      default:
        kept.add(line);
    }
  }
  var rest = lines.sublist(i);
  if (title == null || title.isEmpty) {
    title = null;
    if (rest.isNotEmpty) {
      final heading = _markdownHeading.firstMatch(rest.first) ??
          _orgHeading.firstMatch(rest.first);
      if (heading != null) {
        title = _cleanTitle(heading[heading.groupCount]!);
        rest = rest.sublist(1);
      }
    }
  }
  final body = [...kept, ...rest].join('\n').trim();
  return (title: title ?? file.baseName, tags: tags, body: body);
}

/// Several files as one text (#220): each file under an Org heading with
/// its name. The file's headings go one level down, so they stay under
/// it. Its `#+title:` and `#+filetags:` lines and its IDs are left out, so
/// they do not change the new note's title, tags or IDs.
String joinFiles(List<TextFile> files) => [
      for (final file in files)
        [
          '* ${file.name}',
          for (final line in _withoutIds(unixLines(file.text).split('\n')))
            if (!_titleOrTags(line))
              _orgHeading.hasMatch(line) ? '*$line' : line,
        ].join('\n').trimRight(),
    ].join('\n\n');

bool _titleOrTags(String line) =>
    switch (_keyword.firstMatch(line)?[1]?.toLowerCase()) {
      'title' || 'filetags' => true,
      _ => false,
    };

/// The ID of an Org file's top property drawer, the file node's ID; null
/// when it has none.
String? fileNodeId(String text) {
  final lines = unixLines(text).split('\n');
  final start = _topDrawer(lines);
  if (start == null) return null;
  for (var i = start + 1; i < lines.length; i++) {
    if (_drawerEnd.hasMatch(lines[i])) break;
    final id = _idLine.firstMatch(lines[i])?[1];
    if (id != null && id.isNotEmpty) return id;
  }
  return null;
}

/// The line of the top property drawer: the first line that is not empty
/// and not a comment, if it starts a drawer.
int? _topDrawer(List<String> lines) {
  for (final (i, line) in lines.indexed) {
    if (line.trim().isEmpty || _comment.hasMatch(line)) continue;
    return _drawerStart.hasMatch(line) ? i : null;
  }
  return null;
}

/// An Org file to import as it is (#220): its text unchanged, with [newId]
/// added when it has no ID at the top, as `org-id-get-create` does at the
/// start of the file: into the top property drawer, or in a new drawer
/// above everything. Returns the file node's ID and the text.
({String id, String text}) importText(String text, String newId) {
  if (fileNodeId(text) case final id?) return (id: id, text: text);
  final newline = text.contains('\r\n') ? '\r\n' : '\n';
  final idLine = ':ID:       $newId';
  final lines = text.split(newline);
  if (_topDrawer(lines) case final start?) {
    lines.insert(start + 1, idLine);
    return (id: newId, text: lines.join(newline));
  }
  return (
    id: newId,
    text: [':PROPERTIES:', idLine, ':END:', text].join(newline),
  );
}

/// [text] as the start of a chat message (#220): marked as shared text,
/// with the file name if it came from a file, and quoted, so the question
/// that follows is apart from it.
String sharedTextMessage(String text, {String? name}) {
  final quoted = [
    for (final line in unixLines(text).trim().split('\n'))
      line.isEmpty ? '>' : '> $line',
  ].join('\n');
  return 'Shared text${name == null ? '' : ' ($name)'}:\n$quoted\n\n';
}
