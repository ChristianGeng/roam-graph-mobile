/// The AI providers the settings offer (#59), as plain data, so the list
/// can change without touching the chat's logic. Base URLs, model IDs and
/// notes were checked against each provider's documentation on
/// 2026-10-17; a model is left empty where its ID could not be checked.
///
/// Pure Dart (no Flutter).
library;

/// The two APIs the app speaks.
enum ApiKind {
  /// Anthropic's Messages API: `POST <base>/v1/messages`, `x-api-key`.
  anthropic('Anthropic Messages API'),

  /// OpenAI's Chat Completions API, which many providers offer:
  /// `POST <base>/chat/completions`, `Authorization: Bearer`.
  openAi('OpenAI-compatible Chat Completions');

  const ApiKind(this.label);

  final String label;
}

/// A provider with its defaults; every value can be changed in the
/// settings.
class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.name,
    required this.api,
    this.baseUrl = '',
    this.defaultModel = '',
    this.strongModel = '',
    required this.note,
    this.dataStaysInEu = false,
    this.euSwitch = false,
    this.keyHint = 'API key',
  });

  /// Stable, for the saved settings and the key store.
  final String id;
  final String name;
  final ApiKind api;
  final String baseUrl;

  /// The model a chat starts with.
  final String defaultModel;

  /// A stronger model the chat can switch to; empty when there is none.
  final String strongModel;

  /// One line on where the data goes and what that means, shown when the
  /// provider is chosen.
  final String note;

  /// Whether the data stays in the EU: the settings list these first.
  final bool dataStaysInEu;

  /// Whether the provider has an "EU only" switch (Vercel AI Gateway).
  /// With it on, the data stays in the EU, for models with an EU route.
  final bool euSwitch;

  /// What the key field is called, for providers whose key has another
  /// name.
  final String keyHint;
}

/// The presets, those whose data stays in the EU first. Haiku and other
/// small models are no default anywhere: the chat may propose notes to
/// save; any model can still be typed in.
const providerPresets = <ProviderPreset>[
  ProviderPreset(
    id: 'bedrock-eu',
    name: 'Claude on AWS Bedrock (EU)',
    api: ApiKind.anthropic,
    baseUrl: 'https://bedrock-runtime.eu-central-1.amazonaws.com/anthropic',
    defaultModel: 'eu.anthropic.claude-sonnet-5-5',
    strongModel: 'eu.anthropic.claude-opus-5-5',
    note: 'Stays in the EU with the EU inference profile (about 10 % more); '
        'AWS is a US company (CLOUD Act).',
    dataStaysInEu: true,
    keyHint: 'Bedrock API key (AWS recommends short-lived keys)',
  ),
  ProviderPreset(
    id: 'mistral',
    name: 'Mistral',
    api: ApiKind.openAi,
    baseUrl: 'https://api.mistral.ai/v1',
    defaultModel: 'mistral-large-4',
    note: 'Best value in the EU (Mistral Large 4, in public preview). EU '
        'company, EU processing; no training on paid use; abuse logs kept '
        '30 days.',
    dataStaysInEu: true,
  ),
  ProviderPreset(
    id: 'scaleway',
    name: 'Scaleway',
    api: ApiKind.openAi,
    baseUrl: 'https://api.scaleway.ai/v1',
    note: 'French company, EU processing, prompts not kept by default; open '
        'models only. Pick a model from its list.',
    dataStaysInEu: true,
  ),
  ProviderPreset(
    id: 'vercel',
    name: 'Vercel AI Gateway',
    api: ApiKind.openAi,
    baseUrl: 'https://ai-gateway.vercel.sh/v1',
    note: 'US company; with "EU only" on, inference and stored data stay in '
        'the EU, for models with an EU route (others fail).',
    euSwitch: true,
  ),
  ProviderPreset(
    id: 'anthropic',
    name: 'Anthropic',
    api: ApiKind.anthropic,
    baseUrl: 'https://api.anthropic.com',
    defaultModel: 'claude-sonnet-5-5',
    strongModel: 'claude-opus-5-5',
    note: 'Safe default (Sonnet 5.5). Processed globally or in the US; a US '
        'company (CLOUD Act); no training on API data by default.',
  ),
  ProviderPreset(
    id: 'deepseek',
    name: 'DeepSeek',
    api: ApiKind.openAi,
    baseUrl: 'https://api.deepseek.com',
    defaultModel: 'deepseek-v4-pro',
    note: 'Best value outside the EU (DeepSeek V4 Pro). Processed and stored '
        'in China; reports say inputs may be used for training; Chinese law '
        'can require access.',
  ),
  ProviderPreset(
    id: 'qwen',
    name: 'Qwen (Alibaba Cloud)',
    api: ApiKind.openAi,
    baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen3.8-max',
    note: 'Singapore; Alibaba says no training on customer data; a Chinese '
        'company. A key works only in its own region.',
  ),
  ProviderPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    api: ApiKind.openAi,
    baseUrl: 'https://openrouter.ai/api/v1',
    note: 'Routes to many providers, whose terms apply; EU-only routing only '
        'on the Business plan; 5.5 % fee on credits.',
  ),
  ProviderPreset(
    id: 'huggingface',
    name: 'Hugging Face',
    api: ApiKind.openAi,
    baseUrl: 'https://router.huggingface.co/v1',
    note: 'Open models from many hosts; the region is not guaranteed; no '
        'cache discount shown, so long chats cost more. Tool calling depends '
        'on the model.',
    keyHint: 'Hugging Face token (with "Make calls to Inference Providers")',
  ),
  ProviderPreset(
    id: 'custom',
    name: 'Custom',
    api: ApiKind.openAi,
    note: 'Any provider with one of the two APIs, for example IONOS, Nebius, '
        'OVHcloud, STACKIT, Infomaniak or a local Ollama. Its terms apply.',
  ),
];

/// The preset with [id], or Anthropic's.
ProviderPreset presetById(String id) => providerPresets.firstWhere(
      (p) => p.id == id,
      orElse: () => providerPresets.firstWhere((p) => p.id == 'anthropic'),
    );
