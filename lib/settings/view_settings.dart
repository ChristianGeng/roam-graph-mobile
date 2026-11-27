/// How the app shows notes (#63), kept in the app's own storage, not in
/// the notes.
///
/// The settings are a JSON file in the app's support folder, read once at
/// the start and written when they change. Screens read them through
/// [ViewSettingsScope]. Secrets, such as API keys, never go here: they
/// belong in the platform's secure storage (see `SecureApiKeyStore`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/ai_settings.dart';
import '../graph/graph_index.dart' show cleanRoot;
import '../graph/graph_layout.dart';
import '../graph/roam_graph.dart';
import '../main.dart' show appVersion;
import '../node_view/scripts.dart' show ScriptMode;
import '../node_view/web_links.dart' show UrlOpener, openUrlOnDevice;
import '../platform/desktop.dart';
import '../platform/error_text.dart';
import '../platform/follow_emacs.dart';
import '../platform/update_notification.dart' show UpdateCheckerScope;
import 'about_screen.dart';
import 'keyboard_screen.dart';
import 'keys.dart';

/// How far a note's sections are open when the note opens: the values
/// Org's `#+STARTUP:` keyword has for this.
enum SectionsOnOpen {
  /// `overview`: only the top-level headings.
  collapsed('Collapsed', 'Only the top-level headings', 'overview',
      OrgVisibilityState.folded),

  /// `content`: all headings, without their text.
  headings('Headings', 'All headings, without their text', 'content',
      OrgVisibilityState.contents),

  /// `showall`: everything.
  expanded('Expanded', 'Everything, as Emacs shows it by default',
      'showall', OrgVisibilityState.subtree);

  const SectionsOnOpen(this.label, this.description, this.startup, this.state);

  final String label;
  final String description;

  /// The `#+STARTUP:` word with the same effect.
  final String startup;

  /// The state every section starts in.
  final OrgVisibilityState state;
}

/// The layout the graph view starts with (#71).
enum StartLayout {
  force('Force-directed', 'Linked notes pull together, so clusters show'),
  circo('Circular (circo)', 'As org-roam-graph draws it'),
  radial('Radial', 'The selected note in the middle, rings by distance'),
  communities('Grouped by communities', 'Each topic in its own area'),
  layered('Hierarchical (dot)',
      'Layers from top to bottom, links pointing down'),
  lastUsed('Last used', 'The layout chosen last in the graph\'s View menu');

  const StartLayout(this.label, this.description);

  final String label;
  final String description;
}

/// The app's colours (#90): as Android is set, or always light or dark.
enum AppTheme {
  system('System', 'Light or dark, as Android is set', ThemeMode.system),
  light('Light', 'Always light', ThemeMode.light),
  dark('Dark', 'Always dark', ThemeMode.dark);

  const AppTheme(this.label, this.description, this.mode);

  final String label;
  final String description;
  final ThemeMode mode;
}

/// The settings for showing notes.
class ViewSettings {
  const ViewSettings({
    this.sectionsOnOpen = SectionsOnOpen.collapsed,
    this.graphShare = defaultGraphShare,
    this.graphCollapsed = false,
    this.startLayout = StartLayout.force,
    this.lastLayout = LayoutKind.force,
    this.theme = AppTheme.system,
    this.scripts = ScriptMode.braces,
    this.joinLines = true,
    bool? swipeHeadings,
    this.imageFolder = defaultImageFolder,
    this.emacsClient = '',
    this.emacsRoamDirectory = '',
    this.followEmacs = true,
    this.checkForUpdates = true,
    this.includePreReleases = false,
    this.lastUpdateCheckTime,
    this.lastSeenVersion,
    this.keys = const KeyBindings(),
  }) : _swipeHeadings = swipeHeadings;

  /// Where new images go (#112), relative to `roam/`.
  static const defaultImageFolder = 'img';

  /// The graph's share of the width on a tablet in landscape (#69): 40 %,
  /// so the note gets 60 %.
  static const defaultGraphShare = 0.4;

  /// Creates ViewSettings with platform-specific defaults.
  factory ViewSettings.withDefaults() => ViewSettings(
    checkForUpdates: isDesktop,
  );

  /// By default [SectionsOnOpen.collapsed]: on a phone, the headings first.
  final SectionsOnOpen sectionsOnOpen;

  /// The graph's share of the width beside a note (#69), from 0 to 1.
  final double graphShare;

  /// Whether the graph is folded away beside a note (#69).
  final bool graphCollapsed;

  /// The layout the graph view starts with (#71); force-directed by
  /// default.
  final StartLayout startLayout;

  /// The layout chosen last in the graph's View menu, for
  /// [StartLayout.lastUsed].
  final LayoutKind lastLayout;

  /// Light, dark, or as Android is set (#90).
  final AppTheme theme;

  /// When `_` and `^` make a subscript or superscript (#213); only with
  /// braces by default, as Org's `^:{}`.
  final ScriptMode scripts;

  /// Whether a single line break inside a paragraph shows as a space, so
  /// filled paragraphs wrap at the screen's width (#219); on by default.
  final bool joinLines;

