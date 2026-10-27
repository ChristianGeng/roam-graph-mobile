import 'package:material_ui/material_ui.dart';

import 'ai_chat.dart';
import 'ai_models.dart';
import 'model_advice.dart';

/// A searchable list of a provider's models (#75); picking one returns
/// its ID. The list is fetched by the caller's [load].
class ModelPickerScreen extends StatefulWidget {
  const ModelPickerScreen({
    super.key,
    required this.provider,
    required this.load,
    this.euOnly = false,
    this.images = false,
    this.providerId = '',
  });

  /// The `id` of the provider preset, to mark its recommended models
  /// (#190); empty for none.
  final String providerId;

  /// Lists image models instead of chat models (#112).
  final bool images;

  final String provider;
  final Future<List<ModelInfo>> Function({bool refresh}) load;

  /// Vercel AI Gateway's "EU only": models without an EU route fail.
  final bool euOnly;

  /// Opens the picker; completes with the chosen ID, or null.
  static Future<String?> open(
    BuildContext context, {
    required String provider,
    required Future<List<ModelInfo>> Function({bool refresh}) load,
    bool euOnly = false,
    bool images = false,
    String providerId = '',
  }) => Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => ModelPickerScreen(
        provider: provider,
        load: load,
        euOnly: euOnly,
        images: images,
        providerId: providerId,
      ),
    ),
  );

  @override
  State<ModelPickerScreen> createState() => _ModelPickerScreenState();
}

