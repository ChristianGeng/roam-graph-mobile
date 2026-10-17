import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../edit/agent_changes.dart';
import '../edit/change_set.dart';
import '../edit/change_set_screen.dart';
import '../edit/diff_screen.dart';
import '../edit/edit_proposal.dart';
import '../edit/note_editor.dart';
import '../edit/recent_changes_screen.dart';
import '../edit/save_messages.dart';
import '../graph/roam_graph.dart';
import 'agent_tools.dart';
import 'ai_chat.dart';
import 'ai_settings.dart';
import 'ai_tools.dart';
import 'edit_tools.dart';

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
    this.agentLog = const FileAgentLog(),
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

  /// Where the agent's changes are logged (#82).
  final AgentLog agentLog;

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

  /// The edits the AI proposed (#39), by the ID of the tool call, and
  /// what became of those reviewed.
  final _proposals = <String, EditProposal>{};
  final _proposalStatus = <String, String>{};

  /// The change sets the AI proposed (#76), by the ID of the tool call;
  /// built when first reviewed, and kept, so their state stays.
  final _setProposals =
      <String, ({List<EditProposal> edits, String summary})>{};
  final _sets = <String, ChangeSet>{};

  /// The limit on notes per change set, from AI settings.
  int _maxFiles = 20;

  /// The agent's writes (#82), when AI settings let the AI change notes
  /// itself; null otherwise.
  AgentWriter? _agent;

  /// What the agent changed, by the index of the message in the
  /// transcript that asked for it.
  final _turnChanges = <int, AgentChanges>{};

  /// Undo is running for this message.
  int? _undoing;

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
      // A new chat: tool-call IDs can repeat across chats, so nothing of
      // the old one may be found under them.
      _proposals.clear();
      _turnChanges.clear();
      _proposalStatus.clear();
      _setProposals.clear();
      _sets.clear();
      _startShown = startShown;
      _hiddenTags = settings.hiddenTags.toSet();
      _error = null;
      _config = config;
      _defaultModel = values.defaultModel;
      _strongModel = values.strongModel;
      _maxFiles = settings.maxChangeSetFiles;
      _setupProblem = config == null
          ? 'The AI settings are not available.'
          : config.model.isEmpty
          ? 'Choose a model for ${config.name} in AI settings.'
          : config.keyRequired && config.apiKey.isEmpty
          ? 'Enter the API key for ${config.name} in AI settings.'
          : null;
      final editor = widget.writer?.editor;
      // What the AI may change, as AI settings say, and only where notes
      // can be saved.
      final mode = editor == null ? AiEditMode.off : settings.editMode;
      _agent = mode == AiEditMode.agent
          ? AgentWriter(
              writer: widget.writer!,
              visibleGraph: () =>
                  settings.visibility.visibleGraph(widget.graph.value),
              hiddenIds: () =>
                  settings.visibility.hiddenIds(widget.graph.value),
              visibility: settings.visibility,
              folder: () => editor!.store.historyKey('').split('\n').first,
              limit: settings.maxAgentChanges,
              log: widget.agentLog,
            )
          : null;
      _session = config == null
          ? null
          : ChatSession(
              tools: _tools(settings),
              config: config,
              post: widget.post,
              maxToolRounds: settings.maxToolRounds,
              toolList: switch (mode) {
                AiEditMode.off => null,
                AiEditMode.review => [
                    ...aiTools,
                    proposeEditTool,
                    proposeEditsTool(settings.maxChangeSetFiles),
                  ],
                AiEditMode.agent => [...aiTools, ...agentTools],
              },
              system: mode == AiEditMode.agent ? agentSystemPrompt : systemPrompt,
              handlers: {
                if (mode == AiEditMode.review) ...{
                  'propose_edit': _propose,
                  'propose_edits': _proposeSet,
                },
                ...?_agent?.handlers,
              },
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
    // The agent's changes for this message are kept under its index.
    if (_agent case final agent?) {
      _turnChanges[session.transcript.length] =
          agent.startMessage(prompt: text);
    }
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

  /// Throws [ToolError] if a note of [ids] got a hidden tag since the
  /// index was built, as the read tools check it: its title must not
  /// reach the AI.
  Future<void> _checkStillVisible(List<String> ids) async {
    final visibility = AiSettingsScope.of(context).visibility;
    for (final id in ids) {
      final node = widget.graph.value.nodes[id];
      if (node == null) continue;
      final text = await widget.readNote(node.file);
      if (text != null && visibility.hidesInText(node, text)) {
        throw ToolError('There is no note with the ID $id that you may see.');
      }
    }
  }

  /// Records an edit the AI proposes (#39); the tool writes nothing.
  Future<String> _propose(ToolCall call) async {
    final session = _session;
    if (session == null) return 'Error: the chat has ended.';
    try {
      final proposal = proposalFrom(call.input, session.tools.graph);
      await _checkStillVisible([proposal.nodeId]);
      _proposals[call.id] = proposal;
      final title = session.tools.graph.nodes[proposal.nodeId]!.displayTitle;
      return 'Recorded. I review the change to "$title" as a diff in the '
          'app before anything is saved; it is not saved yet.';
    } on ToolError catch (e) {
      return 'Error: ${e.message}';
    }
  }

  /// Records a change set the AI proposes (#76); the tool writes nothing.
  Future<String> _proposeSet(ToolCall call) async {
    final session = _session;
    if (session == null) return 'Error: the chat has ended.';
    try {
      final edits = proposalsFrom(call.input, session.tools.graph);
      await _checkStillVisible([for (final e in edits) e.nodeId]);
      final files = {
        for (final e in edits) session.tools.graph.nodes[e.nodeId]!.file,
      };
      if (files.length != edits.length) {
        return 'Error: two edits are for the same file; give one edit per '
            'file, with both changes in it.';
      }
      if (files.length > _maxFiles) {
        return 'Error: the set has ${files.length} notes; the limit is '
            '$_maxFiles. Propose fewer at a time.';
      }
      final summary = call.input['summary'];
      _setProposals[call.id] =
          (edits: edits, summary: summary is String ? summary.trim() : '');
      return 'Recorded a change set of ${edits.length} notes. I review each '
          'diff in the app before anything is saved; nothing is saved yet.';
    } on ToolError catch (e) {
      return 'Error: ${e.message}';
    }
  }

  /// Opens the review of a change set (#76), built from the notes as they
  /// are now on first opening.
  Future<void> _reviewSet(String callId) async {
    final writer = widget.writer;
    final editor = writer?.editor;
    final proposed = _setProposals[callId];
    if (writer == null || editor == null || proposed == null) return;
    var set = _sets[callId];
    if (set == null) {
      final settings = AiSettingsScope.of(context);
      final graph = widget.graph.value;
      try {
        set = await ChangeSet.build(
          proposed.edits,
          editor: editor,
          visible: settings.visibility.visibleGraph(graph),
          graph: graph,
          maxFiles: _maxFiles,
          summary: proposed.summary,
          visibility: settings.visibility,
        );
      } on ChangeSetError catch (e) {
        if (mounted) _tell(e.message);
        return;
      }
      _sets[callId] = set;
    }
    if (!mounted) return;
    await ChangeSetScreen.open(context, set, writer, widget.graph.value);
    if (mounted) setState(() {});
  }

  /// Shows the diff of a proposal against the note as it is now, and
  /// saves it only on "Save" (#38, #35).
  Future<void> _review(String callId) async {
    final proposal = _proposals[callId];
    final editor = widget.writer?.editor;
    if (proposal == null || editor == null) return;
    final graph = widget.graph.value;
    final node = graph.nodes[proposal.nodeId];
    if (node == null) {
      _tell('The note is no longer in the graph.');
      return;
    }
    final base = await editor.read(node.file);
    if (!mounted) return;
    if (base == null) {
      _tell('Could not read ${node.file}.');
      return;
    }
    if (AiSettingsScope.of(context).visibility.hidesInText(node, base.text)) {
      _tell('${node.file} is hidden from AI now; nothing was saved.');
      return;
    }
    final after = applyProposal(base.text, node, proposal);
    if (after == null) {
      _tell('The heading is no longer in ${node.file}.');
      return;
    }
    final unknown = unknownLinkIds(proposal.text, graph);
    final save = await DiffScreen.confirm(
      context,
      title: 'AI edit of ${node.displayTitle}',
      before: base.text,
      after: after,
      notes: [
        if (proposal.reason.isNotEmpty) 'The AI: ${proposal.reason}',
        if (unknown.isNotEmpty)
          'Links to IDs that are no note: ${unknown.join(', ')}.',
      ],
    );
    if (!save || !mounted) return;
    final result = await editor.save(node.file, base, after);
    if (!mounted) return;
    final message = saveMessage(result, node.file);
    setState(() {
      // Saved, also when indexing afterwards failed: not to save twice.
      if (result is Saved || result is SavedNotIndexed) {
        _proposalStatus[callId] = 'Saved.';
      }
    });
    _tell(message ?? 'Saved ${node.displayTitle}.');
    if (message != null && result is NoWriteAccessToEdit) {
      await widget.writer?.allowWriting();
    }
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
          if (widget.writer case final writer? when writer.editor != null)
            IconButton(
              tooltip: 'Recent AI changes',
              icon: const Icon(Icons.history),
              onPressed: () => RecentChangesScreen.open(context,
                  writer: writer, log: widget.agentLog),
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
    final transcript = session?.transcript ?? const <ChatEntry>[];
    var turn = 0;
    for (final (i, entry) in transcript.indexed) {
      if (entry is UserMessage) turn = i;
      // The agent's summary goes after the last entry of its message.
      final lastOfTurn =
          i == transcript.length - 1 || transcript[i + 1] is UserMessage;
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
                    // Selectable, as the Copy button copies it all (#94).
                    SelectionArea(
                      child: OrgText(entry.text.trim(), onLinkTap: _openLink),
                    ),
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
                        IconButton(
                          key: ValueKey('chat-copy-$i'),
                          tooltip: 'Copy',
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          onPressed: () => copyText(context, entry.text.trim()),
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
            final callId = result.call.id;
            if (_setProposals[callId] case final proposed?) {
              final set = _sets[callId];
              final saved = set?.entries
                      .where((e) => e.state == EntryState.saved)
                      .length ??
                  0;
              children.add(
                Card(
                  key: ValueKey('chat-change-set-$i-$j'),
                  margin: const EdgeInsets.fromLTRB(8, 4, 24, 4),
                  child: ListTile(
                    leading: const Icon(Icons.library_books_outlined),
                    title: Text(
                        'Changes to ${proposed.edits.length} notes'),
                    subtitle: Text(set == null
                        ? (proposed.summary.isEmpty
                            ? 'Not saved; review them first.'
                            : proposed.summary)
                        : '$saved saved'),
                    trailing: TextButton(
                      onPressed: () => _reviewSet(callId),
                      child: const Text('Review'),
                    ),
                  ),
                ),
              );
            }
            if (_proposals[callId] case final proposal?) {
              final title = widget.graph.value.nodes[proposal.nodeId]
                      ?.displayTitle ??
                  proposal.nodeId;
              final status = _proposalStatus[callId];
              children.add(
                Card(
                  key: ValueKey('chat-proposal-$i-$j'),
                  margin: const EdgeInsets.fromLTRB(8, 4, 24, 4),
                  child: ListTile(
                    leading: const Icon(Icons.edit_note_outlined),
                    title: Text(
                      proposal.mode == EditMode.append
                          ? 'Add to "$title"'
                          : 'Change the text of "$title"',
                    ),
                    subtitle: Text(status ??
                        (proposal.reason.isEmpty
                            ? 'Not saved; review it first.'
                            : proposal.reason)),
                    trailing: status != null
                        ? const Icon(Icons.check)
                        : TextButton(
                            onPressed: () => _review(callId),
                            child: const Text('Review'),
                          ),
                  ),
                ),
              );
            }
          }
      }
      // After the answer: what the agent changed for this message.
      final changes = _turnChanges[turn];
      if (lastOfTurn &&
          !(_sending && i == transcript.length - 1) &&
          changes != null &&
          !changes.isEmpty) {
        children.add(_agentSummary(turn, changes));
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
                SelectableText(error,
                    style: TextStyle(color: colors.onErrorContainer)),
                Row(
                  children: [
                    if (session?.waiting ?? false)
                      TextButton(
                        onPressed: _sending ? null : _resume,
                        child: const Text('Send again'),
                      ),
                    TextButton.icon(
                      key: const ValueKey('chat-error-copy'),
                      onPressed: () => copyText(context, error),
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: const Text('Copy'),
                    ),
                  ],
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

  /// The summary of what the agent changed for the message at [turn]:
  /// each note, to open or to see the change as a diff, and "Undo all".
  Widget _agentSummary(int turn, AgentChanges changes) {
    final undone = changes.undone;
    return Card(
      key: ValueKey('agent-summary-$turn'),
      margin: const EdgeInsets.fromLTRB(8, 4, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.auto_fix_high_outlined),
            title: Text(changes.summary, key: ValueKey('agent-counts-$turn')),
            subtitle: undone == null ? null : Text(undoMessage(undone)),
          ),
          for (final path in changes.files)
            ListTile(
              key: ValueKey('agent-file-$path'),
              dense: true,
              title: Text(changes.first(path).title),
              subtitle: Text(
                '${changes.deletedFiles.contains(path) ? 'Deleted' : changes.createdFiles.contains(path) ? 'Created' : 'Changed'}'
                '${switch (undone?[path]) {
                  UndoOutcome.restored => ', restored',
                  UndoOutcome.deleted => ', deleted again',
                  UndoOutcome.recreated => ', back again',
                  UndoOutcome.changedSince => ', changed since: kept',
                  UndoOutcome.otherFolder =>
                    ', in the folder opened before: kept',
                  UndoOutcome.failed => ', could not be undone',
                  null => ''
                }}',
              ),
              onTap: () {
                final id = changes.first(path).nodeId;
                if (widget.graph.value.nodes.containsKey(id)) {
                  widget.openNode?.call(context, id);
                } else {
                  _tell('That note is not in the graph now.');
                }
              },
              trailing: IconButton(
                tooltip: 'Show the change',
                icon: const Icon(Icons.difference_outlined),
                onPressed: () => DiffScreen.view(
                  context,
                  title: changes.first(path).title,
                  before: changes.before(path) ?? '',
                  after: changes.after(path) ?? '',
                ),
              ),
            ),
          if (changes.canUndo)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextButton.icon(
                key: ValueKey('agent-undo-$turn'),
                onPressed:
                    _sending || _undoing != null ? null : () => _undo(turn),
                icon: const Icon(Icons.undo),
                label: Text(undone == null
                    ? 'Undo all changes of this message'
                    : 'Try the rest again'),
              ),
            ),
        ],
      ),
    );
  }

  /// Undoes every change the agent made for the message at [turn].
  Future<void> _undo(int turn) async {
    final changes = _turnChanges[turn];
    final editor = widget.writer?.editor;
    if (changes == null || editor == null) return;
    setState(() => _undoing = turn);
    try {
      final outcome = await undoAndLog(changes, editor, widget.agentLog,
          create: widget.writer?.create);
      if (mounted) _tell(undoMessage(outcome));
    } finally {
      if (mounted) setState(() => _undoing = null);
    }
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
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('chat-tool-copy'),
              // The call and its result, for example to report an error.
              onPressed: () => copyText(
                  context, '${call.name}($args)\n\n${result.content}'),
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const Text('Copy'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Puts [text] on the clipboard and says so (#94).
Future<void> copyText(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Copied.')));
}