  /// Whether a swipe on a heading changes its TODO state or deletes it
  /// (#217), as the user set it; null for the platform's default.
  final bool? _swipeHeadings;

  /// Whether a swipe on a heading acts (#217): on by default on Android,
  /// off on the desktop, where a mouse drag selects text.
  bool get swipeHeadings => _swipeHeadings ?? !isDesktop;

  /// The folder for images the AI makes (#112), relative to `roam/`, as
  /// [cleanImageFolder] gives it.
  final String imageFolder;

  /// The command that opens a note in Emacs on the desktop (#116), as set;
  /// empty for the system's default, see [emacsCommand].
  final String emacsClient;

  /// "Notes folder on the computer with Emacs" (#303): `org-roam-directory`
  /// there, the folder the paths in the app's database start with, so they
  /// match org-roam's own database and the MCP tools. Empty when not set;
  /// see [databaseRoot] for what is used then.
  final String emacsRoamDirectory;

  /// Whether the graph follows the node at point in Emacs on the desktop
  /// (#117); on by default. Emacs sends nothing unless
  /// `roam-graph-follow-mode` is on there.
  final bool followEmacs;

  /// Whether to check for updates on start (#247); on by default on the
  /// desktop.
  final bool checkForUpdates;

  /// Whether to include pre-releases when checking for updates (#247);
  /// off by default.
  final bool includePreReleases;

  /// The last time an update check was performed (#247).
  final DateTime? lastUpdateCheckTime;

  /// The last seen version from an update check (#247).
  final String? lastSeenVersion;

  /// The desktop's keys (#256): a set and the keys changed from it.
  final KeyBindings keys;

  /// The command to run: [emacsClient], or [defaultEmacsClient].
  String get emacsCommand =>
      emacsClient.trim().isEmpty ? defaultEmacsClient : emacsClient.trim();

  /// The layout a graph view opening now starts with.
  LayoutKind get layoutAtStart => switch (startLayout) {
        StartLayout.force => LayoutKind.force,
        StartLayout.circo => LayoutKind.circo,
        StartLayout.radial => LayoutKind.radial,
        StartLayout.communities => LayoutKind.communities,
        StartLayout.layered => LayoutKind.layered,
        StartLayout.lastUsed => lastLayout,
      };

  /// These settings with the given fields changed.
  ViewSettings copyWith({
    SectionsOnOpen? sectionsOnOpen,
    double? graphShare,
    bool? graphCollapsed,
    StartLayout? startLayout,
    LayoutKind? lastLayout,
    AppTheme? theme,
    ScriptMode? scripts,
    bool? joinLines,
    bool? swipeHeadings,
    String? imageFolder,
    String? emacsClient,
    String? emacsRoamDirectory,
    bool? followEmacs,
    bool? checkForUpdates,
    bool? includePreReleases,
    DateTime? lastUpdateCheckTime,
    String? lastSeenVersion,
    KeyBindings? keys,
  }) =>
      ViewSettings(
        sectionsOnOpen: sectionsOnOpen ?? this.sectionsOnOpen,
        graphShare: graphShare ?? this.graphShare,
        graphCollapsed: graphCollapsed ?? this.graphCollapsed,
        startLayout: startLayout ?? this.startLayout,
        lastLayout: lastLayout ?? this.lastLayout,
        theme: theme ?? this.theme,
        scripts: scripts ?? this.scripts,
        joinLines: joinLines ?? this.joinLines,
        swipeHeadings: swipeHeadings ?? _swipeHeadings,
        imageFolder: imageFolder ?? this.imageFolder,
        emacsClient: emacsClient ?? this.emacsClient,
        emacsRoamDirectory: emacsRoamDirectory ?? this.emacsRoamDirectory,
        followEmacs: followEmacs ?? this.followEmacs,
        checkForUpdates: checkForUpdates ?? this.checkForUpdates,
        includePreReleases: includePreReleases ?? this.includePreReleases,
        lastUpdateCheckTime: lastUpdateCheckTime ?? this.lastUpdateCheckTime,
        lastSeenVersion: lastSeenVersion ?? this.lastSeenVersion,
        keys: keys ?? this.keys,
      );

  Map<String, Object?> toJson() => {
        'sectionsOnOpen': sectionsOnOpen.name,
        'graphShare': graphShare,
        'graphCollapsed': graphCollapsed,
        'startLayout': startLayout.name,
        'lastLayout': lastLayout.name,
        'theme': theme.name,
        'scripts': scripts.name,
        'joinLines': joinLines,
        'swipeHeadings': ?_swipeHeadings,
        'imageFolder': imageFolder,
        'emacsClient': emacsClient,
        'emacsRoamDirectory': emacsRoamDirectory,
        'followEmacs': followEmacs,
        'checkForUpdates': checkForUpdates,
        'includePreReleases': includePreReleases,
        'lastUpdateCheckTime': lastUpdateCheckTime?.toIso8601String(),
        'lastSeenVersion': lastSeenVersion,
        'keys': keys.toJson(),
      };

