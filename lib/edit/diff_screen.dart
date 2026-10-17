import 'package:material_ui/material_ui.dart';

import 'line_diff.dart';

/// Shows what an edit changes before it is saved (#38): the lines removed
/// and added, with three lines of context, as `diff -u` shows them.
/// Nothing is written here: "Save" returns true to the screen that opened
/// it, which saves; "Back to editing" returns false.
class DiffScreen extends StatefulWidget {
  const DiffScreen({
    super.key,
    required this.title,
    required this.before,
    required this.after,
    this.saveLabel = 'Save',
    this.backLabel = 'Back to editing',
    this.notes = const [],
    this.viewOnly = false,
  });

  /// Only shows the change, with "Close": for a change saved already,
  /// such as one the AI agent made (#82).
  final bool viewOnly;

  /// Shows a change that is saved already.
  static Future<void> view(
    BuildContext context, {
    required String title,
    required String before,
    required String after,
  }) =>
      Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => DiffScreen(
          title: title,
          before: before,
          after: after,
          backLabel: 'Close',
          viewOnly: true,
        ),
      ));

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
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> {
  // Computed once, not on every rebuild.
  late final List<DiffLine>? _lines = diffLines(widget.before, widget.after);
  late final List<DiffHunk> _hunks = switch (_lines) {
    final lines? => hunksOf(lines),
    null => const [],
  };

  String _summary() {
    final lines = _lines;
    if (widget.before == widget.after) return 'No change.';
    if (lines == null) {
      String count(String text) {
        final n = '\n'.allMatches(text).length;
        return '$n ${n == 1 ? 'line' : 'lines'}';
      }

      return 'Too many changes to show line by line: '
          '${count(widget.before)} before, ${count(widget.after)} after.';
    }
    if (_hunks.isEmpty) {
      return 'Only the line endings or the newline at the end change.';
    }
    final removed = lines.where((l) => l.kind == DiffKind.removed).length;
    final added = lines.where((l) => l.kind == DiffKind.added).length;
    return '$removed ${removed == 1 ? 'line' : 'lines'} removed, '
        '$added ${added == 1 ? 'line' : 'lines'} added.';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final notes = widget.notes;
    final hunks = _hunks;
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
            child: Text(_summary(), key: const ValueKey('diff-summary')),
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
                    child: Text(widget.backLabel),
                  ),
                  if (!widget.viewOnly) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    // Any difference can be saved, also one the lines do
                    // not show, such as line endings.
                    onPressed: widget.before == widget.after
                        ? null
                        : () => Navigator.of(context).pop(true),
                    child: Text(widget.saveLabel),
                  ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
