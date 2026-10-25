/// "Edit with AI" (#103): one note changed by an instruction. The AI gets
/// only this note's text, as it may see it, and answers with its new text;
/// the result is saved only after the diff, as every edit (decision 10).
///
/// With "Also the linked notes" (#122), the note and the notes around it:
/// the AI first says what it will do, and only after "Go ahead" writes the
/// new texts, reviewed together as a change set (#76).
library;

import 'package:material_ui/material_ui.dart';

import '../ai/ai_chat.dart';
import '../ai/ai_settings.dart';
import '../ai/ai_tools.dart';
import '../ai/note_language.dart';
import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import '../platform/screen_awake.dart';
import 'agent_changes.dart';
import 'change_set.dart';
import 'change_set_screen.dart';
import 'diff_screen.dart';
import 'edit_proposal.dart';
import 'neighbourhood_edit.dart';
import 'node_text.dart';
import 'note_editor.dart';
import 'save_messages.dart';

/// What the AI is told: only the new text, nothing else.
const aiEditPrompt = 'You edit one note of an org-roam notes collection. '
    'You get the note\'s text in Org syntax, below its title and property '
    'drawer, and an instruction. Answer with the complete new text of the '
    'note and nothing else: no explanation, no code fence, no title line, '
    'no property drawer. Keep Org syntax, keep every [[id:...]] link unless '
    'the instruction says otherwise, and keep each line "* (hidden)" (with '
    'its stars) exactly as it is, in its place: it stands for a part you '
    'may not see. Keep links with the text "(hidden N)" as they are. '
    'Keep the language of the text: do not translate it unless the '
    'instruction asks for it, and add or change no #+language: line.';

/// The model's answer without a code fence around it.
String withoutFence(String answer) {
  final fenced =
      RegExp(r'^\s*```[a-zA-Z]*\r?\n([\s\S]*?)\r?\n```\s*$').firstMatch(answer);
  return fenced == null ? answer.trim() : fenced.group(1)!;
}

class AiEditScreen extends StatefulWidget {
  const AiEditScreen({
    super.key,
    required this.writer,
    required this.node,
    required this.graph,
    this.post = postWithDartIo,
    this.agentLog = const FileAgentLog(),
    this.now = DateTime.now,
  });

  final NoteWriter writer;
  final RoamNode node;
  final RoamGraph graph;
  final HttpPost post;

  /// Where a saved change set is logged, for "Recent AI changes" (#99).
  final AgentLog agentLog;
  final DateTime Function() now;

  /// The tool name of these changes in the log.
  static const logTool = 'edit_with_ai';

  /// Opens the screen; returns what to tell, such as "Saved".
  static Future<String?> open(BuildContext context, NoteWriter writer,
          RoamNode node, RoamGraph graph,
          {HttpPost post = postWithDartIo}) =>
      Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) =>
            AiEditScreen(writer: writer, node: node, graph: graph, post: post),
      ));

  @override
  State<AiEditScreen> createState() => _AiEditScreenState();
}

class _AiEditScreenState extends State<AiEditScreen> {
  final _instruction = TextEditingController();
  bool _working = false;
  String? _error;
  ChatSession? _session;

  /// Whether the notes around this one are in the scope (#122); null until
  /// the AI settings are known.
  bool? _withLinked;
  bool _hasNeighbours = false;

  /// The neighbourhood sent and the AI's plan, while it waits for "Go
  /// ahead" or "Back".
  Neighbourhood? _scope;
  EditPlan? _plan;

