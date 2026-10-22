import 'package:material_ui/material_ui.dart';

import 'ai/ai_settings.dart';
import 'capture/share_inbox.dart';
import 'edit/note_editor.dart';
import 'folder/desktop_folder_access.dart';
import 'folder/folder_access.dart';
import 'folder/folder_screen.dart';
import 'graph/graph_index.dart';
import 'graph_view/node_memory.dart';
import 'node_view/sclang_language.dart';
import 'platform/desktop.dart';
import 'settings/view_settings.dart';

/// The version the release workflow builds, passed in with
/// `--dart-define=APP_VERSION=...`. Local builds show "dev".
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

void main() {
  // The app's own source-block grammar, before any note is shown (#147).
  registerSclang();
  runApp(const RoamGraphApp());
}

class RoamGraphApp extends StatelessWidget {
  const RoamGraphApp({
    super.key,
    this.folderAccess,
    this.graphIndex = const SqliteGraphIndex(),
    this.graphScreen = FolderScreen.defaultGraphScreen,
    this.shareInbox = const PlatformShareInbox(),
    this.nodeMemory = const FileNodeMemory(),
    this.aiSettings = const FileAiSettingsStore(),
    this.viewSettings = const FileViewSettingsStore(),
    this.editHistory = const FileEditHistory(),
  });

  /// The notes folder: Android's, or a plain folder on the desktop (#116).
  final FolderAccess? folderAccess;
  final GraphIndex graphIndex;
  final GraphScreenBuilder graphScreen;
  final ShareInbox shareInbox;
  final NodeMemory nodeMemory;
  final AiSettingsStore aiSettings;
  final ViewSettingsStore viewSettings;
  final EditHistory editHistory;

  @override
  Widget build(BuildContext context) {
    return AiSettingsHost(
      store: aiSettings,
      // Above the app, so every screen reads the same settings, and the
      // app reads its theme from them (#90).
      child: ViewSettingsHost(
        store: viewSettings,
        child: Builder(
          builder: (context) => MaterialApp(
            title: 'Roam Graph',
            themeMode: ViewSettingsScope.of(context).theme.mode,
            theme: ThemeData(colorSchemeSeed: Colors.indigo),
            darkTheme: ThemeData(
              colorSchemeSeed: Colors.indigo,
              brightness: Brightness.dark,
            ),
            home: FolderScreen(
              folderAccess: folderAccess ??
                  (isDesktop
                      ? const DesktopFolderAccess()
                      : const PlatformFolderAccess()),
              version: appVersion,
              graphIndex: graphIndex,
              graphScreen: graphScreen,
              shareInbox: shareInbox,
              nodeMemory: nodeMemory,
              editHistory: editHistory,
            ),
          ),
        ),
      ),
    );
  }
}
