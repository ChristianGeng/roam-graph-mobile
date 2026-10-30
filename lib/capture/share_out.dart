/// Sending files to another app (#209): a picture, a note's images, a note
/// as an Org file.
///
/// On Android the app copies each file into its cache folder (`share/`) and
/// hands the copies to Android's share menu through a `FileProvider` in
/// `MainActivity.kt`. The other app gets these copies only, never the notes
/// folder. On the desktop the files are saved where the user chooses.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/desktop.dart';

/// A file to send: its [name] for the other app, its [mimeType] and its
/// content.
class OutFile {
  const OutFile({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

/// Sends [files], with [text] (a caption, for example) and a [subject], to
/// another app. Tests replace it.
typedef FileSharer = Future<void> Function(List<OutFile> files,
    {String? text, String? subject});

/// The folder of the copies, in the app's cache folder. The name is also in
/// `share_paths.xml`.
const shareCacheFolder = 'share';

/// The MIME type of an image file, or of an Org file, by its name.
String mimeTypeOf(String path) {
  final dot = path.lastIndexOf('.');
  final extension = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    'svg' => 'image/svg+xml',
    _ => 'text/plain',
  };
}

/// A file name for [title]: no characters a file system refuses, at most 80
/// characters; "note" if nothing is left.
String fileNameFor(String title) {
  var name = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.runes.length > 80) {
    name = String.fromCharCodes(name.runes.take(80)).trim();
  }
  // A name of dots only means a folder.
  return name.replaceAll('.', '').isEmpty ? 'note' : name;
}

Future<Directory> _defaultCache() async =>
    Directory('${(await getTemporaryDirectory()).path}/$shareCacheFolder');

/// Writes [files] into a new folder below [cache] (the app's cache folder
/// `share/` by default) and returns the paths, in the order of [files]. A
/// name used twice gets its position in front.
Future<List<String>> copyToShareCache(
  List<OutFile> files, {
  Directory? cache,
  DateTime Function() now = DateTime.now,
}) async {
  final root = cache ?? await _defaultCache();
  final folder = Directory('${root.path}/${now().microsecondsSinceEpoch}');
  await folder.create(recursive: true);
  final used = <String>{};
  final paths = <String>[];
  for (final (i, file) in files.indexed) {
    final name = used.add(file.name) ? file.name : '$i-${file.name}';
    final copy = File('${folder.path}/$name');
    await copy.writeAsBytes(file.bytes, flush: true);
    paths.add(copy.path);
  }
  return paths;
}

/// Deletes all copies in the cache folder `share/` (or [cache]); run when
/// the app starts. Never throws: a copy that stays is cleaned up next time.
Future<void> deleteShareCache({Directory? cache}) async {
  try {
    final root = cache ?? await _defaultCache();
    if (await root.exists()) await root.delete(recursive: true);
  } on Object {
    // Nothing to do: a failed clean-up must not stop the app.
  }
}

/// [FileSharer] through `MainActivity.kt`. On the desktop, the files are
/// saved ([saveFilesOnDesktop]).
Future<void> shareFilesOut(List<OutFile> files,
    {String? text, String? subject}) async {
  if (isDesktop) return saveFilesOnDesktop(files, text: text);
  final paths = await copyToShareCache(files);
  await const MethodChannel('roam_graph/share').invokeMethod<void>(
    'shareFiles',
    {
      'paths': paths,
      'mimeTypes': [for (final file in files) file.mimeType],
      'text': text,
      'subject': subject,
    },
  );
}

/// The desktop has no share menu: one file is saved where the platform's
/// save dialog says, several into a folder it asks for. If the system has
/// no dialog, the paths of copies in the cache folder go to the clipboard.
/// A [text] goes to the clipboard too.
Future<void> saveFilesOnDesktop(List<OutFile> files, {String? text}) async {
  if (files.isEmpty) return;
  try {
    if (files.length == 1) {
      final location = await getSaveLocation(suggestedName: files.single.name);
      if (location == null) return;
      await File(location.path).writeAsBytes(files.single.bytes);
    } else {
      final folder = await getDirectoryPath();
      if (folder == null) return;
      for (final file in files) {
        await File('$folder/${file.name}').writeAsBytes(file.bytes);
      }
    }
  } on UnimplementedError {
    final paths = await copyToShareCache(files);
    await Clipboard.setData(ClipboardData(text: paths.join('\n')));
    return;
  } on MissingPluginException {
    final paths = await copyToShareCache(files);
    await Clipboard.setData(ClipboardData(text: paths.join('\n')));
    return;
  }
  if (text != null) await Clipboard.setData(ClipboardData(text: text));
}
