/// The models the app recommends, as plain data (#190). One list, read by
/// the model picker (badges and the "Recommended" filter), the help page
/// "Choosing a model" (a test keeps the two equal) and the weekly check
/// that every recommended model is still in the provider's list.
///
/// Model IDs were checked against the lists of Mistral, Vercel AI Gateway
/// and OpenRouter on 2026-10-27, and against the provider documentation
/// for the other presets (see `assets/help/models.org`).
///
/// Pure Dart (no Flutter).
library;

/// What a recommended model is good for.
enum AdvicePurpose {
  /// Questions about the notes in the chat.
  chat('chat'),

  /// Edits by the agent: tool calls must work reliably.
  agent('agent'),

  /// A picture from a description, without much text.
  illustration('illustration'),

  /// A designed picture with text, numbers and labels.
  infographic('infographic');

  const AdvicePurpose(this.label);

  final String label;

  /// Whether the purpose is about images.
  bool get isImage => this == illustration || this == infographic;
}

/// A rough price class for a purpose, not a quote.
enum PriceClass {
  cheap('cheap'),
  medium('medium'),
  expensive('expensive');

  const PriceClass(this.label);

  final String label;
}

/// One recommendation: [model] of the provider preset [provider].
class ModelAdvice {
  const ModelAdvice({
    required this.provider,
    required this.model,
    required this.purposes,
    required this.price,
    required this.why,
  });

  /// The `id` of the provider preset.
  final String provider;
  final String model;
  final Set<AdvicePurpose> purposes;
  final PriceClass price;

  /// One short line on why.
  final String why;

  /// Whether the model is recommended for images (else for the chat).
  bool get forImages => purposes.any((p) => p.isImage);

  /// "chat, agent", for the badge and the help page.
  String get purposeLabels => purposes.map((p) => p.label).join(', ');
}

/// The recommendations, in the order the help page shows them.
const modelAdvice = <ModelAdvice>[
  ModelAdvice(
    provider: 'bedrock-eu',
    model: 'eu.anthropic.claude-sonnet-5-5',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.medium,
    why: 'Questions across several notes, with EU processing.',
  ),
  ModelAdvice(
    provider: 'bedrock-eu',
    model: 'eu.anthropic.claude-opus-5-5',
    purposes: {AdvicePurpose.agent},
    price: PriceClass.expensive,
    why: 'Difficult changes.',
  ),
  ModelAdvice(
    provider: 'mistral',
    model: 'mistral-large-4',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.cheap,
    why: 'General choice with EU processing; in public preview.',
  ),
  ModelAdvice(
    provider: 'mistral',
    model: 'mistral-medium-latest',
    purposes: {AdvicePurpose.illustration},
    price: PriceClass.medium,
    why: "Illustrations with EU processing, through Mistral's image tool.",
  ),
  ModelAdvice(
    provider: 'scaleway',
    model: 'qwen3.6-35b-a3b',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.cheap,
    why: 'Straightforward questions and small edits, EU processing.',
  ),
  ModelAdvice(
    provider: 'vercel',
    model: 'deepseek/deepseek-v4-pro',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.cheap,
    why: 'Cheap and calls tools; no EU route.',
  ),
  ModelAdvice(
    provider: 'vercel',
    model: 'anthropic/claude-sonnet-5.5',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.medium,
    why: 'Harder comparisons and edits; works with "EU only".',
  ),
  ModelAdvice(
    provider: 'vercel',
    model: 'openai/gpt-image-1-mini',
    purposes: {AdvicePurpose.illustration},
    price: PriceClass.cheap,
    why: 'The cheapest GPT Image model, for plain illustrations.',
  ),
  ModelAdvice(
    provider: 'vercel',
    model: 'openai/gpt-image-2',
    purposes: {AdvicePurpose.illustration, AdvicePurpose.infographic},
    price: PriceClass.expensive,
    why: 'Detailed pictures; sets text well.',
  ),
  ModelAdvice(
    provider: 'vercel',
    model: 'google/gemini-2.5-flash-image',
    purposes: {AdvicePurpose.illustration, AdvicePurpose.infographic},
    price: PriceClass.medium,
    why: 'Quick pictures with readable text; has an EU route.',
  ),
  ModelAdvice(
    provider: 'anthropic',
    model: 'claude-sonnet-5-5',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.medium,
    why: 'A safe starting point for questions and tool calls.',
  ),
  ModelAdvice(
    provider: 'anthropic',
    model: 'claude-opus-5-5',
    purposes: {AdvicePurpose.agent},
    price: PriceClass.expensive,
    why: 'Complex changes and difficult reasoning.',
  ),
  ModelAdvice(
    provider: 'deepseek',
    model: 'deepseek-v4-pro',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.cheap,
    why: 'Cheap; processed and stored in China.',
  ),
  ModelAdvice(
    provider: 'qwen',
    model: 'qwen3.8-max',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.medium,
    why: 'General questions and edits through its tools; Singapore.',
  ),
  ModelAdvice(
    provider: 'qwen',
    model: 'qwen-image-2.0',
    purposes: {AdvicePurpose.illustration},
    price: PriceClass.cheap,
    why: "Straightforward illustrations through Qwen's own image API.",
  ),
  ModelAdvice(
    provider: 'openrouter',
    model: 'deepseek/deepseek-v4-pro',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.cheap,
    why: 'Cheap and lists tools; the default.',
  ),
  ModelAdvice(
    provider: 'openrouter',
    model: 'anthropic/claude-sonnet-5.5',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.medium,
    why: 'Comparisons across notes and careful edits; the strong model.',
  ),
  ModelAdvice(
    provider: 'openrouter',
    model: 'google/gemini-2.5-flash-image',
    purposes: {AdvicePurpose.illustration, AdvicePurpose.infographic},
    price: PriceClass.medium,
    why: 'Quick pictures with readable text, through the Images API.',
  ),
  ModelAdvice(
    provider: 'huggingface',
    model: 'Qwen/Qwen3-Coder-480B-A35B-Instruct',
    purposes: {AdvicePurpose.chat, AdvicePurpose.agent},
    price: PriceClass.medium,
    why: 'Needs tools; tool support depends on the host.',
  ),
];

/// The recommendations for the preset [provider].
List<ModelAdvice> adviceForProvider(String provider) => [
      for (final a in modelAdvice)
        if (a.provider == provider) a,
    ];

/// The recommendation for [model] of [provider] that fits the picker:
/// for image models when [images], else for chat models; null when there
/// is none.
ModelAdvice? adviceForModel(
  String provider,
  String model, {
  required bool images,
}) {
  for (final a in modelAdvice) {
    if (a.provider == provider && a.model == model && a.forImages == images) {
      return a;
    }
  }
  return null;
}
