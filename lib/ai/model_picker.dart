import 'package:material_ui/material_ui.dart';

import 'ai_chat.dart';
import 'ai_models.dart';

/// A searchable list of a provider's models (#75); picking one returns
/// its ID. The list is fetched by the caller's [load].
class ModelPickerScreen extends StatefulWidget {
  const ModelPickerScreen({
    super.key,
    required this.provider,
    required this.load,
    this.euOnly = false,
  });

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
  }) => Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) =>
          ModelPickerScreen(provider: provider, load: load, euOnly: euOnly),
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
    bool usable(ModelInfo m) =>
        m.chat != false && (!knowsTools || m.tools == true);
    final hidden =
        (models ?? const <ModelInfo>[]).where((m) => !usable(m)).length;
    final shown = [
      for (final m in models ?? const <ModelInfo>[])
        if (_all || usable(m))
          if (words.every('${m.id} ${m.name ?? ''}'.toLowerCase().contains)) m,
    ];
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
                if (hidden > 0)
                  SwitchListTile(
                    key: const ValueKey('model-all'),
                    value: _all,
                    onChanged: (on) => setState(() => _all = on),
                    title: Text('Also other models ($hidden)'),
                    subtitle: const Text(
                      'Models without tools, and models that do not chat, '
                      'such as embedding or image models. The chat needs a '
                      'chat model that calls tools to read and change notes.',
                    ),
                  ),
                if (!knowsTools)
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
                      final details = [
                        ?m.name,
                        if (m.inputPrice != null && m.outputPrice != null)
                          '\$${_price(m.inputPrice!)} in, '
                              '\$${_price(m.outputPrice!)} out per '
                              'million tokens',
                        if (m.chat == false) 'no chat model',
                        if (m.tools == false) 'no tools',
                        if (m.tools == null && m.chat != false)
                          'tools not known',
                        if (noEu) 'no EU route: fails with "EU only"',
                      ].join(' · ');
                      return ListTile(
                        key: ValueKey('model-${m.id}'),
                        enabled: !noEu,
                        title: Text(m.id),
                        subtitle: details.isEmpty ? null : Text(details),
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
