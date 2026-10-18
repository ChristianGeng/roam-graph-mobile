import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../capture/new_node.dart';
import 'ai_chat.dart';
import 'ai_images.dart';
import 'ai_models.dart';
import 'model_picker.dart';
import 'ai_providers.dart';
import 'ai_visibility.dart';

/// One provider's values (#59), where they differ from its preset
/// ([ProviderPreset]). The API key is not here: it is in [ApiKeyStore].
class ProviderSettings {
  const ProviderSettings({
    required this.api,
    required this.baseUrl,
    required this.defaultModel,
    required this.strongModel,
    this.euOnly = false,
    this.imageModel = '',
    this.imageApi = ImageApi.images,
  });

  /// The preset's values.
  factory ProviderSettings.of(ProviderPreset preset) => ProviderSettings(
        api: preset.api,
        baseUrl: preset.baseUrl,
        defaultModel: preset.defaultModel,
        strongModel: preset.strongModel,
        imageModel: preset.imageModel,
      );

  /// The model "Create image" uses (#112); empty when none is chosen.
  final String imageModel;

  /// How [imageModel] is asked.
  final ImageApi imageApi;

  /// The API; only Custom can change it.
  final ApiKind api;
  final String baseUrl;
  final String defaultModel;

  /// Empty when there is none.
  final String strongModel;

  /// Vercel AI Gateway's "EU only" switch; off by default, as its
  /// default model has no EU route.
  final bool euOnly;

  Map<String, Object?> toJson() => {
        'api': api.name,
        'baseUrl': baseUrl,
        'defaultModel': defaultModel,
        'strongModel': strongModel,
        'euOnly': euOnly,
        'imageModel': imageModel,
        'imageApi': imageApi.name,
      };

  /// [json] over [preset]'s values; what is missing or unreadable keeps
  /// the preset's value.
  factory ProviderSettings.fromJson(Object? json, ProviderPreset preset) {
    final base = ProviderSettings.of(preset);
    if (json is! Map) return base;
    String text(String key, String fallback) =>
        json[key] is String ? json[key] as String : fallback;
    return ProviderSettings(
      api: preset.id == 'custom'
          ? ApiKind.values.firstWhere((k) => k.name == json['api'],
              orElse: () => base.api)
          : preset.api,
      baseUrl: text('baseUrl', base.baseUrl),
      defaultModel: text('defaultModel', base.defaultModel),
      strongModel: text('strongModel', base.strongModel),
      euOnly: json['euOnly'] is bool ? json['euOnly'] as bool : base.euOnly,
      imageModel: text('imageModel', base.imageModel),
      imageApi: ImageApi.values.firstWhere((k) => k.name == json['imageApi'],
          orElse: () => base.imageApi),
    );
  }
}

/// "Let the AI change notes" (#82).
enum AiEditMode {
  /// The AI only reads.
  off('Off: the AI only reads'),

  /// The AI proposes edits; each is saved only after my OK (#39, #76).
  review('Review each change first'),

  /// The AI creates, edits and links notes itself; I see a summary
  /// afterwards and can undo all changes of a message.
  agent('Agent: it changes notes itself, I can undo');

  const AiEditMode(this.label);

  final String label;
}

/// The settings of the AI features: which tags hide a note from AI (#57),
/// and the provider the chat uses (#59). Kept in the app's own storage,
/// not in the notes; API keys are in [ApiKeyStore].
class AiSettings {
  const AiSettings({
    this.hiddenTags = AiVisibility.defaultHiddenTags,
    this.provider = 'anthropic',
    this.providers = const {},
    this.maxToolRounds = 10,
    this.maxOutputTokens = 8192,
    this.maxChangeSetFiles = 20,
    this.editMode = AiEditMode.agent,
    this.maxAgentChanges = 30,
  });

  /// Tags that hide a note from AI; by default `private`.
  final List<String> hiddenTags;

  /// The chosen provider's preset ID.
  final String provider;

  /// Saved values by preset ID; a provider not in it has its preset's.
  final Map<String, ProviderSettings> providers;

  /// The most tool rounds for one message.
  final int maxToolRounds;

  /// The most tokens for one answer, thinking included.
  final int maxOutputTokens;

  /// The most notes one AI change set may edit (#76).
  final int maxChangeSetFiles;

  /// How the AI may change notes (#82): not at all, through edits I
  /// review first, or on its own as an agent.
  final AiEditMode editMode;