class _ModelPickerScreenState extends State<ModelPickerScreen> {
  final _query = TextEditingController();
  List<ModelInfo>? _models;
  String? _error;
  bool _all = false;
  bool _byPrice = false;
  bool _onlyRecommended = false;
  bool _onlyTools = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    _fetch();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool refresh = false}) async {
    setState(() {
      _models = null;
      _error = null;
    });
    try {
      final models = await widget.load(refresh: refresh);
      if (mounted) setState(() => _models = models);
    } on AiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      // Anything else still ends the spinner, with a message.
      if (mounted) {
        setState(() => _error = 'The model list could not be fetched: $e');
      }
    }
  }

  String _price(double value) => value < 1
      ? value.toStringAsFixed(2)
      : value.toStringAsFixed(value < 10 ? 1 : 0);

  // Keep every decimal the list supplied; small prices must not become zero.
  String _imagePrice(double value) {
    final text = value.toString();
    return text.contains('e') || text.split('.').last.length > 2
        ? text
        : value.toStringAsFixed(2);
  }

  int _compareImagePrices(ModelInfo a, ModelInfo b) {
    // Dollars per image and dollars per million tokens cannot be compared.
    // Put image prices first, token prices next, and unknown prices last.
    int group(ModelInfo m) => m.imagePrice != null
        ? 0
        : m.inputPrice != null && m.outputPrice != null
        ? 1
        : 2;
    final category = group(a).compareTo(group(b));
    if (category != 0) return category;
    final cost = switch (group(a)) {
      0 => a.imagePrice!.compareTo(b.imagePrice!),
      1 => a.outputPrice!.compareTo(b.outputPrice!),
      _ => 0,
    };
    return cost != 0 ? cost : a.id.compareTo(b.id);
  }

  // Chat models by output price, unknown prices last (OpenRouter's list).
  int _compareChatPrices(ModelInfo a, ModelInfo b) {
    final pa = a.outputPrice;
    final pb = b.outputPrice;
    if (pa == null || pb == null) {
      if (pa != null) return -1;
      if (pb != null) return 1;
      return a.id.compareTo(b.id);
    }
    final cost = pa.compareTo(pb);
    return cost != 0 ? cost : a.id.compareTo(b.id);
  }

  @override
  Widget build(BuildContext context) {
    final models = _models;
    final theme = Theme.of(context);
    // Where the list says which models call tools, only those first: the
    // chat needs them.
    final knowsTools = models?.any((m) => m.tools != null) ?? false;
    final knowsRegions = models?.any((m) => m.regions != null) ?? false;
    final words = [
      for (final w in _query.text.toLowerCase().split(RegExp(r'\s+')))
        if (w.isNotEmpty) w,
    ];
    // By default only what the chat can use (#110): chat models, and where
    // the list says which call tools, only those that do. A list that
    // never says shows its chat models, marked.
    // For images (#112): the models that make them.
    bool usable(ModelInfo m) => widget.images
        ? m.images == true
        : m.chat != false && (!knowsTools || m.tools == true);
    final hidden =
        (models ?? const <ModelInfo>[]).where((m) => !usable(m)).length;
    ModelAdvice? adviceOf(ModelInfo m) => widget.providerId.isEmpty
        ? null
        : adviceForModel(widget.providerId, m.id, images: widget.images);
    final hasAdvice = widget.providerId.isNotEmpty &&
        (models ?? const <ModelInfo>[]).any((m) => adviceOf(m) != null);
    // OpenRouter: a filter for tools and an order by price, for chat too.
    final openRouter = widget.providerId == 'openrouter';
    final canOrder = widget.images || openRouter;
    final showToolsChip = openRouter && !widget.images && knowsTools;
    final found = [
      for (final m in models ?? const <ModelInfo>[])
        if (_all || usable(m))
          if (words.every('${m.id} ${m.name ?? ''}'.toLowerCase().contains)) m,
    ];
    if (_byPrice && widget.images) found.sort(_compareImagePrices);
    if (_byPrice && !widget.images && openRouter) {
      found.sort(_compareChatPrices);
    }
    // Recommended models first, in the order chosen.
    final shown = [
      ...found.where((m) => adviceOf(m) != null),
      if (!_onlyRecommended) ...found.where((m) => adviceOf(m) == null),
    ];
    if (_onlyTools) shown.removeWhere((m) => m.tools != true);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const ValueKey('model-search'),
          controller: _query,
          decoration: InputDecoration(
            hintText: 'Search models of ${widget.provider}',
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Fetch again',
            icon: const Icon(Icons.refresh),
            onPressed: models == null && _error == null
                ? null
                : () => _fetch(refresh: true),
          ),
        ],
      ),
      body: _error != null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '$_error\n\nGo back and type the model instead.',
                key: const ValueKey('model-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          : models == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (hasAdvice || showToolsChip)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          if (hasAdvice)
                            FilterChip(
                              key: const ValueKey('model-recommended'),
                              label: const Text('Recommended'),
                              selected: _onlyRecommended,
                              onSelected: (on) =>
                                  setState(() => _onlyRecommended = on),
                            ),
                          if (showToolsChip)
                            FilterChip(
                              key: const ValueKey('model-tools'),
                              label: const Text('Calls tools'),
                              selected: _onlyTools,
                              onSelected: (on) =>
                                  setState(() => _onlyTools = on),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (canOrder)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text('Order: '),
                        Expanded(
                          child: DropdownButton<bool>(
                            key: const ValueKey('model-order'),
                            value: _byPrice,
                            isExpanded: true,
                            onChanged: (value) =>
                                setState(() => _byPrice = value ?? false),
                            items: const [
                              DropdownMenuItem(
                                value: false,
                                child: Text('Model ID'),
                              ),
                              DropdownMenuItem(
                                value: true,
                                child: Text('Price (lowest first)'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (widget.images && _byPrice)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('Per-image prices first, then token prices '
                        'by output price; unknown prices last. '
                        'These units cannot be compared.'),
                  ),
                if (!widget.images && _byPrice)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('By output price per million tokens; '
                        'unknown prices last.'),
                  ),
                if (hidden > 0)
                  SwitchListTile(
                    key: const ValueKey('model-all'),
                    value: _all,
                    onChanged: (on) => setState(() => _all = on),
                    title: Text('Also other models ($hidden)'),
                    subtitle: Text(widget.images
                        ? 'Models the list does not name as image models.'
                        : 'Models without tools, and models that do not chat, '
                            'such as embedding or image models. The chat needs '
                            'a chat model that calls tools to read and change '
                            'notes.'),
                  ),
                if (!knowsTools && !widget.images)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      'This list does not say which models call tools; '
                      'a model without them cannot read the notes.',
                    ),
                  ),
                if (widget.euOnly && !knowsRegions)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      'With "EU only" on, a model without an '
                      'EU route fails; this list does not say which.',
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${shown.length} of ${models.length} models',
                      key: const ValueKey('model-count'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final m = shown[i];
                      // Vercel: a model without regions has no regional route.
                      final noEu =
                          widget.euOnly &&
                          (m.inEu == false ||
                              (knowsRegions && m.regions == null));
                      final advice = adviceOf(m);
                      final details = [
                        ?m.name,
                        if (widget.images && m.imagePrice != null)
                          '${m.imagePriceFrom ? 'from ' : ''}'
                              '\$${_imagePrice(m.imagePrice!)} per image'
                        else if (m.inputPrice != null && m.outputPrice != null)
                          '\$${_price(m.inputPrice!)} in, '
                              '\$${_price(m.outputPrice!)} out per '
                              'million tokens'
                        else if (widget.images)
                          "price not in the provider's list",
                        if (!widget.images) ...[
                          if (m.chat == false) 'no chat model',
                          if (m.tools == false) 'no tools',
                          if (m.tools == null && m.chat != false)
                            'tools not known',
                        ] else if (m.images == true && m.chat == true)
                          'chat model with image output',
                        if (noEu) 'no EU route: fails with "EU only"',
                      ].join(' · ');
                      return ListTile(
                        key: ValueKey('model-${m.id}'),
                        enabled: !noEu,
                        title: Text(m.id),
                        subtitle: details.isEmpty && advice == null
                            ? null
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (details.isNotEmpty) Text(details),
                                  if (advice != null)
                                    Text(
                                      'Recommended: ${advice.purposeLabels}'
                                      ' · ${advice.price.label}'
                                      ' · ${advice.why}',
                                      key: ValueKey('badge-${m.id}'),
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                ],
                              ),
                        onTap: () => Navigator.pop(context, m.id),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
