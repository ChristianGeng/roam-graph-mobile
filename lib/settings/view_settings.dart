/// How the app shows notes (#63), kept in the app's own storage, not in
/// the notes.
///
/// The settings are a JSON file in the app's support folder, read once at
/// the start and written when they change. Screens read them through
/// [ViewSettingsScope]. Secrets, such as API keys, never go here: they
/// belong in Android's secure storage.
library;

import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:path_provider/path_provider.dart';

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

/// The settings for showing notes.
class ViewSettings {
  const ViewSettings({this.sectionsOnOpen = SectionsOnOpen.collapsed});

  /// By default [SectionsOnOpen.collapsed]: on a phone, the headings first.
  final SectionsOnOpen sectionsOnOpen;

  ViewSettings copyWith({SectionsOnOpen? sectionsOnOpen}) =>
      ViewSettings(sectionsOnOpen: sectionsOnOpen ?? this.sectionsOnOpen);

  Map<String, Object?> toJson() => {'sectionsOnOpen': sectionsOnOpen.name};

  /// Settings from [json]; a missing or unknown value keeps its default.
  factory ViewSettings.fromJson(Object? json) {
    const defaults = ViewSettings();
    if (json is! Map) return defaults;
    final sections = json['sectionsOnOpen'];
    return ViewSettings(
      sectionsOnOpen: SectionsOnOpen.values
              .where((value) => value.name == sections)
              .firstOrNull ??
          defaults.sectionsOnOpen,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewSettings && other.sectionsOnOpen == sectionsOnOpen;

  @override
  int get hashCode => sectionsOnOpen.hashCode;
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
      if (mounted) _settings.value = settings;
    }();
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ViewSettingsScope(
        settings: _settings,
        store: widget.store,
        child: widget.child,
      );
}

/// The view settings for the screens below it.
class ViewSettingsScope extends InheritedNotifier<ValueNotifier<ViewSettings>> {
  const ViewSettingsScope({
    super.key,
    required ValueNotifier<ViewSettings> settings,
    required this.store,
    required super.child,
  }) : super(notifier: settings);

  final ViewSettingsStore store;

  /// The settings as they are now, or the defaults where there is no
  /// scope, as in tests of a single screen. Rebuilds [context] when they
  /// change.
  static ViewSettings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ViewSettingsScope>()
          ?.notifier
          ?.value ??
      const ViewSettings();

  /// Saves [settings], then uses them. If saving fails, the settings in
  /// use stay as they were, and the error is thrown.
  static Future<void> change(BuildContext context, ViewSettings settings) async {
    final scope = context.getInheritedWidgetOfExactType<ViewSettingsScope>();
    if (scope == null) return;
    await scope.store.save(settings);
    scope.notifier!.value = settings;
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

  @override
  Widget build(BuildContext context) {
    final current = ViewSettingsScope.of(context).sectionsOnOpen;
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
        ],
      ),
    );
  }
}
