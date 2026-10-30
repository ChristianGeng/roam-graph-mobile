import 'package:material_ui/material_ui.dart';

import 'ai/ai_settings.dart';
import 'ai/chat_store.dart';
import 'capture/share_inbox.dart';
import 'capture/share_out.dart';
import 'edit/note_editor.dart';
import 'folder/desktop_folder_access.dart';
import 'folder/folder_access.dart';
import 'folder/folder_screen.dart';
import 'graph/graph_index.dart';
import 'graph_view/node_memory.dart';
import 'node_view/sclang_language.dart';
import 'platform/chat_background.dart';
import 'platform/desktop.dart';
import 'settings/view_settings.dart';

/// The version the release workflow builds, passed in with
/// `--dart-define=APP_VERSION=...`. Local builds show "dev".
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Copies of pictures and files shared with other apps are only needed
  // while the other app reads them (#209).
  // Awaited, so it cannot delete a copy made by a share just after.
  await deleteShareCache();
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
    this.chatStorage = const FileChatStorage(),
    this.backgroundService,
    this.answerNotifier,
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

  /// Where the AI chats are kept (#201): the app's private storage.
  final ChatStorage chatStorage;

  /// The Android foreground service and the answer notifications (#202);
  /// by default those of the platform, none on the desktop.
  final BackgroundService? backgroundService;
  final AnswerNotifier? answerNotifier;

  @override
  Widget build(BuildContext context) {
    return AiSettingsHost(
      store: aiSettings,
      // Above the app, so every screen reads the same settings, and the
      // app reads its theme from them (#90).
      child: ChatStoreHost(
        // Also above the navigator: chats keep working when their screen
        // closes (#201).
        storage: chatStorage,
        background: backgroundService,
        notifier: answerNotifier,
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
      ),
    );
  }
}
