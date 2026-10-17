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
  });

  final NoteWriter writer;
  final RoamNode node;

  /// The note as read when the editor opened: the edit is saved only over
  /// this version.
  final NoteVersion base;
  final NodeLines lines;

  /// Reads the note and opens the editor; true if an edit was saved.
  static Future<bool> open(
      BuildContext context, NoteWriter writer, RoamNode node) async {
    final editor = writer.editor;
    if (editor == null) return false;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final base = await editor.read(node.file);
    if (base == null) {
      messenger.showSnackBar(SnackBar(
          content: Text('Could not read ${node.file} as text to edit.')));
      return false;
    }
    final lines = NodeLines.find(base.text, node);
    if (lines == null) {
      messenger.showSnackBar(SnackBar(
          content: Text('The heading is no longer in ${node.file}; the '
              'file changed since the app read it.')));
      return false;
    }
    return await navigator.push<bool>(MaterialPageRoute(
          builder: (_) => EditScreen(
              writer: writer, node: node, base: base, lines: lines),
        )) ??
        false;
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
  Future<void> _leave(bool saved) async {
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(saved);
  }

  bool get _changed => _text.text != widget.lines.body;

  Future<void> _review() async {
    final editor = widget.writer.editor;
    if (editor == null) return;
    final after = widget.lines.withBody(_text.text);
    final save = await DiffScreen.confirm(
      context,
      title: 'Changes to ${widget.node.displayTitle}',
      before: widget.base.text,
      after: after,
    );
    if (!save || !mounted) return;
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
    if (message == null) {
      await _leave(true);
      return;
    }
    _tell(message);
    if (result is NoWriteAccessToEdit) await widget.writer.allowWriting();
    if (result is SavedNotIndexed) await _leave(true);
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
    final navigator = Navigator.of(context);
    await _leave(false);
    if (navigator.mounted) {
      await EditScreen.open(navigator.context, widget.writer, widget.node);
    }
  }

  @override
  Widget build(BuildContext context) {
    final head = widget.lines.head;
    final mono = Theme.of(context)
        .textTheme
        .bodyMedium!
        .copyWith(fontFamily: 'monospace', fontSize: 14);
    return PopScope(
      canPop: !_changed || _leaving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
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
        if (discard == true) await _leave(false);
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
