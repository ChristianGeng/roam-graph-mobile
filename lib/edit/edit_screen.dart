import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import 'diff_screen.dart';
import 'node_text.dart';
import 'note_editor.dart';
import 'save_messages.dart';

/// "Edit text" (#37): the node's Org text, to change on the device. The
/// head stays as it is (decision 10, rule 5) and is shown above the text
/// but cannot be edited: for a heading node its heading line, planning and
/// property drawer; for a file node its drawer and keywords such as
/// `#+title:`. "Review" shows the diff (#38); only "Save" there writes,
/// and only over the version the editor opened (#35).
class EditScreen extends StatefulWidget {
  const EditScreen({
    super.key,
    required this.writer,
    required this.node,
    required this.base,
    required this.lines,
    required this.noteKey,
  });

  final NoteWriter writer;
  final RoamNode node;

  /// The note as read when the editor opened: the edit is saved only over
  /// this version.
  final NoteVersion base;
  final NodeLines lines;

  /// The note's folder and path, taken before it was read. After another
  /// folder is chosen (for write access), the same path there is another
  /// note, and nothing is saved into it.
  final String noteKey;

  /// Reads the note and opens the editor. Returns what to tell the user
  /// when an edit was saved, or null if nothing was saved. "Start again
  /// from the new version" opens the editor again within this call, so
  /// its save is reported too.
  static Future<String?> open(
      BuildContext context, NoteWriter writer, RoamNode node) async {
    final editor = writer.editor;
    if (editor == null) return null;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    while (true) {
      final noteKey = editor.store.historyKey(node.file);
      final base = await editor.read(node.file);
      if (base == null) {
        messenger.showSnackBar(SnackBar(
            content: Text('Could not read ${node.file} as text to edit.')));
        return null;
      }
      final lines = NodeLines.find(base.text, node);
      if (lines == null) {
        messenger.showSnackBar(SnackBar(
            content: Text('${node.displayTitle} is no longer in '
                '${node.file} with its :ID:; the file changed since the app '
                'read it.')));
        return null;
      }
      if (!navigator.mounted) return null;
      final result = await navigator.push<Object>(MaterialPageRoute(
        builder: (_) => EditScreen(
            writer: writer,
            node: node,
            base: base,
            lines: lines,
            noteKey: noteKey),
      ));
      if (result == _startAgain) continue;
      return result is String ? result : null;
    }
  }

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late final _text = TextEditingController(text: widget.lines.body);
  bool _saving = false;

  /// Set when the user chose to leave, so the page may close.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _tell(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Closes the page, also with unsaved changes, once [PopScope] knows.
  /// [result] is the message for a save, [_startAgain], or null.
  Future<void> _leave(Object? result) async {
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(result);
  }

  bool get _changed => _text.text != widget.lines.body;

  Future<void> _review() async {
    final editor = widget.writer.editor;
    if (editor == null) return;
    if (editor.store.historyKey(widget.node.file) != widget.noteKey) {
      _tell('Another folder is open now. Open the node there again to edit '
          'it; nothing was saved.');
      return;
    }
    // `#+title:` and `#+filetags:` count anywhere in the file, so their
    // lines in the text stay as they are too (rule 5).
    if (!_sameLockedKeywords(widget.lines.body, _text.text)) {
      _tell('Lines with #+title: or #+filetags: stay as they are: they set '
          "the note's title and tags. Nothing was saved.");
      return;
    }
    final after = widget.lines.withBody(_text.text);
    final save = await DiffScreen.confirm(
      context,
      title: 'Changes to ${widget.node.displayTitle}',
      before: widget.base.text,
      after: after,
    );
    if (!save || !mounted) return;
    // The folder may have changed while the diff was open.
    if (editor.store.historyKey(widget.node.file) != widget.noteKey) {
      _tell('Another folder is open now. Open the node there again to edit '
          'it; nothing was saved.');
      return;
    }
    setState(() => _saving = true);
    final SaveResult result;
    try {
      result = await editor.save(widget.node.file, widget.base, after);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    if (result is ChangedMeanwhile) {
      await _changedMeanwhile();
      return;
    }
    final message = saveMessage(result, widget.node.file);
    if (result is Saved || result is NothingToSave) {
      await _leave('Saved ${widget.node.displayTitle}.');
      return;
    }
    if (result is SavedNotIndexed) {
      // Shown by the node view, so it is not replaced there.
      await _leave(message);
      return;
    }
    if (message != null) _tell(message);
    if (result is NoWriteAccessToEdit) await widget.writer.allowWriting();
  }

  /// The laptop changed the note meanwhile: nothing was saved. The edit is
  /// copied, and the editor can start again from the new version.
  Future<void> _changedMeanwhile() async {
    // Not awaited: the dialog must not wait for the clipboard.
    unawaited(Clipboard.setData(ClipboardData(text: _text.text))
        .catchError((Object _) {}));
    if (!mounted) return;
    final again = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The note changed meanwhile'),
        content: Text('${widget.node.file} was changed on the laptop or '
            'through Syncthing since the editor opened, so nothing was '
            'saved. Your text is copied to the clipboard.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Start again from the new version'),
          ),
        ],
      ),
    );
    if (again != true || !mounted) return;
    // [EditScreen.open] opens the editor again on the new version.
    await _leave(_startAgain);
  }

  @override
  Widget build(BuildContext context) {
    final head = widget.lines.head;
    final mono = Theme.of(context)
        .textTheme
        .bodyMedium!
        .copyWith(fontFamily: 'monospace', fontSize: 14);
    return PopScope(
      // While saving, the page stays: a save cannot be called back.
      canPop: !_saving && (!_changed || _leaving),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _saving) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard the changes?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true) await _leave(null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Edit ${widget.node.displayTitle}'),
          actions: [
            IconButton(
              tooltip: 'Review',
              icon: const Icon(Icons.difference_outlined),
              onPressed: _saving || !_changed ? null : _review,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (head.isNotEmpty) ...[
              Text('Stays as it is: the ID, the property drawer and the '
                  '${widget.node.isFile ? 'title and file tags' : 'heading with its tags'}.'),
              const SizedBox(height: 4),
              Container(
                key: const ValueKey('edit-head'),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(head, style: mono),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('edit-text'),
              controller: _text,
              // Typing during a save would be lost: the save has its text.
              readOnly: _saving,
              minLines: 10,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: mono,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            if (_saving) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}

/// What a page pops with for "Start again from the new version".
const _startAgain = #startAgain;

/// The `#+title:` and `#+filetags:` lines, which set a file's title and
/// tags wherever they are.
final _lockedKeyword =
    RegExp(r'^[ \t]*#\+(title|filetags):', caseSensitive: false);

/// Whether [before] and [after] have the same `#+title:` and
/// `#+filetags:` lines, in the same order.
bool _sameLockedKeywords(String before, String after) {
  List<String> of(String text) => [
        for (final line in text.split(RegExp(r'\r?\n')))
          if (_lockedKeyword.hasMatch(line)) line.trim(),
      ];
  final a = of(before), b = of(after);
  return a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);
}
