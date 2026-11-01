import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../edit/tag_field.dart';
import '../graph/roam_graph.dart';
import '../platform/desktop.dart' show isDesktop;
import 'ai_chat.dart';
import 'ai_images.dart';
import 'ai_models.dart';
import 'model_picker.dart';
import 'note_language.dart';
import 'ai_providers.dart';
import 'ai_visibility.dart';
import 'speech.dart';
import 'chat_store.dart' show ChatStoreScope;

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
    this.infographicModel = '',
    this.infographicApi = ImageApi.images,
  });

  /// The preset's values.
  factory ProviderSettings.of(ProviderPreset preset) => ProviderSettings(
        api: preset.api,
        baseUrl: preset.baseUrl,
        defaultModel: preset.defaultModel,
        strongModel: preset.strongModel,
        imageModel: preset.imageModel,
        imageApi: preset.imageApi,
        infographicModel: preset.imageModel,
        infographicApi: preset.imageApi,
      );

  /// The model infographics use when this provider is chosen under
  /// "Infographics with:" (#183); empty when none is chosen.
  final String infographicModel;

  /// How [infographicModel] is asked.
  final ImageApi infographicApi;

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
        'infographicModel': infographicModel,
        'infographicApi': infographicApi.name,
      };

  /// [json] over [preset]'s values; what is missing or unreadable keeps
  /// the preset's value.
  factory ProviderSettings.fromJson(Object? json, ProviderPreset preset) {
    final base = ProviderSettings.of(preset);
    if (json is! Map) return base;
    String text(String key, String fallback) =>
        json[key] is String ? json[key] as String : fallback;
    String nonEmpty(String key, String fallback) => switch (json[key]) {
          final String value when value.trim().isNotEmpty => value,
          _ => fallback,
        };
    // An empty image model was saved before the provider made images:
    // the preset's default then (#120).
    String model(String key) => switch (json[key]) {
          final String model when model.trim().isNotEmpty => model,
          _ => base.imageModel,
        };
    // DashScope is Qwen's only way and the image tool Mistral's (#126);
    // another way is kept only where the provider has no own one.
    // Mistral settings saved before it made images get its own way.
    ImageApi api(String key) => base.imageApi.ownProvider
        ? base.imageApi
        : ImageApi.values.firstWhere(
            (k) => k.name == json[key] && !k.ownProvider,
            orElse: () => base.imageApi);
    return ProviderSettings(
      api: preset.id == 'custom'
          ? ApiKind.values.firstWhere((k) => k.name == json['api'],
              orElse: () => base.api)
          : preset.api,
      baseUrl: text('baseUrl', base.baseUrl),
      // An empty model was saved before the preset had one (OpenRouter
      // before #190): the preset's model then. The strong model is
      // optional, so an empty one is a choice, unless the default model
      // was empty too, as in settings from before #190.
      defaultModel: nonEmpty('defaultModel', base.defaultModel),
      strongModel: nonEmpty('defaultModel', '').isEmpty
          ? nonEmpty('strongModel', base.strongModel)
          : text('strongModel', base.strongModel).trim(),
      euOnly: json['euOnly'] is bool ? json['euOnly'] as bool : base.euOnly,
      imageModel: model('imageModel'),
      imageApi: api('imageApi'),
      // Missing in settings saved before #183: the preset's image model.
      infographicModel: model('infographicModel'),
      infographicApi: api('infographicApi'),
    );
  }
}

/// "Let the AI change notes" (#82).
enum AiEditMode {
  /// The AI only reads.
  off('Off: the AI only reads', 'Off'),

  /// The AI proposes edits; each is saved only after my OK (#39, #76).
  review('Review each change first', 'Review'),

  /// The AI creates, edits and links notes itself; I see a summary
  /// afterwards and can undo all changes of a message.
  agent('Agent: it changes notes itself, I can undo', 'Agent');

  const AiEditMode(this.label, this.shortLabel);

  final String label;

