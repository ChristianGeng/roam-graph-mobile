import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import '../platform/error_text.dart';
import 'change_set.dart';
import 'diff_screen.dart';
import 'edit_proposal.dart';
import 'line_diff.dart';

/// Reviews an AI change set (#76): one entry per file, with its diff and
/// the AI's reason, to accept, reject or edit; then saves the accepted
/// ones, one file at a time, and reports what became of each. A saved set
/// can be undone.
class ChangeSetScreen extends StatefulWidget {
  const ChangeSetScreen({
    super.key,
    required this.set,
    required this.writer,
    required this.graph,
    this.onSaved,
    this.onUndone,
  });

  final ChangeSet set;
  final NoteWriter writer;
  final RoamGraph graph;

  /// Runs once the set is saved, for example to log it (#122).
  final Future<void> Function(ChangeSet set)? onSaved;

  /// Runs once the whole set is undone.
  final Future<void> Function(ChangeSet set)? onUndone;

  static Future<void> open(BuildContext context, ChangeSet set,
          NoteWriter writer, RoamGraph graph,
          {Future<void> Function(ChangeSet set)? onSaved,
          Future<void> Function(ChangeSet set)? onUndone}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChangeSetScreen(
            set: set,
            writer: writer,
            graph: graph,
            onSaved: onSaved,
            onUndone: onUndone),
      ));

  @override
  State<ChangeSetScreen> createState() => _ChangeSetScreenState();
}

class _ChangeSetScreenState extends State<ChangeSetScreen> {
  bool _busy = false;

  ChangeSet get _set => widget.set;

  bool get _saved => _set.entries.any((e) => e.state == EntryState.saved);

  bool get _decided => _set.entries.any((e) =>
      e.state == EntryState.saved ||
      e.state == EntryState.refused ||
      e.state == EntryState.undone);

