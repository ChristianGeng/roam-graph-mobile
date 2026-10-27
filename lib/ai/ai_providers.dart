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
    this.imagesPath,
    this.imageModel = '',
    this.imageApi = ImageApi.images,
    this.euImageModel = '',
    this.euImageApi = ImageApi.images,
    this.outsideEu = false,
  });

  /// The default image model while "EU only" is on (#127): one with an EU
  /// route; empty when the provider has none or no "EU only" switch.
  final String euImageModel;

  /// How [euImageModel] is asked.
  final ImageApi euImageApi;

  /// Whether the data is known to be processed outside the EU, for the
  /// line on "Create image" (#127). With [dataStaysInEu] and this both
  /// false, the region is not known.
  final bool outsideEu;

  /// How the preset's image model is asked.
  final ImageApi imageApi;

  /// The image model new images are made with (#112); empty when there is
  /// no default.
  final String imageModel;

  /// Where the provider makes images (#112), after the base URL, as its
  /// documentation says: `/images/generations` (OpenAI's Images API, also
  /// Vercel AI Gateway's), `/images` (OpenRouter's); null where the app
  /// does not make images with this provider.
  final String? imagesPath;

  bool get makesImages => imagesPath != null;

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
    // Mistral's built-in image tool, through its Conversations API (#126).
    imagesPath: '/conversations',
    imageModel: 'mistral-medium-latest',
    imageApi: ImageApi.mistral,
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
    defaultModel: 'deepseek/deepseek-v4-pro',
    imagesPath: '/images/generations',
    // Vercel's documentation names it for the Images API.
    imageModel: 'openai/gpt-image-2',
    // The only image model with an EU route in Vercel's list (checked
    // 2026-10-19), for "EU only" (#127).
    euImageModel: 'google/gemini-2.5-flash-image',
    euImageApi: ImageApi.chat,
    note: 'US company. "EU only" is off, as the default model, '
        'deepseek/deepseek-v4-pro, has no EU route: it is processed outside '
        'the EU. With "EU only" on, inference and stored data stay in the '
        'EU, for models with an EU route; others fail. Checked: '
        'anthropic/claude-sonnet-5.5 works with "EU only"; '
        'mistral/mistral-large-4 and deepseek/deepseek-v4-pro do not.',
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
    outsideEu: true,
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
    outsideEu: true,
  ),
  ProviderPreset(
    id: 'qwen',
    name: 'Qwen (Alibaba Cloud)',
    api: ApiKind.openAi,
    baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen3.8-max',
    // DashScope's own image API, on the same host; Qwen Image 2.0 costs
    // 0.035 USD per image in the Singapore region (checked 2026-10-19).
    imagesPath: '/api/v1/services/aigc/multimodal-generation/generation',
    imageModel: 'qwen-image-2.0',
    imageApi: ImageApi.dashscope,
    note: 'Singapore; Alibaba says no training on customer data; a Chinese '
        'company. A key works only in its own region.',
    outsideEu: true,
  ),
  ProviderPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    api: ApiKind.openAi,
    baseUrl: 'https://openrouter.ai/api/v1',
    // Models that list tools in OpenRouter's model list (checked
    // 2026-10-27); the same default as the Vercel preset, which the app
    // has used for tool calls. See lib/ai/model_advice.dart.
    defaultModel: 'deepseek/deepseek-v4-pro',
    strongModel: 'anthropic/claude-sonnet-5.5',
    imagesPath: '/images',
    // Asked through the Images API (/images); the probe of #177 got an
    // image from it. OpenRouter does not list openai/gpt-image-2.
    imageModel: 'google/gemini-2.5-flash-image',
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
    imagesPath: '/images/generations',
    note: 'Any provider with one of the two APIs, for example IONOS, Nebius, '
        'OVHcloud, STACKIT, Infomaniak or a local Ollama. Its terms apply.',
  ),
];

/// How an image model is asked (#112).
enum ImageApi {
  /// The Images API: `POST <base><imagesPath>`, the image in
  /// `data[].b64_json`. For image-only models (GPT Image, Flux, …).
  images('Images API (image-only models)'),

  /// Chat Completions with `modalities: ["image", "text"]`, the image in
  /// `message.images[].image_url.url` (Vercel AI Gateway). For chat
  /// models that also make images (Gemini Image, …).
  chat('Chat with image output (Gemini Image and similar)'),

  /// Alibaba Cloud's DashScope API for Qwen Image: `POST` to the host's
  /// `imagesPath`, the image as a link in
  /// `output.choices[0].message.content[0].image`, downloaded at once.
  dashscope('DashScope (Qwen Image)'),

  /// Mistral's built-in `image_generation` tool, through an agent that
  /// has it (`POST /v1/agents`, made once) and its Conversations API
  /// (`POST /v1/conversations` with `agent_id`, #126, #163): Chat
  /// Completions answers without an image. The image comes as a file ID for the Files
  /// API (or a link on Mistral's file host), downloaded at once.
  mistral('Mistral image tool');

  const ImageApi(this.label);

  final String label;

  /// Whether only one provider is asked this way, and that provider only
  /// this way.
  bool get ownProvider => this == dashscope || this == mistral;
}

/// The preset with [id], or Anthropic's.
ProviderPreset presetById(String id) => providerPresets.firstWhere(
      (p) => p.id == id,
      orElse: () => providerPresets.firstWhere((p) => p.id == 'anthropic'),
    );
