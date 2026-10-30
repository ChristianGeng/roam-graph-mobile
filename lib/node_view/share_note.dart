/// Sharing a whole note, or a picture of it, with another app (#209).
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../capture/share_out.dart';
import '../folder/org_files.dart';
import 'note_images.dart';

/// How a note is shared.
enum ShareNoteKind { text, textWithImages, orgFile }

/// Asks how to share a note. Completes with the choice, or null if the
/// user cancels. The first choice is selected.
Future<ShareNoteKind?> askShareKind(BuildContext context) =>
    showDialog<ShareNoteKind>(
      context: context,
      builder: (context) => const _ShareKindDialog(),
    );

class _ShareKindDialog extends StatefulWidget {
  const _ShareKindDialog();

  @override
  State<_ShareKindDialog> createState() => _ShareKindDialogState();
}

class _ShareKindDialogState extends State<_ShareKindDialog> {
  var _kind = ShareNoteKind.text;

  static const _labels = {
    ShareNoteKind.text: 'As text',
    ShareNoteKind.textWithImages: 'As text with images',
    ShareNoteKind.orgFile: 'As Org file',
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Share note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final MapEntry(:key, :value) in _labels.entries)
              ListTile(
                key: ValueKey(key),
                contentPadding: EdgeInsets.zero,
                leading: Icon(key == _kind
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(value),
                selected: key == _kind,
                onTap: () => setState(() => _kind = key),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _kind),
            child: const Text('Share'),
          ),
        ],
      );
}

/// An Org link: its target and, if it has one, its description. A `\[` or
/// `\]` in them is escaped.
final _link = RegExp(r'\[\[((?:[^\[\]\\]|\\.)*)\](?:\[((?:[^\[\]\\]|\\.)*)\])?\]');

String _unescape(String text) =>
    text.replaceAllMapped(RegExp(r'\\([\[\]\\])'), (m) => m[1]!);

/// [org] with each link shown by its description, or by its target when it
/// has none. A zero-width space, which Org writes inside a description, is
/// dropped.
String linksAsText(String org) => org.replaceAllMapped(_link, (m) {
      final description = m[2];
      final shown = description == null || description.isEmpty
          ? m[1]!
          : description;
      return _unescape(shown).replaceAll('\u200b', '');
    });

/// Whether [line] is only a link to an image file shown in the note.
bool _isImageLine(String line) {
  final match = RegExp(r'^\s*\[\[((?:[^\[\]\\]|\\.)*)\]\]\s*$').firstMatch(line);
  if (match == null) return false;
  return RegExp(r'\.(?:png|jpe?g|gif|webp|bmp|svg)$', caseSensitive: false)
      .hasMatch(_unescape(match[1]!));
}

/// A note as readable text: [title] as the first line, then [org] without
/// its property drawers, `:ID:` lines, Org comments, `#+` keywords and
/// lines that are only an image link. A `#+caption:` stays as its text.
/// Links show their descriptions ([linksAsText]); headings, lists and
/// tables stay as they are. For a heading node ([isFile] false), the
/// heading line itself is left out: the title says it.
String noteAsText(String title, String org, {required bool isFile}) {
  final kept = <String>[];
  var inDrawer = false;
  var headingSeen = isFile;
  for (final line in const LineSplitter().convert(org)) {
    final trimmed = line.trim();
    if (inDrawer) {
      if (trimmed.toUpperCase() == ':END:') inDrawer = false;
      continue;
    }
    if (trimmed.toUpperCase() == ':PROPERTIES:') {
      inDrawer = true;
      continue;
    }
    if (!headingSeen && trimmed.isNotEmpty) {
      headingSeen = true;
      if (RegExp(r'^\*+\s').hasMatch(line)) continue;
    }
    if (RegExp(r'^\s*:ID:', caseSensitive: false).hasMatch(line)) continue;
    // An Org comment: `# ` or a lone `#`.
    if (RegExp(r'^\s*#(?:\s|$)').hasMatch(line)) continue;
    final caption =
        RegExp(r'^\s*#\+caption:\s*(.*)$', caseSensitive: false).firstMatch(line);
    if (caption != null) {
      kept.add(caption[1]!.trim());
      continue;
    }
    if (trimmed.startsWith('#+')) continue;
    if (_isImageLine(line)) continue;
    kept.add(linksAsText(line));
  }
  final body = kept.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  final head = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  return body.isEmpty ? head : '$head\n\n$body';
}

/// The text that goes with the picture that a link to [location] (as
/// written in the note) shows in [org]: its `#+caption:`, then, for an
/// infographic or a chart (#183, #184) with a data table and a source line
/// after the image, `Source: <name>, retrieved <date>`. Null if there is
/// neither.
String? imageShareText(String org, String location) {
  final lines = const LineSplitter().convert(org);
  final at = lines.indexWhere((line) => _link
      .allMatches(line)
      .any((m) => m[2] == null && _unescape(m[1]!) == location));
  if (at < 0) return null;
  // The keyword lines right above the link.
  final captions = <String>[];
  for (var i = at - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (!line.startsWith('#+')) break;
    final caption =
        RegExp(r'^#\+caption:\s*(.*)$', caseSensitive: false).firstMatch(line);
    if (caption != null) captions.insert(0, linksAsText(caption[1]!.trim()));
  }
  // The data table, then the source line, below the image.
  String? source;
  for (var i = at + 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('|')) continue;
    if (RegExp(r'^source:', caseSensitive: false).hasMatch(line)) {
      source = linksAsText(line);
    }
    break;
  }
  final parts = [
    ...captions.where((caption) => caption.isNotEmpty),
    ?source,
  ];
  return parts.isEmpty ? null : parts.join('\n');
}

/// The image files [org] shows, of the note [note] (relative to `roam/`):
/// links without a description whose target [linkedImagePath] reads as an
/// image file, once each, in order. Their bytes are read through [files];
/// [unread] counts the images that are missing or cannot be read.
Future<({List<OutFile> images, int unread})> noteImageFiles(
    NoteFiles files, String note, String org) async {
  final images = <OutFile>[];
  var unread = 0;
  final seen = <String>{};
  for (final match in _link.allMatches(org)) {
    if (match[2] != null) continue;
    final path = linkedImagePath(note, _unescape(match[1]!));
    if (path == null || !seen.add(path)) continue;
    final file = files.reaches(path) ? files.find(path) : null;
    final bytes = file == null ? null : await files.read(file);
    if (bytes == null || bytes.isEmpty) {
      unread++;
      continue;
    }
    final name = path.split('/').last;
    images.add(OutFile(name: name, mimeType: mimeTypeOf(name), bytes: bytes));
  }
  return (images: images, unread: unread);
}

/// The Org file of a note as a file to send, named after [title].
OutFile orgFileOf(String title, String org) => OutFile(
      name: '${fileNameFor(title)}.org',
      mimeType: 'text/plain',
      bytes: Uint8List.fromList(utf8.encode(org)),
    );

/// Sends the picture [file] to another app with [send]: its bytes, its MIME
/// type and [text]. Throws [StateError] if it cannot be read.
Future<void> shareImageFile(
  NoteFiles files,
  FolderFile file,
  FileSharer send, {
  String? text,
}) async {
  final bytes = await files.read(file);
  if (bytes == null || bytes.isEmpty) {
    throw StateError('Could not read ${file.path}.');
  }
  final name = file.path.split('/').last;
  await send(
    [OutFile(name: name, mimeType: mimeTypeOf(name), bytes: bytes)],
    text: text,
  );
}
