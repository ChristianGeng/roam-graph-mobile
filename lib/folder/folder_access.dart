import 'package:flutter/services.dart';

import 'org_files.dart';

/// The folder the user chose.
class ChosenFolder {
  const ChosenFolder({
    required this.uri,
    required this.name,
    required this.hasAccess,
  });

  /// Android tree URI of the folder.
  final String uri;

  /// The folder's name, for display.
  final String name;

  /// False if Android no longer grants read access, for example after the
  /// user revoked it or reinstalled the app.
  final bool hasAccess;
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

  /// Shows [file] in the app [packageName], with Android's `ACTION_VIEW`
  /// (#10). False if that app is not installed.
  Future<bool> openWith(FolderFile file, String packageName);
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
  Future<bool> openWith(FolderFile file, String packageName) async =>
      await _channel.invokeMethod<bool>(
        'openWith',
        {'uri': file.uri, 'package': packageName},
      ) ??
      false;

  static ChosenFolder? _toFolder(Map<Object?, Object?>? map) {
    if (map == null) return null;
    return ChosenFolder(
      uri: map['uri']! as String,
      name: map['name']! as String,
      hasAccess: map['hasAccess']! as bool,
    );
  }
}
