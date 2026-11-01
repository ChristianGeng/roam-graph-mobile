import 'package:flutter/services.dart';

import 'org_files.dart';

/// The folder the user chose.
class ChosenFolder {
  const ChosenFolder({
    required this.uri,
    required this.name,
    required this.hasAccess,
    this.canWrite = false,
  });

  /// Android tree URI of the folder.
  final String uri;

  /// The folder's name, for display.
  final String name;

  /// False if Android no longer grants read access, for example after the
  /// user revoked it or reinstalled the app.
  final bool hasAccess;

  /// True if the app may also write into the folder (v2 capture, #11). A
  /// folder chosen before v2 can only be read until it is chosen again.
  final bool canWrite;
}

/// Picks the org folder and lists its files.
///
/// An interface so the screen can be tested without Android.
abstract interface class FolderAccess {
  /// The folder chosen earlier, or null if none was ever chosen.
  Future<ChosenFolder?> savedFolder();

  /// Opens Android's folder picker. Null if the user cancelled.
  Future<ChosenFolder?> pickFolder();

  /// Every file and directory below [folder], except [skippedDirectories]
  /// and what they contain.
  Future<List<FolderFile>> listFiles(ChosenFolder folder);

  /// The bytes of each of [files], in the same order. Null for a file that
  /// could not be read.
  Future<List<Uint8List?>> readFiles(List<FolderFile> files);

  /// Shows [file] in another app, chosen in Android's app chooser
  /// (`ACTION_VIEW`, #218). The app gets read access to the file only.
  /// False if no app opens it.
  Future<bool> openElsewhere(FolderFile file);

  /// Writes [bytes] as the new file [name] in the directory with the URI
  /// [dir] (from [listFiles], or the folder's own URI), and returns the new
  /// file's URI. Never replaces a file: a [PlatformException] with the
  /// code `exists` if [name] is taken. The file appears only when it is
  /// complete (#13).
  Future<String> createFile(String dir, String name, Uint8List bytes);

  /// The URI of the directory [name] in the directory [dir], made if it is
  /// missing (#112: the folder for new images). A [PlatformException] with
  /// the code `write_failed` if it cannot be made, or `not_a_dir` if a
  /// file has the name.
  Future<String> createDirectory(String dir, String name);

  /// Replaces the file [uri], named [name] in the directory [dir], with
  /// [bytes], and returns its URI afterwards (#35). Only if the file is
  /// still the version the app read: its SHA-256 (hex) must be [expected],
  /// checked just before writing. Otherwise a [PlatformException] with the
  /// code `changed`, or `missing` if the file is gone. The new text is
  /// written to a temporary file first and renamed into place, so the file
  /// is never half-written (decision 10).
  Future<String> replaceFile(
    String dir,
    String name,
    String uri, {
    required String expected,
    required Uint8List bytes,
  });

  /// Deletes the file [uri] if its SHA-256 (hex) is still [expected]
  /// (#82, undoing a note the AI created). Otherwise a [PlatformException]
  /// with the code `changed`, or `missing` if the file is gone.
  Future<void> deleteFile(String uri, {required String expected});
}

/// [FolderAccess] through the Android code in `FolderAccess.kt`.
class PlatformFolderAccess implements FolderAccess {
  const PlatformFolderAccess();

  static const _channel = MethodChannel('roam_graph/folder');

  @override
  Future<ChosenFolder?> savedFolder() => _folderFrom('savedFolder');

  @override
  Future<ChosenFolder?> pickFolder() => _folderFrom('pickFolder');

  static Future<ChosenFolder?> _folderFrom(String method) async =>
      _toFolder(await _channel.invokeMapMethod<Object?, Object?>(method));

  @override
  Future<List<FolderFile>> listFiles(ChosenFolder folder) async {
    final entries = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listFiles',
      {'uri': folder.uri, 'skipDirs': skippedDirectories.toList()},
    );
    return [
      for (final e in entries ?? const <Map<Object?, Object?>>[])
        FolderFile(
          path: e['path']! as String,
          uri: e['uri']! as String,
          isDirectory: (e['directory'] as bool?) ?? false,
          modified: (e['modified'] as int?) ?? 0,
          size: (e['size'] as int?) ?? 0,
        ),
    ];
  }

  @override
  Future<List<Uint8List?>> readFiles(List<FolderFile> files) async {
    final contents = await _channel.invokeListMethod<Uint8List?>(
      'readFiles',
      {'uris': [for (final file in files) file.uri]},
    );
    return contents ?? List.filled(files.length, null);
  }

  @override
  Future<bool> openElsewhere(FolderFile file) async =>
      await _channel.invokeMethod<bool>(
        'openElsewhere',
        {'uri': file.uri},
      ) ??
      false;

  @override
  Future<String> createDirectory(String dir, String name) async =>
      (await _channel.invokeMethod<String>(
          'createDirectory', {'dir': dir, 'name': name}))!;

  @override
  Future<String> createFile(String dir, String name, Uint8List bytes) async =>
      (await _channel.invokeMethod<String>(
        'createFile',
        {'dir': dir, 'name': name, 'bytes': bytes},
      ))!;

  @override
  Future<String> replaceFile(
    String dir,
    String name,
    String uri, {
    required String expected,
    required Uint8List bytes,
  }) async =>
      (await _channel.invokeMethod<String>('replaceFile', {
        'dir': dir,
        'name': name,
        'uri': uri,
        'expected': expected,
        'bytes': bytes,
      }))!;

  @override
  Future<void> deleteFile(String uri, {required String expected}) =>
      _channel.invokeMethod<bool>(
          'deleteFile', {'uri': uri, 'expected': expected});

  static ChosenFolder? _toFolder(Map<Object?, Object?>? map) {
    if (map == null) return null;
    return ChosenFolder(
      uri: map['uri']! as String,
      name: map['name']! as String,
      hasAccess: map['hasAccess']! as bool,
      canWrite: map['canWrite'] as bool? ?? false,
    );
  }
}