  /// Settings from [json]; a missing or unknown value keeps its default
  /// (the platform default for "Check for updates", on Android off, #247).
  factory ViewSettings.fromJson(Object? json) {
    final defaults = ViewSettings.withDefaults();
    if (json is! Map) return defaults;
    final sections = json['sectionsOnOpen'];
    final share = json['graphShare'];
    return ViewSettings(
      sectionsOnOpen: SectionsOnOpen.values
              .where((value) => value.name == sections)
              .firstOrNull ??
          defaults.sectionsOnOpen,
      graphShare: share is num && share > 0 && share < 1
          ? share.toDouble()
          : defaults.graphShare,
      graphCollapsed: json['graphCollapsed'] == true,
      startLayout: StartLayout.values
              .where((value) => value.name == json['startLayout'])
              .firstOrNull ??
          defaults.startLayout,
      lastLayout: LayoutKind.values
              .where((value) => value.name == json['lastLayout'])
              .firstOrNull ??
          defaults.lastLayout,
      theme: AppTheme.values
              .where((value) => value.name == json['theme'])
              .firstOrNull ??
          defaults.theme,
      scripts: ScriptMode.values
              .where((value) => value.name == json['scripts'])
              .firstOrNull ??
          defaults.scripts,
      joinLines: switch (json['joinLines']) {
        final bool join => join,
        _ => defaults.joinLines,
      },
      swipeHeadings: switch (json['swipeHeadings']) {
        final bool swipe => swipe,
        _ => null,
      },
      imageFolder: switch (json['imageFolder']) {
        final String folder => cleanImageFolder(folder) ?? defaults.imageFolder,
        _ => defaults.imageFolder,
      },
      emacsClient: switch (json['emacsClient']) {
        final String command => command,
        _ => defaults.emacsClient,
      },
      emacsRoamDirectory: switch (json['emacsRoamDirectory']) {
        final String folder => cleanRoot(folder) ?? '',
        _ => defaults.emacsRoamDirectory,
      },
      followEmacs: switch (json['followEmacs']) {
        final bool follow => follow,
        _ => defaults.followEmacs,
      },
      checkForUpdates: switch (json['checkForUpdates']) {
        final bool check => check,
        _ => defaults.checkForUpdates,
      },
      includePreReleases: switch (json['includePreReleases']) {
        final bool include => include,
        _ => defaults.includePreReleases,
      },
      lastUpdateCheckTime: switch (json['lastUpdateCheckTime']) {
        // A bad saved time falls back for this field only, not for every
        // setting (#268).
        final String time =>
          DateTime.tryParse(time) ?? defaults.lastUpdateCheckTime,
        _ => defaults.lastUpdateCheckTime,
      },
      lastSeenVersion: switch (json['lastSeenVersion']) {
        final String version => version,
        _ => defaults.lastSeenVersion,
      },
      keys: KeyBindings.fromJson(json['keys']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewSettings &&
      other.sectionsOnOpen == sectionsOnOpen &&
      other.graphShare == graphShare &&
      other.graphCollapsed == graphCollapsed &&
      other.startLayout == startLayout &&
      other.lastLayout == lastLayout &&
      other.theme == theme &&
      other.scripts == scripts &&
      other.joinLines == joinLines &&
      other._swipeHeadings == _swipeHeadings &&
      other.imageFolder == imageFolder &&
      other.emacsClient == emacsClient &&
      other.emacsRoamDirectory == emacsRoamDirectory &&
      other.followEmacs == followEmacs &&
      other.checkForUpdates == checkForUpdates &&
      other.includePreReleases == includePreReleases &&
      other.keys == keys;

  @override
  int get hashCode => Object.hash(sectionsOnOpen, graphShare, graphCollapsed,
      startLayout, lastLayout, theme, scripts, joinLines, _swipeHeadings,
      imageFolder, emacsClient, emacsRoamDirectory, followEmacs,
      checkForUpdates, includePreReleases, keys);
}

/// [folder] as a folder inside `roam/`: slashes at the ends and doubled
/// ones go, `.` parts go; null for an empty folder, one that leaves
/// `roam/` (`..`), or a part Android cannot name (`\`, `:`, …). `roam/`
/// itself is written `.`.
String? cleanImageFolder(String folder) {
  final parts = [
    for (final part in folder.trim().split('/'))
      if (part.isNotEmpty && part != '.') part,
  ];
  if (folder.trim() == '.') return '.';
  if (parts.isEmpty) return null;
  for (final part in parts) {
    // Also no brackets: they end an Org link.
    if (part == '..' || RegExp(r'[\\:*?"<>|\[\]]').hasMatch(part) ||
        part.startsWith('.')) {
      return null;
    }
  }
  return parts.join('/');
}

/// A change to the view settings, for [ViewSettingsScope.change]: gets the
/// settings it is made on and gives them back with what it sets changed,
/// usually with [ViewSettings.copyWith].
typedef ViewSettingsChange = ViewSettings Function(ViewSettings settings);

/// Loads and saves [ViewSettings]. An interface so screens can be tested
/// without files.
abstract interface class ViewSettingsStore {
  Future<ViewSettings> load();
  Future<void> save(ViewSettings settings);
}

/// [ViewSettingsStore] in the file `view-settings.json` in the app's
/// support folder, next to the database. A file that cannot be read gives
/// the defaults.
class FileViewSettingsStore implements ViewSettingsStore {
  const FileViewSettingsStore({this.path});

  /// Where the file is; by default in the app's support folder.
  final String? path;

  /// The file for each [path], found once: a load and a later save then
  /// go on in the order they were called, so the load reads the file
  /// before the save writes it (#310). Finding the folder takes different
  /// steps the first time, when it is created, so two separate lookups
  /// could finish the other way round.
  static final _files = <String?, Future<File>>{};

  Future<File> _file() {
    final key = path;
    return _files[key] ??= () async {
      try {
        if (key != null) return File(key);
        final folder = await getApplicationSupportDirectory();
        return File('${folder.path}/view-settings.json');
      } catch (_) {
        // Tried again next time.
        _files.remove(key);
        rethrow;
      }
    }();
  }

  @override
  Future<ViewSettings> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return ViewSettings.withDefaults();
      return ViewSettings.fromJson(jsonDecode(file.readAsStringSync()));
    } on Exception {
      return ViewSettings.withDefaults();
    }
  }

  @override
  Future<void> save(ViewSettings settings) async {
    final file = await _file();
    // Written next to the file and renamed, so a crash cannot leave half a
    // file, which would read as the defaults.
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(settings.toJson()), flush: true);
    temporary.renameSync(file.path);
  }
}

