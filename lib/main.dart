import 'package:flutter/material.dart';

import 'folder/folder_access.dart';
import 'folder/folder_screen.dart';

/// The version the release workflow builds, passed in with
/// `--dart-define=APP_VERSION=...`. Local builds show "dev".
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

void main() {
  runApp(const RoamGraphApp());
}

class RoamGraphApp extends StatelessWidget {
  const RoamGraphApp({
    super.key,
    this.folderAccess = const PlatformFolderAccess(),
  });

  final FolderAccess folderAccess;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Roam Graph',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: FolderScreen(folderAccess: folderAccess, version: appVersion),
    );
  }
}