  /// The folder and path of the note when the scope was read.
  String? _noteKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_withLinked == null) _loadScope();
  }

  Future<void> _loadScope() async {
    _withLinked = false;
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return;
    final has = hasNeighbours(widget.node, widget.graph, settings.visibility);
    setState(() {
      _hasNeighbours = has;
      _withLinked = has;
    });
  }

  @override
  void dispose() {
    _session?.cancel();
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final instruction = _instruction.text.trim();
    final editor = widget.writer.editor;
    if (instruction.isEmpty || editor == null || _working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final error = await whileScreenOn(() => _hasNeighbours &&
              _withLinked == true
          ? _askPlan(instruction)
          : _run(instruction));
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// The provider to ask, or what is missing.
  Future<(AiSettings, ProviderConfig)?> _config(
      void Function(String error) fail) async {
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return null;
    final keys = AiSettingsScope.keysOf(context);
    final config = keys == null ? null : await providerConfig(settings, keys);
    if (config == null) {
      fail('The AI settings are not available.');
    } else if (config.model.isEmpty) {
      fail('Choose a model for ${config.name} in AI settings.');
    } else if (config.keyRequired && config.apiKey.isEmpty) {
      fail('Enter the API key for ${config.name} in AI settings.');
    } else {
      return (settings, config);
    }
    return null;
  }

  /// The first step with the linked notes: the AI says what it will do.
  Future<String?> _askPlan(String instruction) async {
    final editor = widget.writer.editor!;
    final node = widget.node;
    String? error;
    final found = await _config((e) => error = e);
    if (found == null || !mounted) return error;
    final (settings, config) = found;
    final noteKey = editor.store.historyKey(node.file);
    final Neighbourhood scope;
    try {
      scope = await neighbourhoodOf(node,
          editor: editor,
          graph: widget.graph,
          visibility: settings.visibility,
          maxFiles: settings.maxChangeSetFiles);
    } on NeighbourhoodError catch (e) {
      return e.message;
    }
    final session = _session = ChatSession(
      tools: RoamTools(widget.graph, readNote: (_) async => null),
      config: config,
      post: widget.post,
      toolList: const [],
      system: neighbourhoodPlanPrompt,
    );
    try {
      await session.send(neighbourhoodMessage(instruction, scope));
    } on AiError catch (e) {
      return e.message;
    }
    if (!mounted || _session != session) return null;
    final answer = session.transcript.whereType<AssistantMessage>().lastOrNull;
    try {
      final plan = parsePlan(answer?.text ?? '', scope);
      setState(() {
        _scope = scope;
        _plan = plan;
        _noteKey = noteKey;
      });
      return null;
    } on NeighbourhoodError catch (e) {
      return e.message;
    }
  }

  /// "Back" from the plan: the instruction stays, to change and ask again.
  void _back() {
    _session?.cancel();
    setState(() {
      _session = null;
      _scope = null;
      _plan = null;
      _error = null;
    });
  }

  Future<void> _goAhead() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final error = await whileScreenOn(_change);
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// The second step: the AI writes the new texts of the notes in the
  /// plan, which are reviewed together.
  Future<String?> _change() async {
    final editor = widget.writer.editor!;
    final session = _session;
    final scope = _scope;
    final plan = _plan;
    if (session == null || scope == null || plan == null) return null;
    try {
      await session.send(neighbourhoodChangePrompt);
    } on AiError catch (e) {
      return e.message;
    }
    if (!mounted || _session != session) return null;
    final answer = session.transcript.whereType<AssistantMessage>().lastOrNull;
    final Map<String, String> texts;
    try {
      texts = parseNewTexts(answer?.text ?? '', plan);
    } on NeighbourhoodError catch (e) {
      return e.message;
    }
    final entries = <ChangeEntry>[];
    for (final planned in plan.changes) {
      final note = planned.note;
      final text = texts[note.node.id];
      if (text == null) continue;
      final title = note.node.displayTitle;
      final rewritten = note.hidden.restore(text);
      if (rewritten == null) {
        return 'In $title, the AI dropped or moved a part hidden from it, so '
            'where that part belongs is not known. Nothing changed; ask '
            'again.';
      }
      if (!sameLockedKeywords(note.lines.body, rewritten)) {
        return 'In $title, the AI changed a #+title: or #+filetags: line, '
            'which stay as they are. Nothing changed; ask again.';
      }
      if (!sameLanguageLines(note.lines.body, rewritten)) {
        return 'In $title, the AI changed a #+language: line, which stays '
            'as it is; "Set language…" in search changes it. Nothing '
            'changed; ask again.';
      }
      final proposal = EditProposal(
        nodeId: note.node.id,
        mode: EditMode.replace,
        text: rewritten,
        reason: planned.change,
      );
      final after = applyProposal(note.base.text, note.node, proposal);
      if (after == null) return '$title is no longer in its file.';
      if (after == note.base.text) continue;
      entries.add(ChangeEntry(
        proposal: proposal,
        node: note.node,
        base: note.base,
        after: after,
        unknownIds: unknownLinkIds(rewritten, widget.graph),
      ));
    }
    if (entries.isEmpty) return 'The AI changed nothing.';
    // Another folder may have been chosen meanwhile.
    if (editor.store.historyKey(widget.node.file) != _noteKey) {
      return 'Another folder was opened; nothing was saved.';
    }
    final set = ChangeSet(entries, summary: plan.summary, allOrNothing: true);
    final changes = AgentChanges(
      messageId: '${widget.now().microsecondsSinceEpoch.toRadixString(36)}-'
          '${widget.node.id.hashCode.toRadixString(36)}',
      prompt: _shortPrompt(_instruction.text),
      time: widget.now(),
    );
    final folder = editor.store.historyKey('').split('\n').first;
    await ChangeSetScreen.open(
      context,
      set,
      widget.writer,
      widget.graph,
      onSaved: (set) async {
        for (final e in set.entries) {
          if (e.state != EntryState.saved) continue;
          final change = AgentChange(
            tool: AiEditScreen.logTool,
            path: e.file,
            noteKey: editor.store.historyKey(e.file),
            nodeId: e.node.id,
            title: e.node.displayTitle,
            before: e.base.text,
            after: e.after,
            linksAdded: e.linksAdded,
          );
          changes.changes.add(change);
          await widget.agentLog.record(
              AgentLogEntry.of(changes, change, folder, widget.now()));
        }
      },
      onUndone: (_) async {
        if (changes.isEmpty) return;
        await widget.agentLog
            .record(AgentLogEntry.undo(changes.messageId, widget.now()));
      },
    );
    if (!mounted) return null;
    int count(EntryState state) =>
        set.entries.where((e) => e.state == state).length;
    final saved = count(EntryState.saved);
    if (saved > 0) {
      Navigator.of(context)
          .pop(saved == 1 ? 'Saved 1 note.' : 'Saved $saved notes.');
      return null;
    }
    if (count(EntryState.undone) > 0) {
      Navigator.of(context).pop('The change set was undone.');
      return null;
    }
    // Nothing saved: back to the instruction.
    _back();
    return null;
  }

  static String _shortPrompt(String text) {
    final words = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return words.length <= 80 ? words : '${words.substring(0, 79)}…';
  }

  /// Asks the AI, shows the diff and saves; returns what went wrong.
  Future<String?> _run(String instruction) async {
    final editor = widget.writer.editor!;
    final node = widget.node;
    String? error;
    final found = await _config((e) => error = e);
    if (found == null || !mounted) return error;
    final (settings, config) = found;
    final visibility = settings.visibility;
    final noteKey = editor.store.historyKey(node.file);
    final base = await editor.read(node.file);
    if (base == null) return 'Could not read ${node.file}.';
    if (visibility.hides(node) || visibility.hidesInText(node, base.text)) {
      return 'This note is hidden from AI; nothing was sent.';
    }
    final lines = NodeLines.find(base.text, node);
    if (lines == null) {
      return '${node.displayTitle} is no longer in ${node.file} with '
          'its :ID:.';
    }
    final hidden = visibility.splitHidden(
        lines.body, visibility.hiddenIds(widget.graph),
        numberLinks: true);
    final session = _session = ChatSession(
      tools: RoamTools(widget.graph, readNote: (_) async => null),
      config: config,
      post: widget.post,
      toolList: const [],
      system: aiEditPrompt,
    );
    try {
      await session.send('Instruction: $instruction\n\n'
          'The note "${node.displayTitle}":\n\n${hidden.text}');
    } on AiError catch (e) {
      return e.message;
    }
    if (!mounted) return null;
    final answer = session.transcript.whereType<AssistantMessage>().lastOrNull;
    if (answer == null || answer.text.trim().isEmpty) {
      return 'The AI gave no text.';
    }
    final rewritten = hidden.restore(withoutFence(answer.text));
    if (rewritten == null) {
      return 'The AI dropped or moved a part hidden from it, so where '
          'that part belongs is not known. Nothing changed; ask again.';
    }
    if (!sameLockedKeywords(lines.body, rewritten)) {
      return 'The AI changed a #+title: or #+filetags: line, which '
          'stay as they are. Nothing changed; ask again.';
    }
    if (!sameLanguageLines(lines.body, rewritten)) {
      return 'The AI changed a #+language: line, which stays as it is; '
          '"Set language…" in search changes it. Nothing changed; ask '
          'again.';
    }
    final after = applyProposal(base.text, node,
        EditProposal(nodeId: node.id, mode: EditMode.replace, text: rewritten));
    if (after == null) return 'The note is no longer in its file.';
    if (after == base.text) return 'The AI changed nothing.';
    final unknown = unknownLinkIds(rewritten, widget.graph);
    final save = await DiffScreen.confirm(
      context,
      title: 'AI edit of ${node.displayTitle}',
      before: base.text,
      after: after,
      backLabel: 'Back to the instruction',
      notes: [
        'The AI: $instruction',
        if (unknown.isNotEmpty)
          'Links to IDs that are no note: ${unknown.join(', ')}.',
      ],
    );
    if (!save || !mounted) return null;
    // Another folder may have been chosen meanwhile.
    if (editor.store.historyKey(node.file) != noteKey) {
      return 'Another folder was opened; nothing was saved.';
    }
    final result = await editor.save(node.file, base, after);
    if (!mounted) return null;
    final message = saveMessage(result, node.file);
    if (message != null) {
      if (result is NoWriteAccessToEdit) await widget.writer.allowWriting();
      return message;
    }
    Navigator.of(context).pop('Saved ${node.displayTitle}.');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final linked = _hasNeighbours && _withLinked == true;
    return Scaffold(
      appBar: AppBar(title: Text('Edit with AI: ${widget.node.displayTitle}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('ai-edit-instruction'),
            controller: _instruction,
            autofocus: true,
            readOnly: plan != null,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: linked
                  ? 'What should the AI change in these notes?'
                  : 'What should the AI change in this note?',
              hintText: linked
                  ? 'For example: remove all links to this note, or rename '
                      'X to Y here and in the notes that link here.'
                  : 'For example: fix the typos, or add a short summary at '
                      'the top.',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          if (_hasNeighbours)
            CheckboxListTile(
              key: const ValueKey('ai-edit-linked'),
              contentPadding: EdgeInsets.zero,
              value: _withLinked ?? false,
              onChanged: plan != null || _working
                  ? null
                  : (on) => setState(() => _withLinked = on ?? false),
              title: const Text('Also the linked notes: the notes that link '
                  'here and the notes this one links to'),
            ),
          Text(linked
              ? 'This note and its linked notes are sent, as far as AI may '
                  'see them. The AI first says what it will change; you see '
                  'every change as a diff before anything is saved.'
              : 'Only this note is sent and changed. You see the change as '
                  'a diff before anything is saved.'),
          const SizedBox(height: 16),
          if (plan == null)
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const ValueKey('ai-edit-ask'),
                onPressed: _working ? null : _ask,
                icon: _working
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome_outlined),
                label: const Text('Ask the AI'),
              ),
            )
          else
            _planCard(plan),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                error,
                key: const ValueKey('ai-edit-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  /// The AI's plan, with "Go ahead" and "Back".
  Widget _planCard(EditPlan plan) {
    final leftOut = _scope?.leftOut ?? 0;
    final n = plan.changes.length;
    return Card(
      key: const ValueKey('ai-edit-plan'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('The AI\'s plan', style: Theme.of(context).textTheme.titleMedium),
            if (plan.summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(plan.summary),
            ],
            const SizedBox(height: 8),
            Text(n == 1 ? 'It will change 1 note:' : 'It will change $n notes:'),
            for (final c in plan.changes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.note.node.displayTitle),
                subtitle: Text([
                  '${c.note.node.file}, ${c.note.relation.label}',
                  if (c.change.isNotEmpty) c.change,
                ].join('\n')),
              ),
            if (leftOut > 0)
              Text(
                leftOut == 1
                    ? '1 linked note was left out: at most '
                        '${_scope!.notes.length} notes go in one change set '
                        '("Most notes one AI change set may edit" in AI settings).'
                    : '$leftOut linked notes were left out: at most '
                        '${_scope!.notes.length} notes go in one change set '
                        '("Most notes one AI change set may edit" in AI settings).',
                key: const ValueKey('ai-edit-left-out'),
              ),
            const SizedBox(height: 8),
            const Text('Nothing is changed yet. "Go ahead" asks the AI for the new '
                'texts, which you review before anything is saved.'),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const ValueKey('ai-edit-back'),
                  onPressed: _working ? null : _back,
                  child: const Text('Back'),
                ),
                FilledButton.icon(
                  key: const ValueKey('ai-edit-go'),
                  onPressed: _working ? null : _goAhead,
                  icon: _working
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('Go ahead'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