/// [ViewSettingsStore] in memory, for tests.
class MemoryViewSettingsStore implements ViewSettingsStore {
  MemoryViewSettingsStore([ViewSettings? settings])
      : settings = settings ?? ViewSettings.withDefaults();

  ViewSettings settings;

  @override
  Future<ViewSettings> load() async => settings;

  @override
  Future<void> save(ViewSettings settings) async => this.settings = settings;
}

/// Gives the screens below it the view settings, loaded from [store] at
/// the start; [ViewSettingsScope.of] reads them.
class ViewSettingsHost extends StatefulWidget {
  const ViewSettingsHost({
    super.key,
    this.store = const FileViewSettingsStore(),
    required this.child,
  });

  final ViewSettingsStore store;
  final Widget child;

  @override
  State<ViewSettingsHost> createState() => _ViewSettingsHostState();
}

class _ViewSettingsHostState extends State<ViewSettingsHost> {
  late final _settings = _SettingsNotifier(ViewSettings.withDefaults());

  /// The reading of the file, then the saves, one after the other: nothing
  /// is written before the file is read (#315), and the file ends with the
  /// latest choice.
  late Future<void> _saves;

  /// Counts the changes; a failed save is undone only for the latest one.
  var _changes = 0;

  /// What the file holds as far as known: the settings read, then each one
  /// saved. Shown when the latest save fails.
  late ViewSettings _inFile = ViewSettings.withDefaults();

  /// The changes made before the file was read, in order; null once it is
  /// read.
  List<_EarlyChange>? _early = [];

  /// Completes once the settings are loaded (or a change came first),
  /// for screens that must not start with the defaults (#81).
  final _loaded = Completer<void>();

  @override
  void initState() {
    super.initState();
    _saves = _read();
  }

  /// Reads the file, then makes the changes made meanwhile on its
  /// settings, so its other settings stay (#310). A file that cannot be
  /// read gives the defaults.
  Future<void> _read() async {
    ViewSettings settings;
    try {
      settings = await widget.store.load();
    } catch (error, stack) {
      // Also an Error, since the saves wait for this read; it is a mistake
      // in the code, so it is logged.
      if (error is! Exception) {
        debugPrint('Reading the view settings failed: $error\n$stack');
      }
      settings = ViewSettings.withDefaults();
    }
    _inFile = settings;
    // Also when the screens are gone: the changes are still to be saved.
    for (final early in _early!) {
      settings = early.makeOn(settings);
    }
    _early = null;
    if (mounted) _settings.value = settings;
    if (!_loaded.isCompleted) _loaded.complete();
  }

  /// Makes [update] on the settings shown and uses the result at once, then
  /// saves it, after the read and any earlier save. If the latest save
  /// fails, the screen shows what the file holds, and the error is thrown.
  Future<void> _change(ViewSettingsChange update) async {
    // First: a change that throws changes nothing.
    final settings = update(_settings.value);
    final change = ++_changes;
    // Before the file is read, [settings] are built on the defaults: what
    // is saved is [update] made on the file's settings (#315).
    final early = _early == null ? null : _EarlyChange(update);
    if (early != null) _early!.add(early);
    // A change is newer than the file: screens waiting can go on.
    if (!_loaded.isCompleted) _loaded.complete();
    final saved = _saves.catchError((Object _) {}).then((_) async {
      final next = early == null ? settings : early.toSave();
      await widget.store.save(next);
      _inFile = next;
    });
    _saves = saved;
    // Used at once, so a second change made while the first is saving
    // builds on it instead of on the file (#72 review); undone if saving
    // fails. After the save is queued: a change made by a listener is then
    // saved after this one.
    if (mounted) _settings.value = settings;
    try {
      await saved;
    } catch (_) {
      if (mounted && change == _changes) _settings.value = _inFile;
      rethrow;
    }
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ViewSettingsScope(
        settings: _settings,
        onChange: _change,
        loaded: _loaded.future,
        child: widget.child,
      );
}

/// A change made before the settings file was read (#315).
class _EarlyChange {
  _EarlyChange(this._update);