  /// One word, for the line under "Agent and limits" in AI settings.
  final String shortLabel;
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
    this.maxImagesPerMessage = 1,
    this.imageProvider = '',
    this.infographicProvider = '',
    this.webAccess = false,
    this.maxWebSearches = 5,
    this.imageAgents = const {},
    this.newNoteLanguage = defaultNoteLanguage,
    this.maxParallelChats = 3,
    this.keepChatsDays = 90,
    this.notifyAnswers = true,
    this.speechProvider = '',
    this.speechModels = const {},
    this.speechLanguage = '',
    this.speechSpeakers = false,
    this.speechConsent = const [],
  });

  /// "Speech to text: provider" (#221): the ID of a [speechProviders]
  /// entry; empty for automatic: Mistral when its key is set, else OpenAI
  /// when its key is set.
  final String speechProvider;

  /// The model for each speech provider, by ID; a provider not in it has
  /// its default.
  final Map<String, String> speechModels;

  /// "Speech to text: language": empty for the language of new notes,
  /// [speechLanguageAuto] to let the provider detect it, or a code.
  final String speechLanguage;

  /// "Speakers" (#221): ask for speaker labels where the provider has them.
  final bool speechSpeakers;

  /// The IDs of the speech providers the user agreed to send recordings to.
  final List<String> speechConsent;

  /// The model of the speech provider [id].
  String speechModel(String id) {
    final saved = speechModels[id]?.trim() ?? '';
    return saved.isEmpty ? speechProviderById(id).defaultModel : saved;
  }

  /// "Most chats working at the same time" (#201): a further send waits.
  final int maxParallelChats;

  /// "Keep chats for" (#201), in days; 0 keeps them always. Older chats
  /// are deleted when the app starts.
  final int keepChatsDays;

  /// "Notify when an answer is ready" (#202): a notification when a chat
  /// that is not on screen gets its answer, or fails.
  final bool notifyAnswers;

  /// "Language of new notes" (#172): the code of the language the AI
  /// writes new notes in when neither the request, the note they start
  /// from nor its neighbours decide it.
  final String newNoteLanguage;

  /// The IDs of the Mistral agents the app made for images (#163), by
  /// [imageAgentKey]: one per provider and image model, used again.
  final Map<String, String> imageAgents;

  /// The key of [imageAgents] for the provider [preset] and [model].
  static String imageAgentKey(String preset, String model) =>
      '$preset $model';

  /// "Web access for the AI" (#137): the chat may read web pages, and
  /// search with the provider's own web search where it has one. Off by
  /// default.
  final bool webAccess;

  /// The most web searches and fetched pages for one message (#137).
  final int maxWebSearches;

  /// The preset ID of the provider "Create image" uses (#127); empty for
  /// "Same as the chat".
  final String imageProvider;

  /// The preset ID of the provider infographics use (#183); empty for
  /// "Same as "Images with:"": that provider and its image model.
  final String infographicProvider;

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

  /// The most images the agent may make for one message (#129): each
  /// costs money.
  final int maxImagesPerMessage;

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
    int? maxImagesPerMessage,
    String? imageProvider,
    String? infographicProvider,
    bool? webAccess,
    int? maxWebSearches,
    Map<String, String>? imageAgents,
    String? newNoteLanguage,
    int? maxParallelChats,
    int? keepChatsDays,
    bool? notifyAnswers,
    String? speechProvider,
    Map<String, String>? speechModels,
    String? speechLanguage,
    bool? speechSpeakers,
    List<String>? speechConsent,
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
        maxImagesPerMessage: maxImagesPerMessage ?? this.maxImagesPerMessage,
        imageProvider: imageProvider ?? this.imageProvider,
        infographicProvider: infographicProvider ?? this.infographicProvider,
        webAccess: webAccess ?? this.webAccess,
        maxWebSearches: maxWebSearches ?? this.maxWebSearches,
        imageAgents: imageAgents ?? this.imageAgents,
        newNoteLanguage: newNoteLanguage ?? this.newNoteLanguage,
        maxParallelChats: maxParallelChats ?? this.maxParallelChats,
        keepChatsDays: keepChatsDays ?? this.keepChatsDays,
        notifyAnswers: notifyAnswers ?? this.notifyAnswers,
        speechProvider: speechProvider ?? this.speechProvider,
        speechModels: speechModels ?? this.speechModels,
        speechLanguage: speechLanguage ?? this.speechLanguage,
        speechSpeakers: speechSpeakers ?? this.speechSpeakers,
        speechConsent: speechConsent ?? this.speechConsent,
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
        'maxImagesPerMessage': maxImagesPerMessage,
        'imageProvider': imageProvider,
        'infographicProvider': infographicProvider,
        'webAccess': webAccess,
        'maxWebSearches': maxWebSearches,
        'imageAgents': imageAgents,
        'newNoteLanguage': newNoteLanguage,
        'maxParallelChats': maxParallelChats,
        'keepChatsDays': keepChatsDays,
        'notifyAnswers': notifyAnswers,
        'speechProvider': speechProvider,
        'speechModels': speechModels,
        'speechLanguage': speechLanguage,
        'speechSpeakers': speechSpeakers,
        'speechConsent': speechConsent,
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
      maxImagesPerMessage:
          positive('maxImagesPerMessage', defaults.maxImagesPerMessage),
      // Missing in settings saved before #127, or a provider that makes no
      // images: the chat's provider.
      imageProvider: switch (json['imageProvider']) {
        final String id when imageProviders.any((p) => p.id == id) => id,
        _ => defaults.imageProvider,
      },
      // Missing in settings saved before #183: as "Images with:".
      infographicProvider: switch (json['infographicProvider']) {
        final String id when imageProviders.any((p) => p.id == id) => id,
        _ => defaults.infographicProvider,
      },
      webAccess: json['webAccess'] == true,
      maxWebSearches: positive('maxWebSearches', defaults.maxWebSearches),
      imageAgents: {
        if (json['imageAgents'] case final Map agents)
          for (final MapEntry(:key, :value) in agents.entries)
            if (key is String && value is String && value.isNotEmpty)
              key: value,
      },
      newNoteLanguage: switch (json['newNoteLanguage']) {
        final String code => languageCode(code) ?? defaultNoteLanguage,
        _ => defaultNoteLanguage,
      },
      maxParallelChats:
          positive('maxParallelChats', defaults.maxParallelChats),
      // 0 is "always"; a missing or odd value keeps the default.
      keepChatsDays: keepChatsChoices.any((c) => c.$1 == json['keepChatsDays'])
          ? json['keepChatsDays'] as int
          : defaults.keepChatsDays,
      notifyAnswers: json['notifyAnswers'] is bool
          ? json['notifyAnswers'] as bool
          : defaults.notifyAnswers,
      speechProvider: switch (json['speechProvider']) {
        final String id when speechProviders.any((p) => p.id == id) => id,
        _ => defaults.speechProvider,
      },
      speechModels: {
        if (json['speechModels'] case final Map models)
          for (final MapEntry(:key, :value) in models.entries)
            if (key is String &&
                speechProviders.any((p) => p.id == key) &&
                value is String &&
                value.trim().isNotEmpty)
              key: value.trim(),
      },
      speechLanguage: switch (json['speechLanguage']) {
        final String code when code == speechLanguageAuto => code,
        final String code => languageCode(code) ?? defaults.speechLanguage,
        _ => defaults.speechLanguage,
      },
      speechSpeakers: json['speechSpeakers'] == true,
      speechConsent: [
        if (json['speechConsent'] case final List ids)
          for (final id in ids)
            if (id is String && speechProviders.any((p) => p.id == id)) id,
      ],
    );
  }
}

/// The value of [AiSettings.speechLanguage] for "let the provider detect
/// the language".
const speechLanguageAuto = 'auto';

/// The choices of "Keep chats for" (#201): days, 0 for always.
const keepChatsChoices = [
  (30, '30 days'),
  (90, '90 days'),
  (365, '1 year'),
  (0, 'Always'),
];

/// The providers that can make images in the app, for "Images with:"
/// (#127).
Iterable<ProviderPreset> get imageProviders => providerPresets
    .where((p) => p.makesImages && p.api == ApiKind.openAi);

