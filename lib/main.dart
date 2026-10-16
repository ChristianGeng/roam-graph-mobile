import 'package:material_ui/material_ui.dart';

import 'ai/ai_settings.dart';
import 'capture/share_inbox.dart';
import 'folder/folder_access.dart';
import 'folder/folder_screen.dart';
import 'graph/graph_index.dart';
import 'graph_view/node_memory.dart';
import 'settings/view_settings.dart';

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
    this.graphIndex = const SqliteGraphIndex(),
    this.graphScreen = FolderScreen.defaultGraphScreen,
    this.shareInbox = const PlatformShareInbox(),
    this.nodeMemory = const FileNodeMemory(),
    this.aiSettings = const FileAiSettingsStore(),
    this.viewSettings = const FileViewSettingsStore(),
  });

  final FolderAccess folderAccess;
  final GraphIndex graphIndex;
  final GraphScreenBuilder graphScreen;
  final ShareInbox shareInbox;
  final NodeMemory nodeMemory;
  final AiSettingsStore aiSettings;
  final ViewSettingsStore viewSettings;

  @override
  Widget build(BuildContext context) {
    return AiSettingsHost(
      store: aiSettings,
      child: MaterialApp(
        title: 'Roam Graph',
        // Above the navigator, so every screen reads the same settings.
        builder: (context, child) =>
            ViewSettingsHost(store: viewSettings, child: child!),
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
        ),
        home: FolderScreen(
          folderAccess: folderAccess,
          version: appVersion,
          graphIndex: graphIndex,
          graphScreen: graphScreen,
          shareInbox: shareInbox,
          nodeMemory: nodeMemory,
        ),
      ),
    );
  }
}
