import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../graph/roam_graph.dart';
import 'ai_chat.dart';
import 'ai_settings.dart';
import 'ai_tools.dart';

/// Opens a node by its ID, from a link in an answer.
typedef OpenNode = void Function(BuildContext context, String id);

/// The AI chat (#60): I ask, the model reads the graph with the tools of
/// my org-roam MCP server (#58) through the provider of the AI settings
/// (#59), and answers. Its tool calls are shown, `id:` links in answers
/// open the node, and an answer can become a new node through the capture
/// screen, so I review it before anything is written. The conversation is
/// kept only while the screen is open.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.graph,
    required this.readNote,
    this.startNode,
    this.writer,
    this.openNode,
    this.post = postWithDartIo,
  });

  final ValueListenable<RoamGraph> graph;
  final NoteTextReader readNote;

  /// The node the chat was opened from; the first message names it.
  final RoamNode? startNode;

  /// Writes new nodes; without it, there is no "Save as new node".
  final NoteWriter? writer;

  /// Opens a node from a link in an answer.
  final OpenNode? openNode;

  /// HTTP; tests replace it.
  final HttpPost post;

  static Future<void> open(
    BuildContext context, {
    required ValueListenable<RoamGraph> graph,
    required NoteTextReader readNote,
    RoamNode? startNode,
    NoteWriter? writer,
    OpenNode? openNode,
  }) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        graph: graph,
        readNote: readNote,
        startNode: startNode,
        writer: writer,
        openNode: openNode,
      ),
    ),
  );

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatSession? _session;
  ProviderConfig? _config;
  String _defaultModel = '';
  String _strongModel = '';
  bool _sending = false;
  String? _error;
  String? _setupProblem;

  /// Whether the node the chat starts from may be named to the AI: not
  /// when it is hidden from AI (#57).
  bool _startShown = false;

  /// The hidden tags the tools were made with.
  Set<String>? _hiddenTags;

  @override
  void initState() {
    super.initState();
    widget.graph.addListener(_refreshTools);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(ChatScreen old) {
    super.didUpdateWidget(old);
    if (old.graph != widget.graph) {
      old.graph.removeListener(_refreshTools);
      widget.graph.addListener(_refreshTools);
      _refreshTools();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // New hidden tags apply to the next tool call of an open chat.
    final tags = AiSettingsScope.of(context).hiddenTags.toSet();
    if (_hiddenTags != null && !setEquals(tags, _hiddenTags)) {
      _refreshTools();
    }
  }

  @override
  void dispose() {
    widget.graph.removeListener(_refreshTools);
    // A request under way finishes, but nothing more is read or sent.
    _session?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  RoamTools _tools(AiSettings settings) => RoamTools(
    widget.graph.value,
    readNote: widget.readNote,
    visibility: settings.visibility,
  );

  /// The tools on the graph and the hidden tags as they are now: after a
  /// scan brought new notes, or a tag was hidden.
  void _refreshTools() {
    final session = _session;
    if (session == null || !mounted) return;
    final settings = AiSettingsScope.of(context);
    _hiddenTags = settings.hiddenTags.toSet();
    session.tools = _tools(settings);
  }

  /// Makes a new chat with the settings as they are now.
  Future<void> _start() async {
    if (!mounted) return;
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return;
    final keys = AiSettingsScope.keysOf(context);
    final config = keys == null ? null : await providerConfig(settings, keys);
    if (!mounted) return;
    final values = settings.providerSettings();
    final start = widget.startNode;
    var startShown = start != null && !settings.visibility.hides(start);
    if (startShown) {
      final file = await widget.readNote(start.file);
      startShown =
          file == null || !settings.visibility.hidesInText(start, file);
    }
    if (!mounted) return;
    _session?.cancel();
    setState(() {
      _startShown = startShown;
      _hiddenTags = settings.hiddenTags.toSet();
      _error = null;
      _config = config;
      _defaultModel = values.defaultModel;
      _strongModel = values.strongModel;
      _setupProblem = config == null
          ? 'The AI settings are not available.'
          : config.model.isEmpty
          ? 'Choose a model for ${config.name} in AI settings.'
          : config.keyRequired && config.apiKey.isEmpty
          ? 'Enter the API key for ${config.name} in AI settings.'
          : null;
      _session = config == null
          ? null
          : ChatSession(
              tools: _tools(settings),
              config: config,
              post: widget.post,
              maxToolRounds: settings.maxToolRounds,
            );
    });
  }

  /// What the first message says about the node the chat came from.
  String? get _context {
    final node = widget.startNode;
    if (node == null || !_startShown) return null;
    return 'I am looking at the note "${node.displayTitle}" (ID ${node.id}). '
        'Read it with org_roam_read_node if you need it.';
  }

  Future<void> _send() async {
    final session = _session;
    final text = _input.text.trim();
    if (session == null || text.isEmpty || _sending) return;
    _input.clear();
    await _run(() => session.send(text, context: _context, onUpdate: _changed));
  }

  Future<void> _resume() async {
    final session = _session;
    if (session == null || _sending) return;
    await _run(() => session.resume(onUpdate: _changed));
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await work();
    } on AiError catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _sending = false);
      _toEnd();
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });

  void _openLink(OrgLink link) {
    final location = link.location;
    if (!location.startsWith('id:')) {
      _tell('The chat opens only id: links, not "$location".');
      return;
    }
    final id = location.substring(3).split('::').first.trim();
    if (!widget.graph.value.nodes.containsKey(id)) {
      _tell('There is no node with the ID $id.');
      return;
    }
    widget.openNode?.call(context, id);
  }

  /// An answer as a new node, through the capture screen (#11): the title
  /// and text are proposed as for shared text (#15), I review them.
  Future<void> _saveAsNode(NoteWriter writer, String answer) async {
    final proposal = proposeNode(SharedText(answer));
    final start = widget.startNode;
    final id = await CaptureScreen.open(
      context,
      writer,
      initialTitle: proposal.title,
      initialBody: proposal.body,
      linkTo: start == null ? null : (id: start.id, title: start.displayTitle),
    );
    if (id != null && mounted) widget.openNode?.call(context, id);
  }

  void _tell(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  void _newChat() {
    if (_sending) return;
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final config = _config;
    final model = session?.config.model ?? config?.model ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Ask AI'),
            if (config != null)
              Text(
                '${config.name} · $model',
                key: const ValueKey('chat-model'),
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          if (session != null &&
              _strongModel.isNotEmpty &&
              _strongModel != _defaultModel)
            PopupMenuButton<String>(
              tooltip: 'Model',
              icon: const Icon(Icons.tune),
              initialValue: model,
              onSelected: (m) => setState(() => session.model = m),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _defaultModel,
                  child: Text('Default: $_defaultModel'),
                ),
                PopupMenuItem(
                  value: _strongModel,
                  child: Text('Strong: $_strongModel'),
                ),
              ],
            ),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _sending ? null : _newChat,
          ),
          IconButton(
            tooltip: 'AI settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await AiSettingsScreen.open(context);
              // The new settings apply to a new chat.
              if (mounted && (session?.transcript.isEmpty ?? true)) _start();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _list(context)),
          if (_sending) const LinearProgressIndicator(),
          _composer(context),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    final session = _session;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final children = <Widget>[];
    if (_setupProblem case final problem?) {
      children.add(
        Card(
          key: const ValueKey('chat-setup'),
          child: ListTile(
            title: Text(problem),
            trailing: TextButton(
              onPressed: () async {
                await AiSettingsScreen.open(context);
                if (mounted) _start();
              },
              child: const Text('AI settings'),
            ),
          ),
        ),
      );
    } else if (session != null && session.transcript.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            widget.startNode != null && !_startShown
                ? 'This note is hidden from AI by its tags, so the chat does '
                      'not name it. Ask about your other notes.'
                : widget.startNode == null
                ? 'Ask about your notes. The AI reads them with the tools of '
                      'your org-roam MCP server; notes hidden from AI stay '
                      'hidden.'
                : 'Ask about "${widget.startNode!.displayTitle}" and its '
                      'neighbours. The AI reads the notes with the tools of '
                      'your org-roam MCP server; notes hidden from AI stay '
                      'hidden.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    for (final (i, entry) in (session?.transcript ?? const []).indexed) {
      switch (entry) {
        case UserMessage():
          children.add(
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                key: ValueKey('chat-user-$i'),
                margin: const EdgeInsets.fromLTRB(48, 8, 8, 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(entry.text),
              ),
            ),
          );
        case AssistantMessage():
          if (entry.text.trim().isNotEmpty) {
            final writer = widget.writer;
            children.add(
              Container(
                key: ValueKey('chat-answer-$i'),
                margin: const EdgeInsets.fromLTRB(8, 8, 24, 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OrgText(entry.text.trim(), onLinkTap: _openLink),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.model,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (writer != null && entry.toolCalls.isEmpty)
                          TextButton.icon(
                            key: ValueKey('chat-save-$i'),
                            onPressed: () => _saveAsNode(writer, entry.text),
                            icon: const Icon(Icons.note_add_outlined, size: 18),
                            label: const Text('Save as new node'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          } else if (entry.toolCalls.isEmpty) {
            // A final answer without text: say so rather than show nothing.
            children.add(
              Padding(
                key: ValueKey('chat-empty-$i'),
                padding: const EdgeInsets.fromLTRB(16, 8, 24, 4),
                child: Text(
                  'The model sent no text.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            );
          }
        case ToolResults():
          for (final (j, result) in entry.results.indexed) {
            children.add(
              _ToolCallTile(key: ValueKey('chat-tool-$i-$j'), result: result),
            );
          }
      }
    }
    if (_error case final error?) {
      children.add(
        Card(
          key: const ValueKey('chat-error'),
          color: colors.errorContainer,
          margin: const EdgeInsets.all(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(error, style: TextStyle(color: colors.onErrorContainer)),
                if (session?.waiting ?? false)
                  TextButton(
                    onPressed: _sending ? null : _resume,
                    child: const Text('Send again'),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (session != null && session.transcript.isNotEmpty) {
      final usage = session.usage;
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
            'Tokens in this chat: ${usage.input} in, of them ${usage.cached} '
            'from the cache, ${usage.output} out.',
            key: const ValueKey('chat-usage'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('chat-list'),
      controller: _scroll,
      children: children,
    );
  }

  Widget _composer(BuildContext context) {
    // A turn that failed is finished with "Send again" or a new chat
    // first, so a new question does not join it.
    final ready =
        _session != null &&
        _setupProblem == null &&
        !_sending &&
        !(_session?.waiting ?? false);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('chat-input'),
                controller: _input,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Ask about your notes',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              onPressed: ready ? _send : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A tool call, collapsed: which tool, with what; opened, its result.
class _ToolCallTile extends StatelessWidget {
  const _ToolCallTile({super.key, required this.result});

  final ToolResult result;

  @override
  Widget build(BuildContext context) {
    final call = result.call;
    final args = [
      for (final MapEntry(:key, :value) in call.input.entries) '$key: $value',
    ].join(', ');
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: const Icon(Icons.build_outlined, size: 18),
        title: Text(
          '${call.name.replaceFirst('org_roam_', '')}($args)',
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectableText(
              result.content,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