  final ViewSettingsChange _update;

  /// Gives the settings to save for this change, or throws what the change
  /// threw on the file's settings. Set by [makeOn].
  late final ViewSettings Function() toSave;

  /// [file] with this change made; [file] as it is when the change throws
  /// on it, as a key does that another action has in the file.
  ViewSettings makeOn(ViewSettings file) {
    try {
      final made = _update(file);
      toSave = () => made;
      return made;
    } catch (error, stack) {
      toSave = () => Error.throwWithStackTrace(error, stack);
      return file;
    }
  }
}

/// A [ValueNotifier] that keeps every new settings object, also one that
/// [ViewSettings.==] calls equal, such as one with another
/// `lastUpdateCheckTime` (#310). It notifies when anything saved differs
/// (the JSON), also in those fields, so screens rebuild and their
/// callbacks copy the new settings; not when nothing saved changed.
class _SettingsNotifier extends ValueNotifier<ViewSettings> {
  _SettingsNotifier(super.value) : _current = value;

  /// The settings, kept here: [ValueNotifier]'s own field can only be set
  /// through its setter, which skips a value `==` calls equal. That field
  /// keeps the first settings and is not read.
  ViewSettings _current;

  @override
  ViewSettings get value => _current;

  @override
  set value(ViewSettings settings) {
    if (identical(settings, _current)) return;
    final differs = settings != _current ||
        jsonEncode(settings.toJson()) != jsonEncode(_current.toJson());
    _current = settings;
    if (differs) notifyListeners();
  }
}

/// The view settings for the screens below it.
class ViewSettingsScope extends InheritedNotifier<ValueNotifier<ViewSettings>> {
  const ViewSettingsScope({
    super.key,
    required ValueNotifier<ViewSettings> settings,
    required this.onChange,
    this.loaded,
    required super.child,
  }) : super(notifier: settings);

  /// Completes once the settings are loaded.
  final Future<void>? loaded;

  /// The settings once they are loaded from the file, for code that runs
  /// at a screen's start: [read] alone may still give the defaults then.
  ///
  /// Waits at most [limit]: a file that cannot be read in that time must
  /// not keep a screen from starting; it then starts with the settings as
  /// they are.
  static Future<ViewSettings> current(BuildContext context,
      {Duration limit = const Duration(seconds: 1)}) async {
    final scope = context.getInheritedWidgetOfExactType<ViewSettingsScope>();
    final loaded = scope?.loaded;
    if (loaded != null) {
      await loaded.timeout(limit, onTimeout: () {});
    }
    return scope?.notifier?.value ?? ViewSettings.withDefaults();
  }

  /// Applies and saves a change; see [change].
  final Future<void> Function(ViewSettingsChange) onChange;

  /// The settings as they are now, or the defaults where there is no
  /// scope, as in tests of a single screen. Rebuilds [context] when they
  /// change.
  static ViewSettings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ViewSettingsScope>()
          ?.notifier
          ?.value ??
      ViewSettings.withDefaults();

  /// The settings in use, without rebuilding [context] when they change:
  /// for code outside build. Until the file is read, these are the
  /// defaults, with the changes made meanwhile; [current] waits for the
  /// file (but not past a change, nor longer than its limit). To change
  /// settings, give [change] a function; do not build them from these.
  static ViewSettings read(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<ViewSettingsScope>()
          ?.notifier
          ?.value ??
      ViewSettings.withDefaults();

  /// Makes [update] on the settings as they are now, uses the result at
  /// once, then saves it. [update] sets only what the caller chose, as
  /// `change(context, (s) => s.copyWith(theme: theme))`, so a screen that
  /// waited for something, such as a dialog, keeps what changed meanwhile
  /// (#315). Changes are saved in the order they are made, so a slow
  /// earlier save cannot bring back an older choice. If the latest save
  /// fails, the settings go back to what the file holds, and the error is
  /// thrown.
  ///
  /// Before the file is read, nothing is written. [update] is made on the
  /// settings shown (the defaults, with earlier changes), and once more on
  /// the file's settings when they are read; those are then shown and
  /// saved, so the file's other settings stay (#310). So [update] may be
  /// called twice, and must use only its argument and values taken before.
  /// What it throws, such as [KeyTaken], is thrown here and nothing is
  /// saved; thrown only on the file's settings, it is handled as a failed
  /// save.
  static Future<void> change(
      BuildContext context, ViewSettingsChange update) async {
    final scope = context.getInheritedWidgetOfExactType<ViewSettingsScope>();
    if (scope == null) return;
    await scope.onChange(update);
  }
}

/// What the AI row says when the AI settings cannot be read.
const _aiSubtitleFallback = 'Notes hidden from AI, and the provider, '
    'model and key of the AI chat';

/// The AI row's subtitle: the chat provider and model of the saved AI
/// settings, such as "Mistral · mistral-large-4". Until they are loaded,
/// and where they cannot be read, it is [_aiSubtitleFallback].
class _AiSubtitle extends StatelessWidget {
  const _AiSubtitle();

