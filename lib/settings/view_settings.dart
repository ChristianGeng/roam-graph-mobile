/// How the app shows notes (#63), kept in the app's own storage, not in
/// the notes.
///
/// The settings are a JSON file in the app's support folder, read once at
/// the start and written when they change. Screens read them through
/// [ViewSettingsScope]. Secrets, such as API keys, never go here: they
/// belong in Android's secure storage.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/ai_settings.dart';
import '../graph/graph_layout.dart';

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
  lastUsed('Last used', 'The layout chosen last in the graph\'s More menu');

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
  });

  /// The graph's share of the width on a tablet in landscape (#69): 40 %,
  /// so the note gets 60 %.
  static const defaultGraphShare = 0.4;

  /// By default [SectionsOnOpen.collapsed]: on a phone, the headings first.
  final SectionsOnOpen sectionsOnOpen;

  /// The graph's share of the width beside a note (#69), from 0 to 1.
  final double graphShare;

  /// Whether the graph is folded away beside a note (#69).
  final bool graphCollapsed;

  /// The layout the graph view starts with (#71); force-directed by
  /// default.
  final StartLayout startLayout;

  /// The layout chosen last in the graph's More menu, for
  /// [StartLayout.lastUsed].
  final LayoutKind lastLayout;

  /// Light, dark, or as Android is set (#90).
  final AppTheme theme;

  /// The layout a graph view opening now starts with.
  LayoutKind get layoutAtStart => switch (startLayout) {
        StartLayout.force => LayoutKind.force,
        StartLayout.circo => LayoutKind.circo,
        StartLayout.lastUsed => lastLayout,
      };

  ViewSettings copyWith({
    SectionsOnOpen? sectionsOnOpen,
    double? graphShare,
    bool? graphCollapsed,
    StartLayout? startLayout,
    LayoutKind? lastLayout,
    AppTheme? theme,
  }) =>
      ViewSettings(
        sectionsOnOpen: sectionsOnOpen ?? this.sectionsOnOpen,
        graphShare: graphShare ?? this.graphShare,
        graphCollapsed: graphCollapsed ?? this.graphCollapsed,
        startLayout: startLayout ?? this.startLayout,
        lastLayout: lastLayout ?? this.lastLayout,
        theme: theme ?? this.theme,
      );

  Map<String, Object?> toJson() => {
        'sectionsOnOpen': sectionsOnOpen.name,
        'graphShare': graphShare,
        'graphCollapsed': graphCollapsed,
        'startLayout': startLayout.name,
        'lastLayout': lastLayout.name,
        'theme': theme.name,
      };

  /// Settings from [json]; a missing or unknown value keeps its default.
  factory ViewSettings.fromJson(Object? json) {
    const defaults = ViewSettings();
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
      other.theme == theme;

  @override
  int get hashCode => Object.hash(sectionsOnOpen, graphShare, graphCollapsed,
      startLayout, lastLayout, theme);
}

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

  Future<File> _file() async => File(path ??
      '${(await getApplicationSupportDirectory()).path}/view-settings.json');

  @override
  Future<ViewSettings> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const ViewSettings();
      return ViewSettings.fromJson(jsonDecode(file.readAsStringSync()));
    } on Exception {
      return const ViewSettings();
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
  MemoryViewSettingsStore([this.settings = const ViewSettings()]);

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
  final _settings = ValueNotifier(const ViewSettings());

  /// The saves so far, one after the other, so the file ends with the
  /// latest choice.
  Future<void> _saves = Future.value();

  /// Counts the changes; only the latest one is applied.
  var _changes = 0;

  /// What the file holds as far as known: the settings loaded, then each
  /// one saved. Used when the latest save fails.
  ViewSettings _inFile = const ViewSettings();

  /// Whether a save succeeded; then the file is newer than what was
  /// loaded.
  var _saved = false;

  /// Completes once the settings are loaded (or a change came first),
  /// for screens that must not start with the defaults (#81).
  final _loaded = Completer<void>();

  @override
  void initState() {
    super.initState();
    () async {
      ViewSettings settings;
      try {
        settings = await widget.store.load();
      } on Exception {
        settings = const ViewSettings();
      }
      if (mounted && !_saved) {
        _inFile = settings;
        // A choice made while loading is newer than the file.
        if (_changes == 0) _settings.value = settings;
      }
      if (!_loaded.isCompleted) _loaded.complete();
    }();
  }

  /// Saves [settings] after any earlier save, then uses them, unless a
  /// newer change came meanwhile. If the latest save fails, the screen
  /// shows what the file holds, and the error is thrown.
  Future<void> _change(ViewSettings settings) {
    final change = ++_changes;
    // A change is newer than the file: screens waiting can go on.
    if (!_loaded.isCompleted) _loaded.complete();
    // Used at once, so a second change made while the first is saving
    // builds on it instead of on the file (#72 review); undone if saving
    // fails.
    if (mounted) _settings.value = settings;
    final saved = _saves
        .catchError((Object _) {})
        .then((_) => widget.store.save(settings))
        .then((_) {
      _saved = true;
      _inFile = settings;
    });
    _saves = saved;
    return saved.then((_) {}, onError: (Object error, StackTrace stack) {
      if (mounted && change == _changes) _settings.value = _inFile;
      Error.throwWithStackTrace(error, stack);
    });
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
    return scope?.notifier?.value ?? const ViewSettings();
  }

  /// Saves and applies new settings; see [change].
  final Future<void> Function(ViewSettings) onChange;

  /// The settings as they are now, or the defaults where there is no
  /// scope, as in tests of a single screen. Rebuilds [context] when they
  /// change.
  static ViewSettings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ViewSettingsScope>()
          ?.notifier
          ?.value ??
      const ViewSettings();

  /// Saves [settings], then uses them. Changes are saved in the order they
  /// are made, and only the latest is used, so a slow earlier save cannot
  /// bring back an older choice. If saving fails, the settings in use stay
  /// as they were, and the error is thrown.
  /// The settings, without rebuilding [context] when they change: for
  /// code outside build, such as a screen's start.
  static ViewSettings read(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<ViewSettingsScope>()
          ?.notifier
          ?.value ??
      const ViewSettings();

  static Future<void> change(BuildContext context, ViewSettings settings) async {
    final scope = context.getInheritedWidgetOfExactType<ViewSettingsScope>();
    if (scope == null) return;
    await scope.onChange(settings);
  }
}

/// The settings page: for now, how far sections are open when a note
/// opens.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );

  Future<void> _choose(BuildContext context, SectionsOnOpen? value) async {
    if (value == null) return;
    final settings = ViewSettingsScope.of(context);
    try {
      await ViewSettingsScope.change(
          context, settings.copyWith(sectionsOnOpen: value));
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save the setting: $e')));
      }
    }
  }

  Future<void> _save(BuildContext context, ViewSettings settings) async {
    try {
      await ViewSettingsScope.change(context, settings);
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save the setting: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ViewSettingsScope.of(context);
    final current = settings.sectionsOnOpen;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Sections when a note opens'),
            subtitle: Text("A note's own #+STARTUP: line comes first, as "
                'in Emacs. Tap a heading to open or close it.'),
          ),
          RadioGroup<SectionsOnOpen>(
            groupValue: current,
            onChanged: (value) => _choose(context, value),
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
            title: Text('Graph layout at start'),
            subtitle: Text('The "More" menu still switches the layout '
                'while the graph is open.'),
          ),
          RadioGroup<StartLayout>(
            groupValue: settings.startLayout,
            onChanged: (value) {
              if (value != null) {
                _save(context, settings.copyWith(startLayout: value));
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
                  : () => _save(
                        context,
                        settings.copyWith(
                          graphShare: ViewSettings.defaultGraphShare,
                          graphCollapsed: false,
                        ),
                      ),
              child: const Text('Reset'),
            ),
          ),
          const Divider(),
          // The AI settings keep their own file, with the keys in secure
          // storage (decision 45); this is the way to them.
          ListTile(
            key: const ValueKey('settings-ai'),
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('AI'),
            subtitle: const Text('Notes hidden from AI, and the provider, '
                'model and key of the AI chat'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => AiSettingsScreen.open(context),
          ),
          const Divider(),
          const ListTile(title: Text('Theme')),
          RadioGroup<AppTheme>(
            groupValue: settings.theme,
            onChanged: (value) {
              if (value != null) {
                _save(context, settings.copyWith(theme: value));
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
        ],
      ),
    );
  }
}