/// The connection of the chosen provider (or of the provider [id]), with
/// its key from [keys]: its default model, or its strong one when
/// [strong] and it has one.
Future<ProviderConfig> providerConfig(
  AiSettings settings,
  ApiKeyStore keys, {
  bool strong = false,
  String? id,
}) async {
  final preset = presetById(id ?? settings.provider);
  final values = settings.providerSettings(preset.id);
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

/// Whether [kind] uses "Infographics with:" (#183): an infographic, when
/// a provider is chosen there; else "Images with:".
bool _ownInfographics(AiSettings settings, ImageKind kind) =>
    kind == ImageKind.infographic && settings.infographicProvider.isNotEmpty;

/// The provider "Create image" uses for [kind]: for an illustration the
/// one of "Images with:", or the chat's (#127); for an infographic the one
/// of "Infographics with:", or that of "Images with:" (#183).
ProviderPreset imagePreset(AiSettings settings,
        [ImageKind kind = ImageKind.illustration]) =>
    _ownInfographics(settings, kind)
        ? presetById(settings.infographicProvider)
        : settings.imageProvider.isEmpty
            ? settings.preset
            : presetById(settings.imageProvider);

/// What "Create image" needs for [kind] (#112, #183): the image
/// provider's connection with its own key, image model and "EU only"
/// (#127), and how to ask it; null when the provider makes no images in
/// the app.
Future<ImageConfig?> imageConfig(AiSettings settings, ApiKeyStore keys,
    {ImageKind kind = ImageKind.illustration}) async {
  final preset = imagePreset(settings, kind);
  final path = preset.imagesPath;
  if (path == null || preset.api != ApiKind.openAi) return null;
  final values = settings.providerSettings(preset.id);
  final (model, api) = _ownInfographics(settings, kind)
      ? (values.infographicModel, values.infographicApi)
      : (values.imageModel, values.imageApi);
  final base = await providerConfig(settings, keys, id: preset.id);
  // With "EU only", the preset's default image model gives way to its
  // default with an EU route (#127).
  final euDefault = base.euOnly &&
      preset.euImageModel.isNotEmpty &&
      model == preset.imageModel &&
      api == preset.imageApi;
  return ImageConfig(
    base.withModel(euDefault ? preset.euImageModel : model),
    api: euDefault ? preset.euImageApi : api,
    imagesPath: path,
  );
}

/// Where [config]'s image is made, for the line on "Create image" (#127):
/// in the EU, outside it, or not known. With "EU only" on, the provider
/// makes it in the EU or refuses.
String imageRegion(ProviderPreset preset, ImageConfig config) {
  if (preset.dataStaysInEu || config.provider.euOnly) return 'in the EU';
  if (preset.outsideEu || preset.euSwitch) return 'outside the EU';
  return 'region not known';
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

  /// Where "Create image" keeps the IDs of the Mistral agents it makes
  /// for the provider [preset] (#163): in these settings. Null where
  /// there is no scope.
  static ImageAgents? imageAgentsOf(BuildContext context, String preset) {
    final scope = context.getInheritedWidgetOfExactType<AiSettingsScope>();
    return scope == null ? null : _ScopeImageAgents(scope, preset);
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

/// [ImageAgents] in the settings of [scope], for the provider [preset].
class _ScopeImageAgents implements ImageAgents {
  _ScopeImageAgents(this.scope, this.preset);

  final AiSettingsScope scope;
  final String preset;

  @override
  String? read(String model) => scope.notifier!.value
      .imageAgents[AiSettings.imageAgentKey(preset, model)];

  @override
  Future<void> write(String model, String id) async {
    await scope.loaded;
    final now = scope.notifier!.value;
    final changed = now.copyWith(imageAgents: {
      ...now.imageAgents,
      AiSettings.imageAgentKey(preset, model): id,
    });
    await scope.store.save(changed);
    scope.notifier!.value = changed;
  }
}

/// What the page holds for one provider until it is saved.
class _Draft {
  _Draft(ProviderSettings settings, this.hasKey)
      : api = settings.api,
        euOnly = settings.euOnly,
        imageApi = settings.imageApi,
        infographicApi = settings.infographicApi,
        imageModel = TextEditingController(text: settings.imageModel),
        infographicModel =
            TextEditingController(text: settings.infographicModel),
        baseUrl = TextEditingController(text: settings.baseUrl),
        defaultModel = TextEditingController(text: settings.defaultModel),
        strongModel = TextEditingController(text: settings.strongModel);

  ApiKind api;
  bool euOnly;
  ImageApi imageApi;
  ImageApi infographicApi;
  final TextEditingController imageModel;
  final TextEditingController infographicModel;
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
        infographicModel: infographicModel.text.trim(),
        infographicApi: infographicApi,
      );

  void dispose() {
    for (final c in [
      baseUrl,
      defaultModel,
      strongModel,
      imageModel,
      infographicModel,
      key,
    ]) {
      c.dispose();
    }
  }
}

/// A sub-page of the AI settings: [body] builds its fields from the draft
/// of the AI page, and again whenever [rebuild] changes.
class _AiSubPage extends StatelessWidget {
  const _AiSubPage({
    required this.title,
    required this.rebuild,
    required this.body,
  });

  final String title;
  final Listenable rebuild;
  final List<Widget> Function(BuildContext) body;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListenableBuilder(
          listenable: rebuild,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: body(context),
          ),
        ),
      );
}