  @override
  Widget build(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AiSettingsScope>();
    return FutureBuilder<void>(
      future: scope?.loaded,
      builder: (context, loading) {
        if (loading.connectionState != ConnectionState.done) {
          return const Text(_aiSubtitleFallback);
        }
        final settings = AiSettingsScope.of(context);
        final model = settings.providerSettings().defaultModel.trim();
        return Text(model.isEmpty
            ? _aiSubtitleFallback
            : '${settings.preset.name} · $model');
      },
    );
  }
}

/// Makes [update] and saves it; a failure shows in a snack bar.
Future<void> _saveSettings(
    BuildContext context, ViewSettingsChange update) async {
  try {
    await ViewSettingsScope.change(context, update);
  } on Exception catch (e) {
    if (context.mounted) {
      showErrorSnackBar(ScaffoldMessenger.of(context),
          'Could not save the setting: $e');
    }
  }
}

/// The settings page (#189): a short list with the categories AI and
/// View, and the two settings for note files (#116, #112).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    this.graph,
    this.version = appVersion,
    this.openUrl = openUrlOnDevice,
  });

  /// The graph, for the tags the AI settings offer.
  final RoamGraph? graph;

  /// The version shown in the row "About" (#207).
  final String version;

  /// Opens the link of the About page; a fake in tests.
  final UrlOpener openUrl;

  static Future<void> open(BuildContext context, {RoamGraph? graph}) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => SettingsScreen(graph: graph)),
      );

  /// The folder with `roam-graph-follow.el` that the app ships (#241).
  static String get _followElispDir => followElispDir(
      Platform.resolvedExecutable,
      macOS: Platform.isMacOS);

  /// Copies the Emacs code that loads the shipped file and turns
  /// following on (#241).
  Future<void> _copyFollowSnippet(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await copyTextOut(followEmacsSnippet(_followElispDir));
    messenger.showSnackBar(const SnackBar(
        content: Text('Copied. Paste it into your Emacs config, for Doom '
            'into config.el.')));
  }

  /// Asks for the Emacs command (#116); empty is the system's default.
  Future<void> _chooseEmacs(BuildContext context, ViewSettings settings) async {
    final field = TextEditingController(text: settings.emacsClient);
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Emacs command'),
        content: TextField(
          key: const ValueKey('emacs-field'),
          controller: field,
          autofocus: true,
          decoration: InputDecoration(
            hintText: defaultEmacsClient,
            helperText: 'emacsclient, or its full path, for example '
                '/opt/homebrew/bin/emacsclient. Emacs needs (server-start), '
                'which Doom runs.',
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('emacs-save'),
            onPressed: () => Navigator.pop(context, field.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (chosen != null && context.mounted) {
      await _saveSettings(context, (s) => s.copyWith(emacsClient: chosen));
    }
  }

  /// What "Notes folder on the computer with Emacs" uses while it is not
  /// set (#303, decision 160).
  static String get roamDirectoryDefault => isDesktop
      ? 'the notes folder on this computer'
      : '/notes/ and the name of the notes folder';

  /// Asks for the notes folder on the computer with Emacs (#303); empty is
  /// not set. Saving another value rebuilds the index, whose paths start
  /// with it.
  Future<void> _chooseRoamDirectory(
      BuildContext context, ViewSettings settings) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) =>
          _RoamDirectoryDialog(initial: settings.emacsRoamDirectory),
    );
    if (chosen != null &&
        chosen != settings.emacsRoamDirectory &&
        context.mounted) {
      await _saveSettings(
          context, (s) => s.copyWith(emacsRoamDirectory: chosen));
    }
  }

  /// Asks for the image folder; saves it when it is a folder in `roam/`.
  Future<void> _chooseImageFolder(
      BuildContext context, ViewSettings settings) async {
    final field = TextEditingController(text: settings.imageFolder);
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final clean = cleanImageFolder(field.text);
          return AlertDialog(
            title: const Text('Folder for new images'),
            content: TextField(
              key: const ValueKey('image-folder-field'),
              controller: field,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixText: 'roam/',
                helperText: 'A folder inside roam/, made if it is missing. '
                    '"." is roam/ itself.',
                errorText: clean == null ? 'Not a folder inside roam/.' : null,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                    context, ViewSettings.defaultImageFolder),
                child: const Text('Default'),
              ),
              FilledButton(
                key: const ValueKey('image-folder-save'),
                onPressed:
                    clean == null ? null : () => Navigator.pop(context, clean),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    field.dispose();
    if (chosen != null && context.mounted) {
      await _saveSettings(context, (s) => s.copyWith(imageFolder: chosen));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ViewSettingsScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // The AI settings keep their own file, with the keys in secure
          // storage (decision 45); this is the way to them.
          ListTile(
            key: const ValueKey('settings-ai'),
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('AI'),
            subtitle: const _AiSubtitle(),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => AiSettingsScreen.open(context, graph: graph),
          ),
          ListTile(
            key: const ValueKey('settings-view'),
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('View'),
            subtitle: Text(
                '${settings.theme.label} · ${settings.startLayout.label}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => ViewSettingsScreen.open(context),
          ),
          if (isDesktop)
            ListTile(
              key: const ValueKey('settings-keyboard'),
              leading: const Icon(Icons.keyboard_outlined),
              title: const Text('Keyboard'),
              subtitle: Text('${settings.keys.set.label} keys'
                  '${settings.keys.changed.isEmpty ? '' : ', ${settings.keys.changed.length} changed'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => KeyboardSettingsScreen.open(context),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Note files',
              key: const ValueKey('settings-note-files'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ),
          ListTile(
            key: const ValueKey('settings-image-folder'),
            leading: const Icon(Icons.image_outlined),
            title: const Text('Folder for new images'),
            subtitle: Text('roam/${settings.imageFolder == '.' ? '' : '${settings.imageFolder}/'}'
                ' · images the AI makes go here'),
            onTap: () => _chooseImageFolder(context, settings),
          ),
          ListTile(
            key: const ValueKey('settings-roam-directory'),
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Notes folder on the computer with Emacs'),
            subtitle: Text(
                '${settings.emacsRoamDirectory.isEmpty ? 'Not set: $roamDirectoryDefault' : settings.emacsRoamDirectory}'
                " · org-roam-directory there; note paths in the app's "
                'database start with it, to match org-roam and the MCP '
                'tools'),
            onTap: () => _chooseRoamDirectory(context, settings),
          ),
          if (isDesktop)
            ListTile(
              key: const ValueKey('settings-emacs'),
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Emacs command'),
              subtitle: Text('${settings.emacsCommand} · "Open in Emacs" runs '
                  'it with -n +LINE FILE'),
              onTap: () => _chooseEmacs(context, settings),
            ),
          if (isDesktop)
            SwitchListTile(
              key: const ValueKey('settings-follow-emacs'),
              secondary: const Icon(Icons.my_location_outlined),
              title: const Text('Follow Emacs'),
              subtitle: const Text('The graph shows the node at point in '
                  'Emacs, with roam-graph-follow-mode on there. See Help, '
                  '"The desktop app".'),
              value: settings.followEmacs,
              onChanged: (value) => _saveSettings(
                  context, (s) => s.copyWith(followEmacs: value)),
            ),
          // On Android the default is off (Obtainium is the updater
          // there), but the user can turn it on (#247).
          SwitchListTile(
            key: const ValueKey('settings-check-for-updates'),
            secondary: const Icon(Icons.system_update_outlined),
            title: const Text('Check for updates'),
            subtitle: Text(isDesktop
                ? 'On start, at most once a day, check for a newer release '
                    'on GitHub. See Help, "Update checking".'
                : 'Off by default here; Obtainium updates the app. When on, '
                    'a notice links to the release page on GitHub.'),
            value: settings.checkForUpdates,
            onChanged: (value) => _saveSettings(
                context, (s) => s.copyWith(checkForUpdates: value)),
          ),
          SwitchListTile(
            key: const ValueKey('settings-include-pre-releases'),
            secondary: const Icon(Icons.new_releases_outlined),
            title: const Text('Include pre-releases'),
            subtitle: const Text('Also check for pre-release versions when '
                'checking for updates.'),
            value: settings.includePreReleases,
            onChanged: (value) => _saveSettings(
                context, (s) => s.copyWith(includePreReleases: value)),
          ),
          if (isDesktop)
            ListTile(
              key: const ValueKey('settings-follow-emacs-snippet'),
              leading: const Icon(Icons.content_copy_outlined),
              title: const Text('Copy Emacs snippet'),
              subtitle: Text('Loads roam-graph-follow.el from '
                  '$_followElispDir, which the app ships (#241)'),
              onTap: () => _copyFollowSnippet(context),
            ),
          const Divider(),
          ListTile(
            key: const ValueKey('settings-about'),
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: Text(versionLabel(version)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => AboutScreen.open(
              context,
              version: version,
              openUrl: openUrl,
              checker: UpdateCheckerScope.maybeOf(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// The dialog of "Notes folder on the computer with Emacs" (#303). It owns
/// its text field's controller, so the controller lives as long as the
/// dialog, also while it closes. Pops the new value, empty for not set.
class _RoamDirectoryDialog extends StatefulWidget {
  const _RoamDirectoryDialog({required this.initial});

  final String initial;

  @override
  State<_RoamDirectoryDialog> createState() => _RoamDirectoryDialogState();
}

class _RoamDirectoryDialogState extends State<_RoamDirectoryDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Notes folder on the computer with Emacs'),
        content: TextField(
          key: const ValueKey('roam-directory-field'),
          controller: _field,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Not set: ${SettingsScreen.roamDirectoryDefault}',
            helperText: 'The full path of org-roam-directory there, as '
                '(expand-file-name org-roam-directory) gives it. Note paths '
                "in the app's database start with it, as in org-roam's own "
                'database. Changing it rebuilds the index.',
            helperMaxLines: 4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('roam-directory-clear'),
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Not set'),
          ),
          FilledButton(
            key: const ValueKey('roam-directory-save'),
            onPressed: () =>
                Navigator.pop(context, cleanRoot(_field.text) ?? ''),
            child: const Text('Save'),
          ),
        ],
      );
}

/// The page "View" (#189): the theme, the sections when a note opens, the
/// graph layout at start and the graph width on the tablet.
class ViewSettingsScreen extends StatelessWidget {
  const ViewSettingsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const ViewSettingsScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final settings = ViewSettingsScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('View')),
      body: ListView(
        children: [
          const ListTile(title: Text('Theme')),
          RadioGroup<AppTheme>(
            groupValue: settings.theme,
            onChanged: (value) {
              if (value != null) {
                _saveSettings(context, (s) => s.copyWith(theme: value));
              }
            },
            child: Column(
              children: [
                for (final value in AppTheme.values)
                  RadioListTile<AppTheme>(
                    key: ValueKey('theme-${value.name}'),
                    value: value,
                    title: Text(value.label),
                    subtitle: Text(value.description),
                  ),
              ],
            ),
          ),
          const Divider(),
          const ListTile(
            title: Text('Sections when a note opens'),
            subtitle: Text("A note's own #+STARTUP: line comes first, as "
                'in Emacs. Tap a heading to open or close it.'),
          ),
          RadioGroup<SectionsOnOpen>(
            groupValue: settings.sectionsOnOpen,
            onChanged: (value) {
              if (value != null) {
                _saveSettings(
                    context, (s) => s.copyWith(sectionsOnOpen: value));
              }
            },
            child: Column(
              children: [
                for (final value in SectionsOnOpen.values)
                  RadioListTile<SectionsOnOpen>(
                    key: ValueKey('sections-${value.name}'),
                    value: value,
                    title: Text(value.label),
                    subtitle: Text(value.description),
                  ),
              ],
            ),
          ),
          const Divider(),
          const ListTile(
            title: Text('Subscripts and superscripts'),
            subtitle: Text("A note's own #+OPTIONS: ^: line comes first, as "
                'in Emacs.'),
          ),
          RadioGroup<ScriptMode>(
            groupValue: settings.scripts,
            onChanged: (value) {
              if (value != null) {
                _saveSettings(context, (s) => s.copyWith(scripts: value));
              }
            },
            child: Column(
              children: [
                for (final value in ScriptMode.values)
                  RadioListTile<ScriptMode>(
                    key: ValueKey('scripts-${value.name}'),
                    value: value,
                    title: Text(value.label),
                    subtitle: Text(value.description),
                  ),
              ],
            ),
          ),
          const Divider(),
          SwitchListTile(
            key: const ValueKey('settings-join-lines'),
            title: const Text('Join lines of a paragraph'),
            subtitle: const Text('A single line break inside a paragraph '
                'shows as a space, so the text wraps at the screen width. '
                'The file keeps its line breaks.'),
            value: settings.joinLines,
            onChanged: (value) =>
                _saveSettings(context, (s) => s.copyWith(joinLines: value)),
          ),
          SwitchListTile(
            key: const ValueKey('settings-swipe-headings'),
            title: const Text('Swipe actions on headings'),
            subtitle: const Text('Swipe a heading to the right for its '
                'next TODO state, to the left to delete it. On by default '
                'on Android, off on the desktop.'),
            value: settings.swipeHeadings,
            onChanged: (value) => _saveSettings(
                context, (s) => s.copyWith(swipeHeadings: value)),
          ),
          const Divider(),
          const ListTile(
            title: Text('Graph layout at start'),
            subtitle: Text('The View menu still switches the layout '
                'while the graph is open.'),
          ),
          RadioGroup<StartLayout>(
            groupValue: settings.startLayout,
            onChanged: (value) {
              if (value != null) {
                _saveSettings(context, (s) => s.copyWith(startLayout: value));
              }
            },
            child: Column(
              children: [
                for (final value in StartLayout.values)
                  RadioListTile<StartLayout>(
                    key: ValueKey('start-layout-${value.name}'),
                    value: value,
                    title: Text(value.label),
                    subtitle: Text(value.description),
                  ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            key: const ValueKey('settings-graph-width'),
            title: const Text('Graph width on the tablet'),
            subtitle: Text(
              settings.graphCollapsed
                  ? 'The graph is folded away beside a note. Drag the '
                      'divider, or tap the strip, to change it.'
                  : 'Graph ${(settings.graphShare * 100).round()} %, note '
                      '${100 - (settings.graphShare * 100).round()} %. Drag '
                      'the divider between them to change it.',
            ),
            trailing: TextButton(
              key: const ValueKey('settings-graph-width-reset'),
              onPressed: settings.graphShare ==
                          ViewSettings.defaultGraphShare &&
                      !settings.graphCollapsed
                  ? null
                  : () => _saveSettings(
                        context,
                        (s) => s.copyWith(
                          graphShare: ViewSettings.defaultGraphShare,
                          graphCollapsed: false,
                        ),
                      ),
              child: const Text('Reset'),
            ),
          ),
        ],
      ),
    );
  }
}