  /// The most changes the agent may make for one message (#82).
  final int maxAgentChanges;

  AiVisibility get visibility => AiVisibility(hiddenTags.toSet());

  ProviderPreset get preset => presetById(provider);

  /// The values of the provider [id] (by default the chosen one).
  ProviderSettings providerSettings([String? id]) {
    final preset = presetById(id ?? provider);
    return providers[preset.id] ?? ProviderSettings.of(preset);
  }

  AiSettings copyWith({
    List<String>? hiddenTags,
    String? provider,
    Map<String, ProviderSettings>? providers,
    int? maxToolRounds,
    int? maxOutputTokens,
    int? maxChangeSetFiles,
    AiEditMode? editMode,
    int? maxAgentChanges,
  }) =>
      AiSettings(
        hiddenTags: hiddenTags ?? this.hiddenTags,
        provider: provider ?? this.provider,
        providers: providers ?? this.providers,
        maxToolRounds: maxToolRounds ?? this.maxToolRounds,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
        maxChangeSetFiles: maxChangeSetFiles ?? this.maxChangeSetFiles,
        editMode: editMode ?? this.editMode,
        maxAgentChanges: maxAgentChanges ?? this.maxAgentChanges,
      );

  Map<String, Object?> toJson() => {
        'hiddenTags': hiddenTags,
        'provider': provider,
        'providers': {
          for (final MapEntry(:key, :value) in providers.entries)
            key: value.toJson(),
        },
        'maxToolRounds': maxToolRounds,
        'maxOutputTokens': maxOutputTokens,
        'maxChangeSetFiles': maxChangeSetFiles,
        'editMode': editMode.name,
        'maxAgentChanges': maxAgentChanges,
      };

  /// Settings from [json]; a missing or unreadable value keeps its default.
  factory AiSettings.fromJson(Object? json) {
    const defaults = AiSettings();
    if (json is! Map) return defaults;
    final tags = json['hiddenTags'];
    final saved = json['providers'];
    int positive(String key, int fallback) =>
        json[key] is int && (json[key] as int) > 0 ? json[key] as int : fallback;
    return AiSettings(
      hiddenTags: tags is List
          ? [
              for (final tag in tags)
                if (tag is String && tag.isNotEmpty) tag,
            ]
          : defaults.hiddenTags,
      provider: json['provider'] is String
          ? presetById(json['provider'] as String).id
          : defaults.provider,
      providers: {
        if (saved is Map)
          for (final preset in providerPresets)
            if (saved.containsKey(preset.id))
              preset.id: ProviderSettings.fromJson(saved[preset.id], preset),
      },
      maxToolRounds: positive('maxToolRounds', defaults.maxToolRounds),
      maxOutputTokens: positive('maxOutputTokens', defaults.maxOutputTokens),
      maxChangeSetFiles:
          positive('maxChangeSetFiles', defaults.maxChangeSetFiles),
      editMode: AiEditMode.values
              .where((m) => m.name == json['editMode'])
              .firstOrNull ??
          defaults.editMode,
      maxAgentChanges: positive('maxAgentChanges', defaults.maxAgentChanges),
    );
  }
}

/// The connection of the chosen provider, with its key from [keys]:
/// its default model, or its strong one when [strong] and it has one.
Future<ProviderConfig> providerConfig(
  AiSettings settings,
  ApiKeyStore keys, {
  bool strong = false,
}) async {
  final preset = settings.preset;
  final values = settings.providerSettings();
  String key;
  try {
    key = await keys.read(preset.id) ?? '';
  } on Exception {
    key = '';
  }
  return ProviderConfig(
    name: preset.name,
    api: values.api,
    baseUrl: values.baseUrl,
    model: strong && values.strongModel.isNotEmpty
        ? values.strongModel
        : values.defaultModel,
    apiKey: key,
    euOnly: preset.euSwitch && values.euOnly,
    maxOutputTokens: settings.maxOutputTokens,
    // A local server such as Ollama needs no key.
    keyRequired: preset.id != 'custom',
  );
}

/// What "Create image" needs (#112): the chosen provider's connection
/// with its image model, and how to ask it; null when the provider makes
/// no images in the app.
Future<ImageConfig?> imageConfig(AiSettings settings, ApiKeyStore keys) async {
  final preset = settings.preset;
  final path = preset.imagesPath;
  if (path == null || preset.api != ApiKind.openAi) return null;
  final values = settings.providerSettings();
  final base = await providerConfig(settings, keys);
  return ImageConfig(
    base.withModel(values.imageModel),
    api: values.imageApi,
    imagesPath: path,
  );
}

