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

  /// Every file below [folder], except inside [skippedDirectories].
  Future<List<FolderFile>> listFiles(ChosenFolder folder);
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
          modified: (e['modified'] as int?) ?? 0,
          size: (e['size'] as int?) ?? 0,
        ),
    ];
  }

  static ChosenFolder? _toFolder(Map<Object?, Object?>? map) {
    if (map == null) return null;
    return ChosenFolder(
      uri: map['uri']! as String,
      name: map['name']! as String,
      hasAccess: map['hasAccess']! as bool,
    );
  }
}