  /// An [error] has a "Copy" action (#180).
  void _tell(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.of(context);
    if (error) {
      showErrorSnackBar(messenger, message);
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _mark(ChangeEntry entry, EntryState state) =>
      setState(() => entry.state = state);

  Future<void> _showDiff(ChangeEntry entry) async {
    // Once the set is saved, a diff is only to look at: accepting again
    // would take a saved entry out of Undo.
    if (_decided) {
      await DiffScreen.view(context,
          title: entry.node.displayTitle,
          before: entry.base.text,
          after: entry.after);
      return;
    }
    final accept = await DiffScreen.confirm(
      context,
      title: entry.node.displayTitle,
      before: entry.base.text,
      after: entry.after,
      saveLabel: 'Accept',
      backLabel: 'Back',
      notes: _notes(entry),
    );
    if (accept && mounted) _mark(entry, EntryState.accepted);
  }

  List<String> _notes(ChangeEntry entry) => [
        if (entry.proposal.reason.isNotEmpty)
          'The AI: ${entry.proposal.reason}',
        if (entry.unknownIds.isNotEmpty)
          'Links to IDs that are no note: ${entry.unknownIds.join(', ')}.',
      ];

  Future<void> _edit(ChangeEntry entry) async {
    final controller = TextEditingController(text: entry.proposal.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.proposal.mode == EditMode.append
            ? 'Text to add to ${entry.node.displayTitle}'
            : 'New text of ${entry.node.displayTitle}'),
        content: TextField(
          key: const ValueKey('change-edit-text'),
          controller: controller,
          maxLines: null,
          minLines: 4,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Use'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    setState(() {
      _set.editEntry(entry, text, widget.graph);
      entry.state = EntryState.pending;
    });
  }

  Future<void> _save() async {
    final editor = widget.writer.editor;
    if (editor == null) return;
    setState(() => _busy = true);
    try {
      await _set.save(editor, onEach: () {
        if (mounted) setState(() {});
      });
      if (_saved) await widget.onSaved?.call(_set);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final saved =
        _set.entries.where((e) => e.state == EntryState.saved).length;
    final refused =
        _set.entries.where((e) => e.state == EntryState.refused).length;
    final rejected =
        _set.entries.where((e) => e.state == EntryState.rejected).length;
    _tell('$saved saved, $refused refused, $rejected rejected.',
        error: refused > 0);
  }

  Future<void> _undo() async {
    final editor = widget.writer.editor;
    if (editor == null) return;
    setState(() => _busy = true);
    final Map<String, String> problems;
    try {
      problems = await _set.undo(editor);
      if (problems.isEmpty) await widget.onUndone?.call(_set);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    _tell(problems.isEmpty
        ? 'The change set is undone.'
        : 'Undone, except: ${[
            for (final MapEntry(:key, :value) in problems.entries)
              '$key ($value)'
          ].join(', ')}.',
        error: problems.isNotEmpty);
  }

  String _stateText(ChangeEntry entry) => switch (entry.state) {
        EntryState.pending => 'Not decided',
        EntryState.accepted => 'Accepted',
        EntryState.rejected => 'Rejected',
        EntryState.saved => 'Saved',
        EntryState.refused => 'Not saved: ${entry.problem}',
        EntryState.undone => 'Undone',
      };

  @override
  Widget build(BuildContext context) {
    final entries = _set.entries;
    final accepted = _set.accepted.toList();
    final links = accepted.fold(0, (sum, e) => sum + e.linksAdded);
    return Scaffold(
      appBar: AppBar(title: const Text('AI change set')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          if (_set.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text('The AI: ${_set.summary}'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '${entries.length} notes proposed. ${accepted.length} '
              'accepted, which change ${accepted.length} '
              '${accepted.length == 1 ? 'file' : 'files'} and add $links '
              '${links == 1 ? 'link' : 'links'}.',
              key: const ValueKey('change-count'),
            ),
          ),
          if (!_decided)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() {
                    for (final e in entries) {
                      e.state = EntryState.accepted;
                    }
                  }),
                  child: const Text('Accept all'),
                ),
              ),
            ),
          for (final (i, entry) in entries.indexed)
            Card(
              key: ValueKey('change-$i'),
              margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry.node.displayTitle),
                      subtitle: Text([
                        entry.file,
                        if (entry.proposal.reason.isNotEmpty)
                          entry.proposal.reason,
                        _changeCounts(entry),
                        _stateText(entry),
                      ].join('\n')),
                      onTap: () => _showDiff(entry),
                    ),
                    for (final note in _notes(entry).skip(
                        entry.proposal.reason.isEmpty ? 0 : 1))
                      ErrorText.message(note),
                    if (!_decided)
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => _showDiff(entry),
                            child: const Text('Diff'),
                          ),
                          TextButton(
                            onPressed: () => _mark(entry, EntryState.accepted),
                            child: const Text('Accept'),
                          ),
                          TextButton(
                            onPressed: () => _mark(entry, EntryState.rejected),
                            child: const Text('Reject'),
                          ),
                          TextButton(
                            onPressed: () => _edit(entry),
                            child: const Text('Edit'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: _busy
          ? const FloatingActionButton(
              onPressed: null, child: CircularProgressIndicator())
          : !_decided
              ? FloatingActionButton.extended(
                  key: const ValueKey('change-save'),
                  // Every note is decided before the first save: the set is
                  // saved once, so none is left without controls.
                  onPressed: accepted.isEmpty ||
                          entries.any((e) => e.state == EntryState.pending)
                      ? null
                      : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text('Save ${accepted.length}'),
                )
              : _saved
                  ? FloatingActionButton.extended(
                      key: const ValueKey('change-undo'),
                      onPressed: _undo,
                      icon: const Icon(Icons.undo),
                      label: const Text('Undo this change set'),
                    )
                  : null,
    );
  }

  static String _changeCounts(ChangeEntry entry) {
    final lines = diffLines(entry.base.text, entry.after);
    // Too many changes for a line-by-line diff (decision 55).
    if (lines == null) return 'many lines changed';
    final removed = lines.where((l) => l.kind == DiffKind.removed).length;
    final added = lines.where((l) => l.kind == DiffKind.added).length;
    return '−$removed +$added lines';
  }
}