/// Keeps API keys, one per provider. An interface so screens can be
/// tested without Android.
abstract interface class ApiKeyStore {
  Future<String?> read(String provider);

  /// Saves [key]; an empty key removes it.
  Future<void> write(String provider, String key);
}

/// [ApiKeyStore] in Android's secure storage: encrypted with a key that
/// the Android Keystore holds, in the app's private storage. Not in the
/// notes, not in a plain file.
class SecureApiKeyStore implements ApiKeyStore {
  const SecureApiKeyStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String provider) =>
      _storage.read(key: 'api-key-$provider');

  @override
  Future<void> write(String provider, String key) => key.isEmpty
      ? _storage.delete(key: 'api-key-$provider')
      : _storage.write(key: 'api-key-$provider', value: key);
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
/// start, and the API keys in [keys]; [AiSettingsScope.of] reads them.
class AiSettingsHost extends StatefulWidget {
  const AiSettingsHost({
    super.key,
    this.store = const FileAiSettingsStore(),
    this.keys = const SecureApiKeyStore(),
    required this.child,
  });

  final AiSettingsStore store;
  final ApiKeyStore keys;
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
        keys: widget.keys,
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
    required this.keys,
    required this.loaded,
    required super.child,
  }) : super(notifier: settings);

  final AiSettingsStore store;
  final ApiKeyStore keys;

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

  /// The key store, or null where there is no scope.
  static ApiKeyStore? keysOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AiSettingsScope>()?.keys;

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

/// What the page holds for one provider until it is saved.
class _Draft {
  _Draft(ProviderSettings settings, this.hasKey)
      : api = settings.api,
        euOnly = settings.euOnly,
        imageApi = settings.imageApi,
        imageModel = TextEditingController(text: settings.imageModel),
        baseUrl = TextEditingController(text: settings.baseUrl),
        defaultModel = TextEditingController(text: settings.defaultModel),
        strongModel = TextEditingController(text: settings.strongModel);

  ApiKind api;
  bool euOnly;
  ImageApi imageApi;
  final TextEditingController imageModel;
  final TextEditingController baseUrl;
  final TextEditingController defaultModel;
  final TextEditingController strongModel;

  /// Empty unless a new key is typed in.
  final key = TextEditingController();

  /// Whether a key is saved.
  bool hasKey;
  bool removeKey = false;

  ProviderSettings get settings => ProviderSettings(
        api: api,
        baseUrl: baseUrl.text.trim(),
        defaultModel: defaultModel.text.trim(),
        strongModel: strongModel.text.trim(),
        euOnly: euOnly,
        imageModel: imageModel.text.trim(),
        imageApi: imageApi,
      );

  void dispose() {
    for (final c in [baseUrl, defaultModel, strongModel, imageModel, key]) {
      c.dispose();
    }
  }
}

