import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../capture/new_node.dart';
import 'ai_visibility.dart';

/// The settings of the AI features (#57): which tags hide a note from AI.
/// Kept in the app's own storage, not in the notes.
class AiSettings {
  const AiSettings({this.hiddenTags = AiVisibility.defaultHiddenTags});

  /// Tags that hide a note from AI; by default `private`.
  final List<String> hiddenTags;

  AiVisibility get visibility => AiVisibility(hiddenTags.toSet());

  AiSettings copyWith({List<String>? hiddenTags}) =>
      AiSettings(hiddenTags: hiddenTags ?? this.hiddenTags);

  Map<String, Object?> toJson() => {'hiddenTags': hiddenTags};

  /// Settings from [json]; a missing or unreadable value keeps its default.
  factory AiSettings.fromJson(Object? json) {
    const defaults = AiSettings();
    if (json is! Map) return defaults;
    final tags = json['hiddenTags'];
    return AiSettings(
      hiddenTags: tags is List
          ? [
              for (final tag in tags)
                if (tag is String && tag.isNotEmpty) tag,
            ]
          : defaults.hiddenTags,
    );
  }
}

/// Loads and saves [AiSettings]. An interface so screens can be tested
/// without files.
abstract interface class AiSettingsStore {
  Future<AiSettings> load();
  Future<void> save(AiSettings settings);
}

/// [AiSettingsStore] in the file `ai-settings.json` in the app's support
/// folder, next to the database. A file that cannot be read gives the
/// defaults, which hide `private` notes.
class FileAiSettingsStore implements AiSettingsStore {
  const FileAiSettingsStore({this.path});

  /// Where the file is; by default in the app's support folder.
  final String? path;

  Future<File> _file() async => File(
    path ?? '${(await getApplicationSupportDirectory()).path}/ai-settings.json',
  );

  @override
  Future<AiSettings> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const AiSettings();
      return AiSettings.fromJson(jsonDecode(file.readAsStringSync()));
    } on Exception {
      return const AiSettings();
    }
  }

  @override
  Future<void> save(AiSettings settings) async {
    final file = await _file();
    // Written next to the file and renamed, so a crash cannot leave half a
    // file, which would read as the defaults.
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(settings.toJson()), flush: true);
    temporary.renameSync(file.path);
  }
}

/// Gives the screens below it the AI settings, loaded from [store] at the
/// start; [AiSettingsScope.of] reads them.
class AiSettingsHost extends StatefulWidget {
  const AiSettingsHost({
    super.key,
    this.store = const FileAiSettingsStore(),
    required this.child,
  });

  final AiSettingsStore store;
  final Widget child;

  @override
  State<AiSettingsHost> createState() => _AiSettingsHostState();
}

class _AiSettingsHostState extends State<AiSettingsHost> {
  final _settings = ValueNotifier(const AiSettings());

  /// Completes when the saved settings are loaded. Until then nothing is
  /// shared and nothing is changed (see [AiSettingsScope.current]), so a
  /// note hidden by a saved tag cannot leave before the tag is known.
  late final Future<void> _loaded = () async {
    AiSettings settings;
    try {
      settings = await widget.store.load();
    } on Exception {
      settings = const AiSettings();
    }
    if (mounted) _settings.value = settings;
  }();

  @override
  void initState() {
    super.initState();
    _loaded;
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AiSettingsScope(
    settings: _settings,
    store: widget.store,
    loaded: _loaded,
    child: widget.child,
  );
}

/// The AI settings for the screens below it.
class AiSettingsScope extends InheritedNotifier<ValueNotifier<AiSettings>> {
  const AiSettingsScope({
    super.key,
    required ValueNotifier<AiSettings> settings,
    required this.store,
    required this.loaded,
    required super.child,
  }) : super(notifier: settings);

  final AiSettingsStore store;

  /// Completes when the saved settings are loaded.
  final Future<void> loaded;

  /// The settings as they are now, or the defaults where there is no
  /// scope, as in tests of a single screen. Rebuilds [context] when they
  /// change. Before sharing, use [current], which waits for the load.
  static AiSettings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AiSettingsScope>()
          ?.notifier
          ?.value ??
      const AiSettings();

  /// The settings once the saved ones are loaded; the defaults where there
  /// is no scope.
  static Future<AiSettings> current(BuildContext context) async {
    final scope = context.getInheritedWidgetOfExactType<AiSettingsScope>();
    if (scope == null) return const AiSettings();
    await scope.loaded;
    return scope.notifier!.value;
  }


  /// Saves [settings], then uses them. If saving fails, the settings in
  /// use stay as they were, and the error is thrown.
  static Future<void> change(BuildContext context, AiSettings settings) async {
    final scope = context.getInheritedWidgetOfExactType<AiSettingsScope>();
    if (scope == null) return;
    await scope.loaded;
    await scope.store.save(settings);
    scope.notifier!.value = settings;
  }
}

/// The AI settings page (#57): the tags that hide notes from AI.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const AiSettingsScreen()),
  );

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  /// Filled once the saved settings are loaded, so the field never shows
  /// the defaults over saved tags.
  TextEditingController? _tags;
  String? _problem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final settings = await AiSettingsScope.current(context);
      if (mounted) {
        setState(
          () => _tags = TextEditingController(
            text: settings.hiddenTags.join(' '),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _tags?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final tags = _tags;
    if (tags == null) return;
    final settings = AiSettingsScope.of(
      context,
    ).copyWith(hiddenTags: parseTags(tags.text));
    try {
      await AiSettingsScope.change(context, settings);
      if (mounted) Navigator.pop(context);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _problem = 'Could not save the settings: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI settings'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed: _tags == null ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_problem case final problem?)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                problem,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_tags == null)
            const Center(child: CircularProgressIndicator())
          else
            TextField(
              key: const ValueKey('hidden-tags'),
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Hidden from AI: tags',
                hintText: 'Separated by spaces or commas',
                helperText:
                    'Notes with one of these tags are never shared '
                    'with an AI, nor shown to one. Headings with one of them '
                    'are left out of the notes that are.',
                helperMaxLines: 4,
              ),
            ),
        ],
      ),
    );
  }
}
