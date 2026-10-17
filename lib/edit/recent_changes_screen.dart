/// "Recent AI changes" (#99): the agent's changes of the last 30 days,
/// from the log, grouped by message, each group to undo also after its
/// chat is closed.
library;

import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import 'agent_changes.dart';
import 'diff_screen.dart';

class RecentChangesScreen extends StatefulWidget {
  const RecentChangesScreen({
    super.key,
    required this.writer,
    required this.log,
  });

  final NoteWriter writer;
  final AgentLog log;

  static Future<void> open(BuildContext context,
          {required NoteWriter writer, required AgentLog log}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => RecentChangesScreen(writer: writer, log: log),
      ));

  @override
  State<RecentChangesScreen> createState() => _RecentChangesScreenState();
}

class _RecentChangesScreenState extends State<RecentChangesScreen> {
  List<LoggedMessage>? _messages;
  LoggedMessage? _undoing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await widget.log.read();
    if (mounted) setState(() => _messages = recentMessages(entries));
  }

  static String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _undo(LoggedMessage message) async {
    final editor = widget.writer.editor;
    if (editor == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo these changes?'),
        content: Text('${message.changes.summary}. Notes changed since stay '
            'as they are.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-undo'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _undoing = message);
    try {
      final outcome = await undoAndLog(message.changes, editor, widget.log,
          create: widget.writer.create);
      if (!message.changes.canUndo) message.undone = true;
      if (!mounted) return;
      final stayed = [
        for (final MapEntry(key: path, value: o) in outcome.entries)
          if (o == UndoOutcome.changedSince ||
              o == UndoOutcome.otherFolder ||
              o == UndoOutcome.failed)
            message.changes.first(path).title.isEmpty
                ? path
                : message.changes.first(path).title,
      ];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(stayed.isEmpty
            ? undoMessage(outcome)
            : '${undoMessage(outcome)} Stayed: ${stayed.join(', ')}.'),
      ));
    } finally {
      if (mounted) setState(() => _undoing = null);
    }
  }

  String _what(AgentChanges changes, String path) {
    if (changes.createdFiles.contains(path)) return 'Created';
    if (changes.deletedFiles.contains(path)) return 'Deleted';
    if (changes.after(path) == null) return 'Created and deleted';
    return 'Changed';
  }

  Widget _message(BuildContext context, int i, LoggedMessage message) {
    final changes = message.changes;
    final canUndo = message.undoable &&
        !message.undone &&
        changes.canUndo &&
        widget.writer.editor != null;
    return Card(
      key: ValueKey('recent-$i'),
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: ExpansionTile(
        title: Text(changes.prompt.isEmpty ? 'AI changes' : changes.prompt,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${_when(message.time)} · ${changes.summary}'
            '${message.undone ? ' · undone' : ''}'),
        children: [
          for (final path in changes.files)
            ListTile(
              dense: true,
              title: Text(changes.first(path).title.isEmpty
                  ? path
                  : changes.first(path).title),
              subtitle: Text('${_what(changes, path)} · $path'),
              trailing: const Icon(Icons.difference_outlined),
              onTap: () => DiffScreen.view(
                context,
                title: changes.first(path).title,
                before: changes.before(path) ?? '',
                after: changes.after(path) ?? '',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerRight,
              child: message.undoable
                  ? FilledButton.tonalIcon(
                      key: ValueKey('recent-undo-$i'),
                      onPressed: canUndo && _undoing == null
                          ? () => _undo(message)
                          : null,
                      icon: const Icon(Icons.undo),
                      label: Text(message.undone
                          ? 'Undone'
                          : 'Undo these changes'),
                    )
                  : const Text('Logged before undo was possible here.'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(title: const Text('Recent AI changes')),
      body: messages == null
          ? const Center(child: CircularProgressIndicator())
          : messages.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('The AI changed no notes in the last '
                        '$recentDays days.'),
                  ),
                )
              : ListView(
                  key: const ValueKey('recent-list'),
                  children: [
                    for (final (i, m) in messages.indexed)
                      _message(context, i, m),
                  ],
                ),
    );
  }
}
