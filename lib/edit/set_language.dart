/// "Set language…" on the search selection (#172): adds or replaces
/// `#+language:` in the file of each selected note, as one change that
/// can be undone.
library;

import 'package:material_ui/material_ui.dart';

import '../ai/note_language.dart';
import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import 'agent_changes.dart';
import 'note_editor.dart';
import 'save_messages.dart';

/// What "Set language…" did: its changes, for Undo, and the files that
/// could not be changed, with why.
class LanguageReport {
  LanguageReport(this.changes, this.code);
  final AgentChanges changes;
  final String code;
  final failures = <String>[];

  /// The files that already had the language.
  final unchanged = <String>[];
}

/// The files of [nodes], each once, in the order selected: a heading node
/// stands for its file.
List<String> languageFiles(List<RoamNode> nodes) =>
    {for (final node in nodes) node.file}.toList();

/// Sets `#+language: [code]` in the files of [nodes]; each saved file is
/// a change of one group in [log], so Undo restores all of them. Notes
/// hidden from AI are changed too: this is my own action.
Future<LanguageReport> setNotesLanguage({
  required NoteEditor editor,
  required AgentLog log,
  required RoamGraph graph,
  required List<RoamNode> nodes,
  required String code,
  DateTime Function() now = DateTime.now,
}) async {
  final time = now();
  final files = languageFiles(nodes);
  final changes = AgentChanges(
    messageId: 'language-${time.microsecondsSinceEpoch}',
    prompt: files.length == 1
        ? 'Set language $code: ${files.single}'
        : 'Set language $code in ${files.length} notes',
    time: time,
  );
  final report = LanguageReport(changes, code);
  for (final file in files) {
    final fileNode = graph.nodes.values
        .where((n) => n.file == file && n.isFile)
        .firstOrNull;
    final node = fileNode ?? nodes.firstWhere((n) => n.file == file);
    final title = fileNode?.displayTitle ?? file;
    final key = editor.store.historyKey(file);
    final base = await editor.read(file);
    if (base == null) {
      report.failures.add('$title: the file cannot be read as text.');
      continue;
    }
    final after = withLanguage(base.text, code);
    if (after == base.text) {
      report.unchanged.add(title);
      continue;
    }
    if (editor.store.historyKey(file) != key) {
      report.failures.add('$title: another folder was opened; nothing was '
          'written.');
      continue;
    }
    final result = await editor.save(file, base, after);
    if (result is! Saved && result is! SavedNotIndexed) {
      report.failures.add('$title: ${saveMessage(result, file)}');
      continue;
    }
    final change = AgentChange(
      tool: 'set_language',
      path: file,
      noteKey: key,
      nodeId: node.id,
      title: title,
      before: base.text,
      after: after,
    );
    changes.changes.add(change);
    await log.record(
        AgentLogEntry.of(changes, change, key.split('\n').first, now()));
  }
  return report;
}

/// Asks for the language code; null when cancelled. A line says which
/// files headings in the selection change.
Future<String?> askLanguage(BuildContext context, List<RoamNode> nodes) =>
    showDialog<String>(
      context: context,
      builder: (_) => _LanguageDialog(nodes: nodes),
    );

class _LanguageDialog extends StatefulWidget {
  const _LanguageDialog({required this.nodes});
  final List<RoamNode> nodes;

  @override
  State<_LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<_LanguageDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _set() {
    final code = languageCode(_code.text);
    if (code != null) Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final files = languageFiles(widget.nodes);
    final headingFiles = {
      for (final node in widget.nodes)
        if (!node.isFile) node.file,
    }.toList();
    final valid = languageCode(_code.text) != null;
    return AlertDialog(
      title: Text(files.length == 1
          ? 'Set the language of 1 note'
          : 'Set the language of ${files.length} notes'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('language-code'),
              controller: _code,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Language code',
                helperText: 'Written as #+language: in each file.',
                errorText: _code.text.trim().isEmpty || valid
                    ? null
                    : 'A code such as en or de.',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _set(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final MapEntry(key: code, value: name)
                    in commonLanguages.entries)
                  ActionChip(
                    key: ValueKey('language-$code'),
                    label: Text('$name ($code)'),
                    onPressed: () => setState(() => _code.text = code),
                  ),
              ],
            ),
            if (headingFiles.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                key: const ValueKey('language-heading-files'),
                'A heading has no language of its own, so the language is '
                'set for its file: ${headingFiles.join(', ')}.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid ? _set : null,
          child: const Text('Set'),
        ),
      ],
    );
  }
}

/// The message after "Set language…", with Undo for all its changes.
void showLanguageSet(
  ScaffoldMessengerState messenger,
  LanguageReport report,
  NoteWriter writer,
) {
  final count = report.changes.files.length;
  final lines = [
    count == 1
        ? 'Set #+language: ${report.code} in 1 note.'
        : 'Set #+language: ${report.code} in $count notes.',
    if (report.unchanged.isNotEmpty)
      'Already so: ${report.unchanged.join(', ')}.',
    ...report.failures,
  ];
  var undoing = false;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(lines.join('\n')),
      action: report.changes.isEmpty
          ? null
          : SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                if (undoing || !report.changes.canUndo) return;
                undoing = true;
                final result = await undoAndLog(
                    report.changes, writer.editor!, writer.changeLog);
                final stayed = [
                  for (final MapEntry(key: path, value: outcome)
                      in result.entries)
                    if (outcome == UndoOutcome.changedSince ||
                        outcome == UndoOutcome.otherFolder ||
                        outcome == UndoOutcome.failed)
                      report.changes.first(path).title,
                ];
                if (!messenger.mounted) return;
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                      content: Text(stayed.isEmpty
                          ? 'Undone.'
                          : 'Undone. Left unchanged: ${stayed.join(', ')}.')));
              },
            ),
    ));
}
