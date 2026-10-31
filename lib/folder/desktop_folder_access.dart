/// [FolderAccess] on Linux, Windows and macOS (#116): the notes folder is
/// a plain folder on disk, read and written with `dart:io`, under the same
/// rules as on Android (`FolderAccess.kt`): new files appear only when
/// complete and never replace a file; a replace or delete happens only
/// over the version read, its SHA-256 checked just before (decision 10).
///
/// A "URI" here is the absolute path.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'folder_access.dart';
import 'org_files.dart';

class DesktopFolderAccess implements FolderAccess {
  const DesktopFolderAccess({this.statePath, this.pick});

  /// The file that remembers the chosen folder; by default `folder.json`
  /// in the app's support folder.
  final String? statePath;

  /// The folder picker; tests replace it.
  final Future<String?> Function()? pick;

  Future<File> _state() async => File(statePath ??
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}folder.json');

  static String _name(String path) {
    final parts = path.split(RegExp(r'[\\/]'))..removeWhere((p) => p.isEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  static ChosenFolder _folder(String path) {
    final dir = Directory(path);
    final exists = dir.existsSync();
    return ChosenFolder(
      uri: path,
      name: _name(path),
      hasAccess: exists,
      canWrite: exists && _writable(path),
    );
  }

  /// Whether a file can be made in [path]: tried with a new, empty one,
  /// made only if no file has its name, and deleted only then.
  static bool _writable(String path) {
    final probe = File('$path${Platform.pathSeparator}'
        '.syncthing.roam-graph-write-test.$pid.${_unique()}.tmp');
    try {
      probe.createSync(exclusive: true);
    } on FileSystemException {
      return false;
    }
    try {
      probe.deleteSync();
    } on FileSystemException {
      // Made, so the folder is writable; an empty file is left.
    }
    return true;
  }

  static int _counter = 0;

  /// Unique within this process, for temporary names.
  static String _unique() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  @override
  Future<ChosenFolder?> savedFolder() async {
    try {
      final file = await _state();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      final path = json is Map ? json['path'] : null;
      return path is String && path.isNotEmpty ? _folder(path) : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<ChosenFolder?> pickFolder() async {
    final path = await (pick ?? () => getDirectoryPath(
          confirmButtonText: 'Use this folder',
        ))();
    if (path == null || path.isEmpty) return null;
    final file = await _state();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'path': path}), flush: true);
    return _folder(path);
  }

  @override
  Future<List<FolderFile>> listFiles(ChosenFolder folder) async {
    final root = Directory(folder.uri);
    if (!await root.exists()) {
      throw PlatformException(
          code: 'missing', message: '${folder.uri} is not there.');
    }
    final files = <FolderFile>[];
    // Symbolic links are followed, as org-roam's file list does (`find
    // -L`); a folder already seen is not entered again, so a loop ends.
    final seen = <String>{await root.resolveSymbolicLinks()};
    Future<void> walk(Directory dir, String prefix) async {
      await for (final entity in dir.list(followLinks: true)) {
        final name = _name(entity.path);
        final path = prefix.isEmpty ? name : '$prefix/$name';
        if (entity is Directory) {
          if (skippedDirectories.contains(name)) continue;
          String real;
          try {
            real = await entity.resolveSymbolicLinks();
          } on FileSystemException {
            continue;
          }
          if (!seen.add(real)) continue;
          files.add(FolderFile(path: path, uri: entity.path, isDirectory: true));
          await walk(entity, path);
        } else if (entity is File) {
          final stat = await entity.stat();
          files.add(FolderFile(
            path: path,
            uri: entity.path,
            modified: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          ));
        }
      }
    }

    await walk(root, '');
    return files;
  }

  @override
  Future<List<Uint8List?>> readFiles(List<FolderFile> files) async => [
        for (final file in files)
          await File(file.uri)
              .readAsBytes()
              .then<Uint8List?>((b) => b, onError: (Object _) => null),
      ];

  /// Android only: the desktop opens notes in Emacs instead.
  @override
  Future<bool> openElsewhere(FolderFile file) async => false;

  String _join(String dir, String name) =>
      '$dir${dir.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}$name';

  @override
  Future<String> createDirectory(String dir, String name) async {
    final path = _join(dir, name);
    if (await File(path).exists()) {
      throw PlatformException(
          code: 'not_a_dir', message: '$name is a file, not a folder');
    }
    try {
      await Directory(path).create();
    } on FileSystemException catch (e) {
      throw PlatformException(code: 'write_failed', message: e.message);
    }
    return path;
  }

  /// A new temporary file in [dir], named as Syncthing names its own
  /// (`.syncthing.NAME.….tmp`, not synced), unique, so two writes never
  /// share one.
  File _tempFile(String dir, String name) =>
      File(_join(dir, '.syncthing.$name.$pid.${_unique()}.tmp'));

  Future<File> _temp(String dir, String name, List<int> bytes) async {
    final temp = _tempFile(dir, name);
    await temp.create(exclusive: true);
    await temp.writeAsBytes(bytes, flush: true);
    return temp;
  }

  @override
  Future<String> createFile(String dir, String name, Uint8List bytes) async {
    final path = _join(dir, name);
    File? temp;
    var claimed = false;
    try {
      temp = await _temp(dir, name, bytes);
      // The name is claimed with an empty file that only this call can
      // make (`exclusive`): a file that is there, or one another program
      // makes meanwhile, is never replaced. Then the full file is renamed
      // over the empty one.
      try {
        await File(path).create(exclusive: true);
      } on FileSystemException {
        throw PlatformException(
            code: 'exists', message: '$name exists already');
      }
      claimed = true;
      await temp.rename(path);
      claimed = false;
      return path;
    } on FileSystemException catch (e) {
      throw PlatformException(code: 'write_failed', message: e.message);
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
      // A failed rename leaves the empty claim: it goes.
      if (claimed) {
        try {
          if (await File(path).length() == 0) await File(path).delete();
        } on FileSystemException {
          // Gone already.
        }
      }
    }
  }

  Future<void> _checkHash(String uri, String expected) async {
    final file = File(uri);
    if (!await file.exists()) {
      throw PlatformException(code: 'missing', message: '$uri is gone');
    }
    if (sha256.convert(await file.readAsBytes()).toString() != expected) {
      throw PlatformException(
          code: 'changed', message: '$uri changed since it was read');
    }
  }

  @override
  Future<String> replaceFile(
    String dir,
    String name,
    String uri, {
    required String expected,
    required Uint8List bytes,
  }) async {
    File? temp;
    File? old;
    // A note that is a symbolic link is saved where it points: the link
    // stays, and the temporary files are next to the real file, so each
    // rename stays on one file system.
    final String real;
    try {
      real = await File(uri).resolveSymbolicLinks();
    } on FileSystemException {
      throw PlatformException(code: 'missing', message: '$name is gone');
    }
    final realDir = File(real).parent.path;
    try {
      temp = await _temp(realDir, name, bytes);
      await _checkHash(real, expected);
      // As FolderAccess.kt: the old file is renamed aside first, and its
      // hash checked again there, where no editor writes. A save that
      // came between the first check and the rename is in it: then it is
      // put back, and nothing is replaced.
      old = _tempFile(realDir, '$name.old');
      await File(real).rename(old.path);
      if (sha256.convert(await old.readAsBytes()).toString() != expected) {
        await _putBack(old, real);
        old = null;
        throw PlatformException(
            code: 'changed', message: '$name changed since it was read');
      }
      if (await FileSystemEntity.type(real) != FileSystemEntityType.notFound) {
        // Written anew in the moment it was aside: that one stays.
        await old.delete();
        old = null;
        throw PlatformException(
            code: 'changed', message: '$name changed since it was read');
      }
      await temp.rename(real);
      await old.delete();
      old = null;
      return uri;
    } on FileSystemException catch (e) {
      if (old != null) await _putBack(old, real);
      old = null;
      throw PlatformException(code: 'write_failed', message: e.message);
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
    }
  }

  /// Renames [old] back to [uri], unless a file is there now.
  Future<void> _putBack(File old, String uri) async {
    if (await FileSystemEntity.type(uri) == FileSystemEntityType.notFound) {
      await old.rename(uri);
    }
  }

  @override
  Future<void> deleteFile(String uri, {required String expected}) async {
    await _checkHash(uri, expected);
    try {
      await File(uri).delete();
    } on FileSystemException catch (e) {
      throw PlatformException(code: 'write_failed', message: e.message);
    }
  }
}