/// The AI settings page: the tags that hide notes from AI (#57), and the
/// provider of the chat with its key and limits (#59).
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, this.get = getWithDartIo});

  /// HTTP for the model lists (#75); tests replace it.
  final HttpGet get;

  static Future<void> open(BuildContext context) => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const AiSettingsScreen()),
      );

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  /// Filled once the saved settings are loaded, so the fields never show
  /// the defaults over saved values.
  TextEditingController? _tags;
  late String _provider;
  final _drafts = <String, _Draft>{};
  final _rounds = TextEditingController();
  final _tokens = TextEditingController();
  final _files = TextEditingController();
  final _changes = TextEditingController();
  AiEditMode _editMode = AiEditMode.agent;
  AiSettings? _loaded;
  String? _problem;

  /// Each provider's model IDs as its list has them now, to show a chosen
  /// model that is gone (#113); null where the list cannot be fetched.
  final _listed = <String, Set<String>?>{};

  /// Fetches [id]'s list once, with the key saved or typed in.
  Future<void> _checkModels(String id) async {
    if (_listed.containsKey(id)) return;
    _listed[id] = null;
    final draft = _drafts[id];
    if (draft == null) return;
    final preset = presetById(id);
    var key = draft.key.text.trim();
    if (key.isEmpty && !draft.removeKey) {
      try {
        key = await AiSettingsScope.keysOf(context)?.read(id) ?? '';
      } on Exception {
        key = '';
      }
    }
    if (key.isEmpty && preset.id != 'custom') return;
    final listed = await listedModels(
      provider: preset.name,
      api: draft.api,
      baseUrl: draft.baseUrl.text,
      apiKey: key,
      get: widget.get,
    );
    if (mounted && listed != null) setState(() => _listed[id] = listed);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final settings = await AiSettingsScope.current(context);
      if (!mounted) return;
      _loaded = settings;
      _provider = settings.provider;
      _rounds.text = '${settings.maxToolRounds}';
      _tokens.text = '${settings.maxOutputTokens}';
      _files.text = '${settings.maxChangeSetFiles}';
      _changes.text = '${settings.maxAgentChanges}';
      _editMode = settings.editMode;
      await _draft(_provider);
      if (mounted) {
        setState(() => _tags = TextEditingController(
            text: settings.hiddenTags.join(' ')));
        unawaited(_checkModels(_provider));
      }
    });
  }

  /// The draft of [id], made from the saved settings on first use.
  Future<_Draft> _draft(String id) async {
    final existing = _drafts[id];
    if (existing != null) return existing;
    final keys = AiSettingsScope.keysOf(context);
    String? key;
    try {
      key = await keys?.read(id);
    } on Exception {
      key = null;
    }
    return _drafts[id] ??= _Draft(
        _loaded!.providerSettings(id), key != null && key.isNotEmpty);
  }

  @override
  void dispose() {
    _tags?.dispose();
    _rounds.dispose();
    _tokens.dispose();
    _files.dispose();
    _changes.dispose();
    for (final d in _drafts.values) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _choose(String id) async {
    await _draft(id);
    if (mounted) setState(() => _provider = id);
    if (mounted) unawaited(_checkModels(id));
  }

  Future<void> _save() async {
    final tags = _tags, loaded = _loaded;
    if (tags == null || loaded == null) return;
    final rounds = int.tryParse(_rounds.text.trim());
    final tokens = int.tryParse(_tokens.text.trim());
    final files = int.tryParse(_files.text.trim());
    final changes = int.tryParse(_changes.text.trim());
    if (changes == null || changes < 1) {
      setState(() => _problem =
          'The changes per message must be at least 1.');
      return;
    }
    if (rounds == null ||
        rounds < 1 ||
        tokens == null ||
        tokens < 256 ||
        files == null ||
        files < 1) {
      setState(() => _problem = 'Tool rounds and notes per change set must '
          'be at least 1, and tokens per answer at least 256.');
      return;
    }
    final settings = AiSettingsScope.of(context).copyWith(
      hiddenTags: parseTags(tags.text),
      provider: _provider,
      providers: {
        ...loaded.providers,
        for (final MapEntry(:key, :value) in _drafts.entries)
          key: value.settings,
      },
      maxToolRounds: rounds,
      maxOutputTokens: tokens,
      maxChangeSetFiles: files,
      editMode: _editMode,
      maxAgentChanges: changes,
    );
    final keys = AiSettingsScope.keysOf(context);
    try {
      for (final MapEntry(key: id, value: draft) in _drafts.entries) {
        final key = draft.key.text.trim();
        if (key.isNotEmpty) {
          await keys?.write(id, key);
        } else if (draft.removeKey) {
          await keys?.write(id, '');
        }
      }
      if (!mounted) return;
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
    final ready = _tags != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI settings'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed: ready ? _save : null,
          ),
        ],
      ),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_problem case final problem?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      problem,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                TextField(
                  key: const ValueKey('hidden-tags'),
                  controller: _tags,
                  decoration: const InputDecoration(
                    labelText: 'Hidden from AI: tags',
                    hintText: 'Separated by spaces or commas',
                    helperText: 'Notes with one of these tags are never '
                        'shared with an AI, nor shown to one. Headings with '
                        'one of them are left out of the notes that are.',
                    helperMaxLines: 4,
                  ),
                ),
                const SizedBox(height: 24),
                ..._providerSection(context),
              ],
            ),
    );
  }

  /// "Choose model" (#75): the provider's model list, fetched with the key
  /// typed in or saved; the chosen ID fills [field].
  Widget _chooseModel(ProviderPreset preset, _Draft draft,
      TextEditingController field, String which) {
    return IconButton(
      key: ValueKey('choose-$which-${preset.id}'),
      tooltip: 'Choose model',
      icon: const Icon(Icons.list),
      onPressed: () async {
        final keys = AiSettingsScope.keysOf(context);
        final typed = draft.key.text.trim();
        String saved = '';
        if (typed.isEmpty && !draft.removeKey) {
          try {
            saved = await keys?.read(preset.id) ?? '';
          } on Exception {
            saved = '';
          }
        }
        if (!mounted) return;
        final images = which == 'image';
        var models = const <ModelInfo>[];
        final id = await ModelPickerScreen.open(
          context,
          provider: preset.name,
          euOnly: preset.euSwitch && draft.euOnly,
          images: images,
          load: ({bool refresh = false}) async => models = await fetchModels(
            provider: preset.name,
            api: draft.api,
            baseUrl: draft.baseUrl.text,
            apiKey: typed.isNotEmpty ? typed : saved,
            get: widget.get,
            refresh: refresh,
          ),
        );
        if (id != null && mounted) {
          setState(() {
            field.text = id;
            // A chat model that also makes images is asked through the
            // chat; OpenRouter's Images API takes them all (#112).
            if (images) {
              final model = models.where((m) => m.id == id).firstOrNull;
              draft.imageApi = preset.id != 'openrouter' &&
                      model?.chat == true &&
                      model?.images == true
                  ? ImageApi.chat
                  : ImageApi.images;
            }
          });
        }
        // The list is fetched now: check the models against it.
        if (mounted) {
          _listed.remove(preset.id);
          unawaited(_checkModels(preset.id));
        }
      },
    );
  }

  /// "Reset to the defaults": the preset's base URL, models and "EU only",
  /// for example after trying another model. Saved with Save, as every
  /// change here. Not shown when they are the preset's already.
  Widget _resetModels(ProviderPreset preset, _Draft draft) {
    final base = ProviderSettings.of(preset);
    return ListenableBuilder(
      listenable: Listenable.merge([
        draft.baseUrl,
        draft.defaultModel,
        draft.strongModel,
        draft.imageModel,
      ]),
      builder: (context, _) {
        final differs = draft.baseUrl.text.trim() != base.baseUrl ||
            draft.defaultModel.text.trim() != base.defaultModel ||
            draft.strongModel.text.trim() != base.strongModel ||
            (preset.makesImages &&
                (draft.imageModel.text.trim() != base.imageModel ||
                    draft.imageApi != base.imageApi)) ||
            (preset.euSwitch && draft.euOnly != base.euOnly);
        if (!differs) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('reset-models-${preset.id}'),
            icon: const Icon(Icons.restart_alt),
            label: Text(base.defaultModel.isEmpty
                ? 'Reset to the defaults'
                : 'Reset to the defaults (${base.defaultModel})'),
            onPressed: () => setState(() {
              draft.baseUrl.text = base.baseUrl;
              draft.defaultModel.text = base.defaultModel;
              draft.strongModel.text = base.strongModel;
              draft.imageModel.text = base.imageModel;
              draft.imageApi = base.imageApi;
              draft.euOnly = base.euOnly;
            }),
          ),
        );
      },
    );
  }

  List<Widget> _providerSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final draft = _drafts[_provider]!;
    final preset = presetById(_provider);
    Widget group(String title, bool eu) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(title, style: text.titleSmall),
            ),
            for (final p in providerPresets)
              if (p.dataStaysInEu == eu)
                RadioListTile<String>(
                  key: ValueKey('provider-${p.id}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: p.id,
                  title: Text(
                      p.euSwitch ? '${p.name} ("EU only" possible)' : p.name),
                ),
          ],
        );
    return [
      Text('AI chat: provider', style: text.titleMedium),
      const SizedBox(height: 4),
      const Text('The chat sends my messages and the notes its tools read '
          'to this provider, only when I send a message.'),
      RadioGroup<String>(
        groupValue: _provider,
        onChanged: (id) {
          if (id != null) _choose(id);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            group('Data stays in the EU', true),
            group('Outside the EU', false),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(preset.note, key: const ValueKey('provider-note')),
      const SizedBox(height: 8),
      if (preset.id == 'custom')
        DropdownButtonFormField<ApiKind>(
          key: const ValueKey('provider-api'),
          initialValue: draft.api,
          decoration: const InputDecoration(labelText: 'API'),
          items: [
            for (final kind in ApiKind.values)
              DropdownMenuItem(value: kind, child: Text(kind.label)),
          ],
          onChanged: (kind) => setState(() => draft.api = kind ?? draft.api),
        ),
      TextField(
        key: ValueKey('base-url-${preset.id}'),
        controller: draft.baseUrl,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'Base URL'),
      ),
      ListenableBuilder(
        listenable: draft.defaultModel,
        builder: (context, _) => TextField(
          key: ValueKey('default-model-${preset.id}'),
          controller: draft.defaultModel,
          decoration: InputDecoration(
            labelText: 'Model',
            helperText: 'The model a chat starts with.',
            errorText: modelGoneMessage(
                preset.name, draft.defaultModel.text, _listed[preset.id]),
            errorMaxLines: 3,
            suffixIcon:
                _chooseModel(preset, draft, draft.defaultModel, 'default'),
          ),
        ),
      ),
      ListenableBuilder(
        listenable: draft.strongModel,
        builder: (context, _) => TextField(
          key: ValueKey('strong-model-${preset.id}'),
          controller: draft.strongModel,
          decoration: InputDecoration(
            labelText: 'Strong model (optional)',
            helperText: 'A stronger model the chat can switch to.',
            errorText: modelGoneMessage(
                preset.name, draft.strongModel.text, _listed[preset.id]),
            errorMaxLines: 3,
            suffixIcon:
                _chooseModel(preset, draft, draft.strongModel, 'strong'),
          ),
        ),
      ),
      if (preset.makesImages) ...[
        TextField(
          key: ValueKey('image-model-${preset.id}'),
          controller: draft.imageModel,
          decoration: InputDecoration(
            labelText: 'Image model (optional)',
            helperText: 'For "Create image" in a note\'s edit menu.',
            suffixIcon:
                _chooseModel(preset, draft, draft.imageModel, 'image'),
          ),
        ),
        DropdownButtonFormField<ImageApi>(
          // Keyed by the value, so a model chosen from the list shows here.
          key: ValueKey('image-api-${preset.id}-${draft.imageApi.name}'),
          initialValue: draft.imageApi,
          isExpanded: true,
          decoration:
              const InputDecoration(labelText: 'How the image model is asked'),
          items: [
            for (final kind in ImageApi.values)
              DropdownMenuItem(
                  value: kind,
                  child: Text(kind.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (kind) =>
              setState(() => draft.imageApi = kind ?? draft.imageApi),
        ),
      ] else
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('${preset.name} cannot make images in the app.',
              key: ValueKey('no-images-${preset.id}'),
              style: Theme.of(context).textTheme.bodySmall),
        ),
      _resetModels(preset, draft),
      TextField(
        key: ValueKey('api-key-${preset.id}'),
        controller: draft.key,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: preset.keyHint,
          helperText: draft.hasKey && !draft.removeKey
              ? 'A key is saved. Type a new one to replace it.'
              : 'Kept in Android\'s secure storage, never in the notes.',
          helperMaxLines: 2,
        ),
      ),
      if (draft.hasKey && !draft.removeKey)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => draft.removeKey = true),
            child: const Text('Remove the saved key'),
          ),
        ),
      if (preset.euSwitch)
        SwitchListTile(
          key: const ValueKey('eu-only'),
          contentPadding: EdgeInsets.zero,
          value: draft.euOnly,
          onChanged: (on) => setState(() => draft.euOnly = on),
          title: const Text('EU only'),
          subtitle: const Text('Inference and stored data in the EU; models '
              'without an EU route then fail.'),
        ),
      const SizedBox(height: 16),
      Text('Limits', style: text.titleSmall),
      TextField(
        key: const ValueKey('max-tool-rounds'),
        controller: _rounds,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Most tool rounds per message',
        ),
      ),
      TextField(
        key: const ValueKey('max-output-tokens'),
        controller: _tokens,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Most tokens per answer, thinking included',
        ),
      ),
      DropdownButtonFormField<AiEditMode>(
        key: const ValueKey('edit-mode'),
        initialValue: _editMode,
        isExpanded: true,
        decoration:
            const InputDecoration(labelText: 'Let the AI change notes'),
        items: [
          for (final mode in AiEditMode.values)
            DropdownMenuItem(value: mode, child: Text(mode.label)),
        ],
        onChanged: (mode) {
          if (mode != null) setState(() => _editMode = mode);
        },
      ),
      TextField(
        key: const ValueKey('max-agent-changes'),
        controller: _changes,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Most changes the agent may make for one message',
        ),
      ),
      TextField(
        key: const ValueKey('max-change-set-files'),
        controller: _files,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Most notes one AI change set may edit',
        ),
      ),
    ];
  }
}
