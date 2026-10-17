/// "Edit with AI" (#103): one note changed by an instruction. The AI gets
/// only this note's text, as it may see it, and answers with its new text;
/// the result is saved only after the diff, as every edit (decision 10).
library;

import 'package:material_ui/material_ui.dart';

import '../ai/ai_chat.dart';
import '../ai/ai_settings.dart';
import '../ai/ai_tools.dart';
import '../ai/ai_visibility.dart';
import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import 'diff_screen.dart';
import 'edit_proposal.dart';
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
    'may not see.';

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
  });

  final NoteWriter writer;
  final RoamNode node;
  final RoamGraph graph;
  final HttpPost post;

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
      final error = await _run(instruction);
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Asks the AI, shows the diff and saves; returns what went wrong.
  Future<String?> _run(String instruction) async {
    final editor = widget.writer.editor!;
    final node = widget.node;
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return null;
    final keys = AiSettingsScope.keysOf(context);
    final config = keys == null ? null : await providerConfig(settings, keys);
    if (config == null) return 'The AI settings are not available.';
    if (config.model.isEmpty) {
      return 'Choose a model for ${config.name} in AI settings.';
    }
    if (config.keyRequired && config.apiKey.isEmpty) {
      return 'Enter the API key for ${config.name} in AI settings.';
    }
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
        lines.body, visibility.hiddenIds(widget.graph));
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
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Edit with AI: ${widget.node.displayTitle}')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const ValueKey('ai-edit-instruction'),
              controller: _instruction,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'What should the AI change in this note?',
                hintText: 'For example: fix the typos, or add a short '
                    'summary at the top.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Only this note is sent and changed. You see the '
                'change as a diff before anything is saved.'),
            const SizedBox(height: 16),
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
            ),
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