/// The AI settings page (#194): a short list of rows, each opening a
/// sub-page: Chat, Images, Agent and limits, Web access, Notes and Privacy.
/// All sub-pages edit one draft, which the check mark here saves; leaving
/// with unsaved changes asks (decision 109).
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, this.get = getWithDartIo, this.graph});

  /// HTTP for the model lists (#75); tests replace it.
  final HttpGet get;

  /// The graph whose tags "Hidden from AI" offers; null before a folder is
  /// read.
  final RoamGraph? graph;

  static Future<void> open(BuildContext context, {RoamGraph? graph}) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => AiSettingsScreen(graph: graph)),
      );

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  /// Filled once the saved settings are loaded, so the fields never show
  /// the defaults over saved values.
  TagFieldController? _tags;
  late final _known = tagCounts(widget.graph);
  late String _provider;

  /// "Images with:"; empty for the chat's provider (#127).
  String _imageProvider = '';

  /// "Infographics with:"; empty for that of "Images with:" (#183).
  String _infographicProvider = '';
  final _drafts = <String, _Draft>{};
  final _rounds = TextEditingController();
  final _tokens = TextEditingController();
  final _files = TextEditingController();
  final _changes = TextEditingController();
  final _images = TextEditingController();
  final _webSearches = TextEditingController();
  final _language = TextEditingController();
  final _parallel = TextEditingController();
  int _keepChats = 90;
  bool _webAccess = false;
  bool _notifyAnswers = true;

  /// "Speech to text" (#221): '' for automatic, else a provider ID.
  String _speechProvider = '';
  final _speechMistralModel = TextEditingController();
  final _speechOpenAiModel = TextEditingController();

  /// '' for the language of new notes, [speechLanguageAuto], or 'code'.
  String _speechLanguageMode = '';
  final _speechLanguage = TextEditingController();
  bool _speechSpeakers = false;

  /// A new OpenAI key typed in, and whether one is saved or to be removed.
  final _openAiKey = TextEditingController();
  bool _openAiKeySaved = false;
  bool _openAiKeyRemove = false;
  AiEditMode _editMode = AiEditMode.agent;
  AiSettings? _loaded;
  String? _problem;

  /// Whether a save is running. The page stays until it ends, so a key
  /// that is written is never left behind by a discarded draft.
  bool _saving = false;

  /// Changes whenever the page's state does, so an open sub-page, which is
  /// another route, builds again with the shared draft.
  final _tick = ValueNotifier<int>(0);

  /// Each provider's model IDs as its list has them now, to show a chosen
  /// model that is gone (#113), with the connection they were fetched
  /// with: API, base URL and typed key. A changed connection fetches again.
  final _listed = <String, ({String connection, Set<String> ids})>{};

  /// The providers whose list is being fetched.
  final _checking = <String>{};

  /// The providers to fetch again when the running fetch ends: the
  /// connection changed meanwhile.
  final _checkAgain = <String>{};

  /// Waits for typing to stop before fetching with a changed connection.
  Timer? _recheck;

  String _connection(_Draft draft) =>
      '${draft.api.name} ${draft.baseUrl.text.trim()} ${draft.key.text.trim()} '
      '${draft.removeKey}';

  /// The list of [id] when it was fetched with the connection the page
  /// shows now; null otherwise.
  Set<String>? _listedNow(String id) {
    final entry = _listed[id];
    final draft = _drafts[id];
    if (entry == null || draft == null) return null;
    return entry.connection == _connection(draft) ? entry.ids : null;
  }

  /// Fetches [id]'s list again after its base URL or key changed.
  void _connectionChanged(String id) {
    _recheck?.cancel();
    _recheck = Timer(const Duration(milliseconds: 800), () {
      if (mounted) unawaited(_checkModels(id));
    });
  }

  /// Fetches [id]'s list, with the key saved or typed in, unless it was
  /// fetched with this connection already.
  Future<void> _checkModels(String id) async {
    final draft = _drafts[id];
    if (draft == null) return;
    if (_checking.contains(id)) {
      _checkAgain.add(id);
      return;
    }
    final connection = _connection(draft);
    if (_listed[id]?.connection == connection) return;
    _checking.add(id);
    try {
      await _fetchListed(id, draft, connection);
    } finally {
      _checking.remove(id);
    }
    if (_checkAgain.remove(id) && mounted) await _checkModels(id);
  }

  Future<void> _fetchListed(String id, _Draft draft, String connection) async {
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
    if (!mounted) return;
    setState(() {
      if (listed == null) {
        // Not known: nothing is said, and a later check tries again.
        _listed.remove(id);
      } else {
        _listed[id] = (connection: connection, ids: listed);
      }
    });
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
      _imageProvider = settings.imageProvider;
      _infographicProvider = settings.infographicProvider;
      _rounds.text = '${settings.maxToolRounds}';
      _tokens.text = '${settings.maxOutputTokens}';
      _files.text = '${settings.maxChangeSetFiles}';
      _changes.text = '${settings.maxAgentChanges}';
      _images.text = '${settings.maxImagesPerMessage}';
      _webSearches.text = '${settings.maxWebSearches}';
      _language.text = settings.newNoteLanguage;
      _parallel.text = '${settings.maxParallelChats}';
      _keepChats = settings.keepChatsDays;
      _webAccess = settings.webAccess;
      _notifyAnswers = settings.notifyAnswers;
      _speechProvider = settings.speechProvider;
      _speechMistralModel.text = settings.speechModel('mistral');
      _speechOpenAiModel.text = settings.speechModel('openai');
      _speechLanguageMode = switch (settings.speechLanguage) {
        '' => '',
        speechLanguageAuto => speechLanguageAuto,
        _ => 'code',
      };
      _speechLanguage.text = _speechLanguageMode == 'code'
          ? settings.speechLanguage
          : settings.newNoteLanguage;
      _speechSpeakers = settings.speechSpeakers;
      try {
        final saved = await AiSettingsScope.keysOf(context)
            ?.read(speechProviderById('openai').keyId);
        _openAiKeySaved = saved != null && saved.isNotEmpty;
      } on Exception {
        _openAiKeySaved = false;
      }
      _editMode = settings.editMode;
      await _draft('mistral');
      await _draft(_provider);
      if (_imageProvider.isNotEmpty) await _draft(_imageProvider);
      if (_infographicProvider.isNotEmpty) await _draft(_infographicProvider);
      if (mounted) {
        setState(() => _tags = TagFieldController(settings.hiddenTags));
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
    final known = _drafts[id];
    if (known != null) return known;
    final draft = _drafts[id] = _Draft(
        _loaded!.providerSettings(id), key != null && key.isNotEmpty);
    // A new base URL or key: the list is fetched again (#113).
    draft.baseUrl.addListener(() => _connectionChanged(id));
    draft.key.addListener(() => _connectionChanged(id));
    return draft;
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _tick.value++;
  }

  @override
  void dispose() {
    _recheck?.cancel();
    _tick.dispose();
    _tags?.dispose();
    _rounds.dispose();
    _tokens.dispose();
    _files.dispose();
    _changes.dispose();
    _images.dispose();
    _webSearches.dispose();
    _language.dispose();
    _parallel.dispose();
    _speechMistralModel.dispose();
    _speechOpenAiModel.dispose();
    _speechLanguage.dispose();
    _openAiKey.dispose();
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
    final images = int.tryParse(_images.text.trim());
    if (images == null || images < 1) {
      setState(() => _problem =
          'The images per message must be at least 1.');
      return;
    }
    final webSearches = int.tryParse(_webSearches.text.trim());
    if (webSearches == null || webSearches < 1) {
      setState(() => _problem =
          'The web searches per message must be at least 1.');
      return;
    }
    final parallel = int.tryParse(_parallel.text.trim());
    if (parallel == null || parallel < 1) {
      setState(() => _problem =
          'The chats working at the same time must be at least 1.');
      return;
    }
    final language = languageCode(_language.text);
    if (language == null) {
      setState(() => _problem = 'The language of new notes must be a '
          'language code such as en or de.');
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
    final speechCode = languageCode(_speechLanguage.text);
    if (_speechLanguageMode == 'code' && speechCode == null) {
      setState(() => _problem = 'The language for speech to text must be a '
          'language code such as en or de.');
      return;
    }
    final settings = AiSettingsScope.of(context).copyWith(
      speechProvider: _speechProvider,
      speechModels: _speechModels(),
      speechLanguage:
          _speechLanguageMode == 'code' ? speechCode : _speechLanguageMode,
      speechSpeakers: _speechSpeakers,
      hiddenTags: tags.tags,
      provider: _provider,
      imageProvider: _imageProvider,
      infographicProvider: _infographicProvider,
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
      maxImagesPerMessage: images,
      webAccess: _webAccess,
      maxWebSearches: webSearches,
      newNoteLanguage: language,
      maxParallelChats: parallel,
      keepChatsDays: _keepChats,
      notifyAnswers: _notifyAnswers,
    );
    final keys = AiSettingsScope.keysOf(context);
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      final openAiKey = _openAiKey.text.trim();
      if (openAiKey.isNotEmpty) {
        await keys?.write(speechProviderById('openai').keyId, openAiKey);
      } else if (_openAiKeyRemove) {
        await keys?.write(speechProviderById('openai').keyId, '');
      }
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
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Whether anything on the page differs from the saved settings: a
  /// typed value, a typed or removed key, a changed choice.
  bool get _dirty {
    final saved = _loaded, tags = _tags;
    if (saved == null || tags == null) return false;
    if (jsonEncode(tags.tags) != jsonEncode(saved.hiddenTags) ||
        _provider != saved.provider ||
        _imageProvider != saved.imageProvider ||
        _infographicProvider != saved.infographicProvider ||
        _webAccess != saved.webAccess ||
        _notifyAnswers != saved.notifyAnswers ||
        _speechProvider != saved.speechProvider ||
        jsonEncode(_speechModels()) != jsonEncode(saved.speechModels) ||
        _speechLanguageValue != saved.speechLanguage ||
        _speechSpeakers != saved.speechSpeakers ||
        _openAiKey.text.trim().isNotEmpty ||
        _openAiKeyRemove ||
        _editMode != saved.editMode ||
        _rounds.text.trim() != '${saved.maxToolRounds}' ||
        _tokens.text.trim() != '${saved.maxOutputTokens}' ||
        _files.text.trim() != '${saved.maxChangeSetFiles}' ||
        _changes.text.trim() != '${saved.maxAgentChanges}' ||
        _images.text.trim() != '${saved.maxImagesPerMessage}' ||
        _webSearches.text.trim() != '${saved.maxWebSearches}' ||
        _language.text.trim() != saved.newNoteLanguage ||
        _parallel.text.trim() != '${saved.maxParallelChats}' ||
        _keepChats != saved.keepChatsDays) {
      return true;
    }
    for (final MapEntry(key: id, value: draft) in _drafts.entries) {
      if (draft.key.text.trim().isNotEmpty || draft.removeKey) return true;
      if (jsonEncode(draft.settings.toJson()) !=
          jsonEncode(saved.providerSettings(id).toJson())) {
        return true;
      }
    }
    return false;
  }

  /// Leaving the page: at once when nothing changed, else after asking.
  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('The changes in AI settings are not saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  /// Opens a sub-page with [body]; it edits the draft of this page.
  Future<void> _openPage(
      String title, List<Widget> Function(BuildContext) body) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _AiSubPage(title: title, rebuild: _tick, body: body),
      ),
    );
    // Back here: the lines under the rows show the draft now.
    if (mounted) setState(() {});
  }

  /// The language of new notes as the line under "Notes": "English (en)".
  String _languageLine() {
    final code = languageCode(_language.text);
    if (code == null) return _language.text.trim();
    return commonLanguages.containsKey(code.substring(0, 2))
        ? languageName(code)
        : code;
  }

  Widget _row(String key, IconData icon, String title, String subtitle,
      List<Widget> Function(BuildContext) body) {
    return ListTile(
      key: ValueKey(key),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      // Not while a save runs: its last step closes this page.
      onTap: _saving ? null : () => _openPage(title, body),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _tags != null;
    String? chat, images, agent, web, notes, privacy;
    if (ready) {
      final chatPreset = presetById(_provider);
      final model = _drafts[_provider]?.defaultModel.text.trim() ?? '';
      chat = model.isEmpty ? chatPreset.name : '${chatPreset.name} · $model';
      final imagesPreset =
          _imageProvider.isEmpty ? chatPreset : presetById(_imageProvider);
      images = _infographicProvider.isEmpty ||
              _infographicProvider == imagesPreset.id
          ? imagesPreset.name
          : '${imagesPreset.name} · '
              '${presetById(_infographicProvider).name} (infographics)';
      agent = _editMode.shortLabel;
      web = _webAccess
          ? 'On, at most ${_webSearches.text.trim()} searches'
          : 'Off';
      notes = _languageLine();
      final tags = _tags!.tags;
      privacy = tags.isEmpty ? 'No tags' : tags.join(', ');
    }
    return PopScope(
      // The page asks before it goes with unsaved changes (decision 109).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI settings'),
          actions: [
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.check),
              onPressed: ready && !_saving ? _save : null,
            ),
          ],
        ),
        body: !ready
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  if (_problem case final problem?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text(
                        problem,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  if (_dirty)
                    const ListTile(
                      key: ValueKey('ai-unsaved'),
                      leading: Icon(Icons.edit_note),
                      title: Text('Unsaved changes'),
                      subtitle: Text('Tap the check mark to save them.'),
                    ),
                  _row('ai-chat', Icons.chat_outlined, 'Chat', chat!,
                      _chatSection),
                  _row('ai-images', Icons.image_outlined, 'Images', images!,
                      _imagesSection),
                  _row('ai-agent', Icons.tune, 'Agent and limits', agent!,
                      _agentSection),
                  _row('ai-web', Icons.public, 'Web access', web!,
                      _webSection),
                  _row('ai-speech', Icons.mic_none, 'Speech to text',
                      _speechLine(), _speechSection),
                  _row('ai-notes', Icons.translate, 'Notes', notes!,
                      _notesSection),
                  _row('ai-privacy', Icons.lock_outline, 'Privacy', privacy!,
                      _privacySection),
                ],
              ),
      ),
    );
  }

  /// The models typed on the speech page, those that differ from the
  /// provider's default.
  Map<String, String> _speechModels() => {
        for (final (id, field) in [
          ('mistral', _speechMistralModel),
          ('openai', _speechOpenAiModel),
        ])
          if (field.text.trim().isNotEmpty &&
              field.text.trim() != speechProviderById(id).defaultModel)
            id: field.text.trim(),
      };

  /// What [AiSettings.speechLanguage] would be now.
  String get _speechLanguageValue => _speechLanguageMode == 'code'
      ? languageCode(_speechLanguage.text) ?? _speechLanguage.text.trim()
      : _speechLanguageMode;

  /// The line under "Speech to text".
  String _speechLine() {
    final id = _speechProvider.isEmpty ? 'mistral' : _speechProvider;
    final name = speechProviderById(id).name;
    return _speechProvider.isEmpty ? '$name (automatic)' : name;
  }

  /// "Speech to text" (#221): the provider that turns a shared voice memo
  /// into text, its model, the language and the speaker labels.
  List<Widget> _speechSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mistralDraft = _drafts['mistral'];
    final mistralKey = mistralDraft != null &&
        (mistralDraft.key.text.trim().isNotEmpty ||
            (mistralDraft.hasKey && !mistralDraft.removeKey));
    final openAiKey =
        _openAiKey.text.trim().isNotEmpty || (_openAiKeySaved && !_openAiKeyRemove);
    final effective = _speechProvider.isNotEmpty
        ? _speechProvider
        : (mistralKey || !openAiKey ? 'mistral' : 'openai');
    final provider = speechProviderById(effective);
    return [
      Text(
          'A voice memo shared with the app is sent whole to the provider, '
          'after you agree once for the provider. Recordings of up to 30 '
          'minutes.',
          style: text.bodySmall),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        key: ValueKey('speech-provider-$_speechProvider'),
        initialValue: _speechProvider,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Provider'),
        items: [
          const DropdownMenuItem(
              value: '',
              child: Text('Automatic (Mistral when its key is set)')),
          for (final p in speechProviders)
            DropdownMenuItem(value: p.id, child: Text(p.name)),
        ],
        onChanged: (id) => setState(() => _speechProvider = id ?? ''),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('${provider.name}: ${provider.where} '
            'Price: ${provider.price}.'),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('speech-model-mistral'),
        controller: _speechMistralModel,
        decoration: const InputDecoration(
          labelText: 'Mistral model',
          helperText: 'Voxtral; the preset is voxtral-mini-latest. The key '
              'is the one of Mistral under Chat.',
          helperMaxLines: 2,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
            mistralKey
                ? 'A Mistral key is set.'
                : 'No Mistral key is set. Set one under Chat → Mistral.',
            key: const ValueKey('speech-mistral-key'),
            style: text.bodySmall),
      ),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('speech-model-openai'),
        controller: _speechOpenAiModel,
        decoration: const InputDecoration(
          labelText: 'OpenAI model',
          helperText: 'For example gpt-4o-mini-transcribe or whisper-1.',
        ),
      ),
      TextField(
        key: const ValueKey('speech-key-openai'),
        controller: _openAiKey,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'OpenAI API key (for speech to text only)',
          helperText: _openAiKeySaved && !_openAiKeyRemove
              ? 'A key is saved. Type a new one to replace it.'
              : "Kept in Android's secure storage, never in the notes.",
          helperMaxLines: 2,
        ),
      ),
      if (_openAiKeySaved && !_openAiKeyRemove)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _openAiKeyRemove = true),
            child: const Text('Remove the saved key'),
          ),
        ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: ValueKey('speech-language-$_speechLanguageMode'),
        initialValue: _speechLanguageMode,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Language'),
        items: [
          DropdownMenuItem(
              value: '',
              child: Text('Language of new notes (${_languageLine()})',
                  overflow: TextOverflow.ellipsis)),
          const DropdownMenuItem(
              value: speechLanguageAuto, child: Text('Automatic')),
          const DropdownMenuItem(value: 'code', child: Text('A language code')),
        ],
        onChanged: (mode) =>
            setState(() => _speechLanguageMode = mode ?? ''),
      ),
      if (_speechLanguageMode == 'code')
        TextField(
          key: const ValueKey('speech-language-code'),
          controller: _speechLanguage,
          decoration: const InputDecoration(
              labelText: 'Language code', helperText: 'For example en or de.'),
        ),
      SwitchListTile(
        key: const ValueKey('speech-speakers'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Speakers'),
        subtitle: const Text('Label the speakers in the text (Speaker 1: …), '
            'where the provider can: Mistral. With labels, Mistral is not '
            'given a language.'),
        value: _speechSpeakers,
        onChanged: (on) => setState(() => _speechSpeakers = on),
      ),
    ];
  }

  /// "Privacy": the tags that hide notes from AI (#57).
  List<Widget> _privacySection(BuildContext context) => [
        TagField(
          key: const ValueKey('hidden-tags'),
          controller: _tags!,
          known: _known,
          label: 'Hidden from AI: tags',
          helperText: 'Notes with one of these tags are never '
              'shared with an AI, nor shown to one. Headings with '
              'one of them are left out of the notes that are.',
        ),
        DropdownButtonFormField<int>(
          key: const ValueKey('keep-chats'),
          initialValue: _keepChats,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Keep chats for',
            helperText: 'Chats are kept on this device only. Older chats '
                'are deleted when the app starts.',
          ),
          items: [
            for (final (days, label) in keepChatsChoices)
              DropdownMenuItem(value: days, child: Text(label)),
          ],
          onChanged: (days) {
            if (days != null) setState(() => _keepChats = days);
          },
        ),
      ];

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
        final images = which == 'image' || which == 'infographic';
        var models = const <ModelInfo>[];
        final id = await ModelPickerScreen.open(
          context,
          provider: preset.name,
          euOnly: preset.euSwitch && draft.euOnly,
          images: images,
          providerId: preset.id,
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
            // chat; OpenRouter's Images API takes them all (#112); Qwen's
            // are asked through DashScope, Mistral's through its tool.
            if (images) {
              final model = models.where((m) => m.id == id).firstOrNull;
              final api = preset.imageApi.ownProvider
                  ? preset.imageApi
                  : preset.id != 'openrouter' &&
                          model?.chat == true &&
                          model?.images == true
                      ? ImageApi.chat
                      : ImageApi.images;
              if (which == 'image') {
                draft.imageApi = api;
              } else {
                draft.infographicApi = api;
              }
            }
          });
        }
        // The list is fetched now: check the models against it.
        if (mounted) {
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
        draft.infographicModel,
      ]),
      builder: (context, _) {
        final differs = draft.baseUrl.text.trim() != base.baseUrl ||
            draft.defaultModel.text.trim() != base.defaultModel ||
            draft.strongModel.text.trim() != base.strongModel ||
            (preset.makesImages &&
                (draft.imageModel.text.trim() != base.imageModel ||
                    draft.imageApi != base.imageApi ||
                    draft.infographicModel.text.trim() !=
                        base.infographicModel ||
                    draft.infographicApi != base.infographicApi)) ||
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
              draft.infographicModel.text = base.infographicModel;
              draft.infographicApi = base.infographicApi;
              draft.euOnly = base.euOnly;
            }),
          ),
        );
      },
    );
  }

  /// The image model and how it is asked, for [preset] (#112); with
  /// [infographic], the model for infographics (#183).
  List<Widget> _imageFields(ProviderPreset preset, _Draft draft,
      {bool infographic = false}) {
    final which = infographic ? 'infographic' : 'image';
    final field = infographic ? draft.infographicModel : draft.imageModel;
    final api = infographic ? draft.infographicApi : draft.imageApi;
    return [
      if (preset.makesImages) ...[
        ListenableBuilder(
          listenable: field,
          builder: (context, _) => TextField(
            key: ValueKey('$which-model-${preset.id}'),
            controller: field,
            decoration: InputDecoration(
              labelText: infographic
                  ? 'Infographic model'
                  : 'Image model (optional)',
              helperText: infographic
                  ? 'For infographics: in the chat and in "Create image".'
                  : 'For "Create image" in a note\'s edit menu.',
              errorText: modelGoneMessage(
                  preset.name, field.text, _listedNow(preset.id)),
              errorMaxLines: 3,
              suffixIcon: _chooseModel(preset, draft, field, which),
            ),
          ),
        ),
        DropdownButtonFormField<ImageApi>(
          // Keyed by the value, so a model chosen from the list shows here.
          key: ValueKey('$which-api-${preset.id}-${api.name}'),
          initialValue: api,
          isExpanded: true,
          decoration:
              const InputDecoration(labelText: 'How the image model is asked'),
          items: [
            // Qwen only through DashScope and Mistral only through its
            // image tool; the others never through these.
            for (final kind in ImageApi.values)
              if (kind.ownProvider
                  ? kind == preset.imageApi
                  : !preset.imageApi.ownProvider)
                DropdownMenuItem(
                    value: kind,
                    child: Text(kind.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (kind) => setState(() {
            if (infographic) {
              draft.infographicApi = kind ?? draft.infographicApi;
            } else {
              draft.imageApi = kind ?? draft.imageApi;
            }
          }),
        ),
      ] else
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('${preset.name} cannot make images in the app.',
              key: ValueKey('no-images-${preset.id}'),
              style: Theme.of(context).textTheme.bodySmall),
        ),
    ];
  }

  /// The API key of [preset].
  List<Widget> _keyFields(ProviderPreset preset, _Draft draft) {
    return [
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
    ];
  }

  /// "EU only" of [preset], where it has the switch.
  List<Widget> _euFields(
      ProviderPreset preset, _Draft draft, String switchKey) {
    return [
      if (preset.euSwitch)
        SwitchListTile(
          key: ValueKey(switchKey),
          contentPadding: EdgeInsets.zero,
          value: draft.euOnly,
          onChanged: (on) => setState(() {
            draft.euOnly = on;
            // The default image model follows: one with an EU route
            // while "EU only" is on (#127).
            final (from, to, api) = on
                ? (preset.imageModel, preset.euImageModel, preset.euImageApi)
                : (preset.euImageModel, preset.imageModel, preset.imageApi);
            if (preset.euImageModel.isNotEmpty &&
                draft.imageModel.text.trim() == from) {
              draft.imageModel.text = to;
              draft.imageApi = api;
            }
            if (preset.euImageModel.isNotEmpty &&
                draft.infographicModel.text.trim() == from) {
              draft.infographicModel.text = to;
              draft.infographicApi = api;
            }
          }),
          title: const Text('EU only'),
          subtitle: const Text('Inference and stored data in the EU; models '
              'without an EU route then fail.'),
        ),
    ];
  }

  /// "Images with:" (#127): the provider "Create image" uses, the chat's
  /// by default; another one shows its own image model, key and "EU only"
  /// here.
  List<Widget> _imageProviderSection(BuildContext context) {
    final chat = presetById(_provider);
    final other = _imageProvider.isEmpty || _imageProvider == _provider
        ? null
        : presetById(_imageProvider);
    return [
      const SizedBox(height: 16),
      Text('Create image: provider',
          style: Theme.of(context).textTheme.titleMedium),
      DropdownButtonFormField<String>(
        key: ValueKey('image-provider-$_imageProvider'),
        initialValue: _imageProvider,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Images with:',
          helperText: 'Only the description and the note\'s title go to it, '
              'when I tap "Make image".',
          helperMaxLines: 2,
        ),
        items: [
          DropdownMenuItem(
              value: '',
              child: Text('Same as the chat (${chat.name})',
                  overflow: TextOverflow.ellipsis)),
          for (final p in imageProviders)
            DropdownMenuItem(
                value: p.id,
                child: Text(p.name, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (id) async {
          if (id == null) return;
          if (id.isNotEmpty) await _draft(id);
          if (mounted) setState(() => _imageProvider = id);
          if (mounted && id.isNotEmpty) unawaited(_checkModels(id));
        },
      ),
      if (other != null) ...[
        const SizedBox(height: 8),
        Text(other.note, key: const ValueKey('image-provider-note')),
        ..._imageFields(other, _drafts[other.id]!),
        ..._keyFields(other, _drafts[other.id]!),
        ..._euFields(other, _drafts[other.id]!, 'eu-only-image'),
      ] else ...[
        // The chat's provider: its image model is set here, its key and
        // "EU only" under Chat.
        ..._imageFields(chat, _drafts[_provider]!),
        if (chat.makesImages)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                'The key and "EU only" of ${chat.name} are set under Chat.',
                key: const ValueKey('image-key-chat'),
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    ];
  }

  /// "Infographics with:" (#183): the provider and image model for
  /// pictures with text and numbers; by default those of "Images with:".
  /// A provider not shown above also shows its key and "EU only" here.
  List<Widget> _infographicSection(BuildContext context) {
    final images = presetById(
        _imageProvider.isEmpty ? _provider : _imageProvider);
    final chosen = _infographicProvider.isEmpty
        ? null
        : presetById(_infographicProvider);
    final shownAbove = chosen != null &&
        (chosen.id == _provider || chosen.id == _imageProvider);
    return [
      const SizedBox(height: 16),
      Text('Create image: infographics',
          style: Theme.of(context).textTheme.titleMedium),
      DropdownButtonFormField<String>(
        key: ValueKey('infographic-provider-$_infographicProvider'),
        initialValue: _infographicProvider,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Infographics with:',
          helperText: 'For pictures with text and numbers. GPT Image and '
              'Gemini Image set text well; FLUX (Mistral) does not.',
          helperMaxLines: 3,
        ),
        items: [
          DropdownMenuItem(
              value: '',
              child: Text('Same as "Images with:" (${images.name})',
                  overflow: TextOverflow.ellipsis)),
          for (final p in imageProviders)
            DropdownMenuItem(
                value: p.id,
                child: Text(p.name, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (id) async {
          if (id == null) return;
          if (id.isNotEmpty) await _draft(id);
          if (mounted) setState(() => _infographicProvider = id);
          if (mounted && id.isNotEmpty) unawaited(_checkModels(id));
        },
      ),
      if (chosen != null) ...[
        const SizedBox(height: 8),
        if (!shownAbove)
          Text(chosen.note, key: const ValueKey('infographic-provider-note')),
        ..._imageFields(chosen, _drafts[chosen.id]!, infographic: true),
        if (shownAbove)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                'The key and "EU only" of ${chosen.name} are set above or '
                'under Chat.',
                key: const ValueKey('infographic-key-above'),
                style: Theme.of(context).textTheme.bodySmall),
          )
        else ...[
          ..._keyFields(chosen, _drafts[chosen.id]!),
          ..._euFields(chosen, _drafts[chosen.id]!, 'eu-only-infographic'),
        ],
      ],
    ];
  }

  /// "Chat": the provider with its key, base URL, models and "EU only".
  List<Widget> _chatSection(BuildContext context) {
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
                preset.name, draft.defaultModel.text, _listedNow(preset.id)),
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
                preset.name, draft.strongModel.text, _listedNow(preset.id)),
            errorMaxLines: 3,
            suffixIcon:
                _chooseModel(preset, draft, draft.strongModel, 'strong'),
          ),
        ),
      ),
      // With another image provider, "Images" shows that one's image model;
      // the chat provider's own stays here.
      if (_imageProvider.isNotEmpty && _imageProvider != _provider)
        ..._imageFields(preset, draft),
      _resetModels(preset, draft),
      ..._keyFields(preset, draft),
      ..._euFields(preset, draft, 'eu-only'),
    ];
  }

  /// "Images": "Images with:" and "Infographics with:" (#127, #183).
  List<Widget> _imagesSection(BuildContext context) => [
        ..._imageProviderSection(context),
        ..._infographicSection(context),
      ];

  /// "Notes": the language of new notes (#172).
  List<Widget> _notesSection(BuildContext context) {
    return [
      TextField(
        key: const ValueKey('new-note-language'),
        controller: _language,
        decoration: const InputDecoration(
          labelText: 'Language of new notes',
          helperText: 'The language code the AI writes new notes in, as '
              '#+language:, when neither my request, the note they start '
              'from nor its linked notes decide it.',
          helperMaxLines: 3,
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final MapEntry(key: code, value: name)
              in commonLanguages.entries)
            ActionChip(
              key: ValueKey('new-note-language-$code'),
              label: Text('$name ($code)'),
              onPressed: () => setState(() => _language.text = code),
            ),
        ],
      ),
    ];
  }

  /// "Web access": the switch and the most web searches (#137).
  List<Widget> _webSection(BuildContext context) {
    return [
      SwitchListTile(
        key: const ValueKey('web-access'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Web access for the AI'),
        subtitle: const Text(
            'The chat may search the web and read web pages. Search words '
            'go to the provider (Anthropic searches itself); pages are '
            'fetched from this phone, over https only, never from the '
            'own network. Notes hidden from AI stay hidden.'),
        value: _webAccess,
        onChanged: (on) => setState(() => _webAccess = on),
      ),
      TextField(
        key: const ValueKey('max-web-searches'),
        controller: _webSearches,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Most web searches for one message',
          helperText: 'Each page the AI reads counts as one too.',
        ),
      ),
    ];
  }

  /// "Agent and limits": what the AI may change, and the most it may do
  /// for one message.
  List<Widget> _agentSection(BuildContext context) {
    return [
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
        key: const ValueKey('max-images'),
        controller: _images,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Most images the agent may make for one message',
          helperText: 'Each image costs money at the image provider.',
        ),
      ),
      TextField(
        key: const ValueKey('max-parallel-chats'),
        controller: _parallel,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Most chats working at the same time',
          helperText: 'A further message waits until one of them is done.',
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
      SwitchListTile(
        key: const ValueKey('notify-answers'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Notify when an answer is ready'),
        subtitle: const Text(
            'A notification when a chat that is not on screen has its '
            'answer, or fails. A tap opens the chat.'),
        value: _notifyAnswers,
        onChanged: (on) => setState(() => _notifyAnswers = on),
      ),
      if (_notifyAnswers) const NotificationPermissionLine(),
    ];
  }
}

/// The line under "Notify when an answer is ready" when Android does not
/// allow notifications for the app (#202): chats still work, without them.
/// It checks again when the app comes back from Android's settings.
class NotificationPermissionLine extends StatefulWidget {
  const NotificationPermissionLine({super.key});

  @override
  State<NotificationPermissionLine> createState() =>
      _NotificationPermissionLineState();
}

class _NotificationPermissionLineState extends State<NotificationPermissionLine>
    with WidgetsBindingObserver {
  Future<bool>? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _granted = _check());
    }
  }

  Future<bool> _check() async {
    final store = ChatStoreScope.maybeOf(context);
    if (store == null) return true;
    try {
      return await store.notifier.permissionGranted();
    } on Exception {
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isDesktop) return const SizedBox.shrink();
    return FutureBuilder<bool>(
      future: _granted ??= _check(),
      builder: (context, snapshot) {
        if (snapshot.data != false) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey('notify-denied'),
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Android does not allow notifications about answers for this app: '
            'its notifications, or its "Answers" category, are switched off. '
            'Chats still work, but without a notification. Allow them in '
            'Android\'s settings for this app.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
        );
      },
    );
  }
}
