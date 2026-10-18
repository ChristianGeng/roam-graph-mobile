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

  /// Whether a file can be made in [path]: tried with an empty one.
  static bool _writable(String path) {
    final probe = File(
        '$path${Platform.pathSeparator}.roam-graph-write-test-$pid.tmp');
    try {
      probe.writeAsBytesSync(const [], flush: true);
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

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
    Future<void> walk(Directory dir, String prefix) async {
      await for (final entity in dir.list(followLinks: false)) {
        final name = _name(entity.path);
        final path = prefix.isEmpty ? name : '$prefix/$name';
        if (entity is Directory) {
          if (skippedDirectories.contains(name)) continue;
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
  Future<bool> openWith(FolderFile file, String packageName) async => false;

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

  /// Writes [bytes] to a temporary file in [dir], named as Syncthing names
  /// its own (`.syncthing.NAME.tmp`, not synced).
  Future<File> _temp(String dir, String name, List<int> bytes) async {
    final temp = File(_join(dir, '.syncthing.$name.tmp'));
    await temp.writeAsBytes(bytes, flush: true);
    return temp;
  }

  @override
  Future<String> createFile(String dir, String name, Uint8List bytes) async {
    final path = _join(dir, name);
    if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
      throw PlatformException(code: 'exists', message: '$name exists already');
    }
    File? temp;
    try {
      temp = await _temp(dir, name, bytes);
      // Checked again just before the rename, which would replace a file.
      if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
        throw PlatformException(
            code: 'exists', message: '$name exists already');
      }
      await temp.rename(path);
      return path;
    } on FileSystemException catch (e) {
      throw PlatformException(code: 'write_failed', message: e.message);
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
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
    try {
      temp = await _temp(dir, name, bytes);
      await _checkHash(uri, expected);
      // A rename over the old file: never half-written.
      await temp.rename(uri);
      return uri;
    } on FileSystemException catch (e) {
      throw PlatformException(code: 'write_failed', message: e.message);
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
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
