/// Text and text files dropped onto the window on the desktop (#220).
///
/// One [DropTarget] covers the whole window ([WindowDropTarget], in
/// main.dart). A drop goes to the newest [TextDrop] handler that takes
/// it: the chat on screen puts it into its message field, and otherwise
/// the folder screen opens the capture screen.
library;

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../capture/share_inbox.dart';
import '../capture/text_files.dart';
import 'desktop.dart';

/// Takes a drop; false if this handler does not want it now, so an older
/// one gets it.
typedef DropHandler = bool Function(Share share);

/// The handlers of drops, newest last.
abstract final class TextDrop {
  static final _handlers = <DropHandler>[];

  static void add(DropHandler handler) => _handlers.add(handler);

  static void remove(DropHandler handler) => _handlers.remove(handler);

  /// Gives [share] to the newest handler that takes it; false if none did.
  static bool deliver(Share share) {
    for (final handler in _handlers.reversed.toList()) {
      if (handler(share)) return true;
    }
    return false;
  }
}

/// Reads the files at [paths] for [readTextFiles]: the first [maxFiles]
/// text files, up to one byte more than [maxFileBytes] each, so a larger
/// file is known as one without reading all of it.
Future<SharedFiles> readLocalFiles(List<String> paths) async =>
    SharedFiles([
      for (final (index, path) in paths.indexed)
        await _readLocalFile(path, index < maxFiles),
    ]);

Future<IncomingFile> _readLocalFile(String path, bool read) async {
  final name = fileBaseName(path);
  if (!read || !hasTextExtension(name)) return IncomingFile(name);
  try {
    if (await FileSystemEntity.isDirectory(path)) {
      return IncomingFile(name, error: 'it is a folder');
    }
    final file = File(path);
    final size = await file.length();
    if (size > maxFileBytes) return IncomingFile(name, size: size);
    return IncomingFile(name, bytes: await file.readAsBytes());
  } on FileSystemException catch (e) {
    return IncomingFile(name, error: e.osError?.message ?? e.message);
  }
}

/// "Open files…" (#220): the text files the user chooses.
Future<List<String>> pickTextFilesOnDesktop() async {
  final files = await openFiles(acceptedTypeGroups: const [
    XTypeGroup(label: 'Text files', extensions: textFileExtensions),
  ]);
  return [for (final file in files) file.path];
}

/// True for a path of a file on this computer, not a URL such as
/// `https://…` that desktop_drop gives as a path on Linux.
bool _isLocalPath(String path) =>
    path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// What a drop brings: the dropped files, or, without files, the dropped
/// text. Null if it brings nothing.
Future<Share?> shareFromDrop(List<String> paths, String? rawText) async {
  final local = paths.where(_isLocalPath).toList();
  if (local.isNotEmpty) return readLocalFiles(local);
  if (rawText == null || rawText.trim().isEmpty) return null;
  return SharedText(rawText);
}

/// Takes drops onto the whole window on the desktop; elsewhere [child]
/// only.
class WindowDropTarget extends StatelessWidget {
  const WindowDropTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return child;
    return DropTarget(
      onDragDone: (details) async {
        final share = await shareFromDrop(
            [for (final file in details.files) file.path], details.rawText);
        if (share != null) TextDrop.deliver(share);
      },
      child: child,
    );
  }
}
