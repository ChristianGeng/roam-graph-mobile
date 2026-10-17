import 'package:material_ui/material_ui.dart';

import 'line_diff.dart';

/// Shows what an edit changes before it is saved (#38): the lines removed
/// and added, with three lines of context, as `diff -u` shows them.
/// Nothing is written here: "Save" returns true to the screen that opened
/// it, which saves; "Back to editing" returns false.
class DiffScreen extends StatelessWidget {
  const DiffScreen({
    super.key,
    required this.title,
    required this.before,
    required this.after,
    this.saveLabel = 'Save',
    this.backLabel = 'Back to editing',
    this.notes = const [],
  });

  final String title;
  final String before;
  final String after;
  final String saveLabel;
  final String backLabel;

  /// Lines shown above the diff, such as why an AI proposes the edit, or
  /// links that point nowhere.
  final List<String> notes;

  /// Opens the screen; true if the user chose to save.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String before,
    required String after,
    String saveLabel = 'Save',
    String backLabel = 'Back to editing',
    List<String> notes = const [],
  }) async =>
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => DiffScreen(
          title: title,
          before: before,
          after: after,
          saveLabel: saveLabel,
          backLabel: backLabel,
          notes: notes,
        ),
      )) ??
      false;

  @override
  Widget build(BuildContext context) {
    final hunks = diffHunks(before, after);
    final lines = diffLines(before, after);
    final removed = lines.where((l) => l.kind == DiffKind.removed).length;
    final added = lines.where((l) => l.kind == DiffKind.added).length;
    final scheme = Theme.of(context).colorScheme;
    final mono = Theme.of(context)
        .textTheme
        .bodyMedium!
        .copyWith(fontFamily: 'monospace', fontSize: 13);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              hunks.isEmpty
                  ? 'No change.'
                  : '$removed ${removed == 1 ? 'line' : 'lines'} removed, '
                      '$added ${added == 1 ? 'line' : 'lines'} added.',
              key: const ValueKey('diff-summary'),
            ),
          ),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(note, key: const ValueKey('diff-note')),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final (i, hunk) in hunks.indexed) ...[
                  if (i > 0) const Divider(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Line ${hunk.newStart == 0 ? hunk.oldStart : hunk.newStart}',
                      style: mono.copyWith(color: scheme.outline),
                    ),
                  ),
                  for (final line in hunk.lines)
                    Container(
                      color: switch (line.kind) {
                        DiffKind.same => null,
                        DiffKind.removed => scheme.errorContainer,
                        DiffKind.added => scheme.tertiaryContainer,
                      },
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '$line',
                        key: ValueKey('diff-${line.kind.name}'),
                        style: mono.copyWith(
                          color: switch (line.kind) {
                            DiffKind.same => null,
                            DiffKind.removed => scheme.onErrorContainer,
                            DiffKind.added => scheme.onTertiaryContainer,
                          },
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(backLabel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: hunks.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(true),
                    child: Text(saveLabel),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
