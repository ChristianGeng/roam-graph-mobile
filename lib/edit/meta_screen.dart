import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import '../capture/new_node.dart';
import '../graph/roam_graph.dart';
import 'diff_screen.dart';
import 'node_meta.dart';
import 'note_editor.dart';
import 'save_messages.dart';
import 'unsaved_text.dart';

/// "Title, tags and aliases" (#97): the node's head, the only part of it
/// that changes here; the `:ID:` and every other property stay. "Review"
/// shows the diff (#38); only "Save" there writes, over the version read.
class MetaScreen extends StatefulWidget {
  const MetaScreen({
    super.key,
    required this.writer,
    required this.node,
    required this.base,
    required this.meta,
    required this.noteKey,
  });

  final NoteWriter writer;
  final RoamNode node;
  final NoteVersion base;
  final NodeMeta meta;

  /// The note's folder and path, taken before it was read: after another
  /// folder is chosen, nothing is saved.
  final String noteKey;

  /// Reads the note and opens the form. Returns what to tell the user when
  /// something was saved, or null.
  static Future<String?> open(
      BuildContext context, NoteWriter writer, RoamNode node) async {
    final editor = writer.editor;
    if (editor == null) return null;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final noteKey = editor.store.historyKey(node.file);
    final base = await editor.read(node.file);
    final meta = base == null ? null : readMeta(base.text, node);
    if (base == null || meta == null) {
      messenger.showSnackBar(SnackBar(
          content: Text('${node.displayTitle} could not be read from '
              '${node.file}.')));
      return null;
    }
    if (!navigator.mounted) return null;
    return navigator.push<String>(MaterialPageRoute(
      builder: (_) => MetaScreen(
          writer: writer,
          node: node,
          base: base,
          meta: meta,
          noteKey: noteKey),
    ));
  }

  @override
  State<MetaScreen> createState() => _MetaScreenState();
}

class _MetaScreenState extends State<MetaScreen> {
  late final _title = TextEditingController(text: widget.meta.title);
  late final _tags = TextEditingController(text: widget.meta.tags.join(' '));
  late final _aliases =
      TextEditingController(text: widget.meta.aliases.join('\n'));
  bool _saving = false;

  bool get _changed =>
      _title.text != widget.meta.title ||
      _tags.text != widget.meta.tags.join(' ') ||
      _aliases.text != widget.meta.aliases.join('\n');

  @override
  void initState() {
    super.initState();
    for (final field in [_title, _tags, _aliases]) {
      field.addListener(() => UnsavedText.mark(this, _changed));
    }
  }

  @override
  void dispose() {
    UnsavedText.mark(this, false);
    _title.dispose();
    _tags.dispose();
    _aliases.dispose();
    super.dispose();
  }

  void _tell(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _review() async {
    final editor = widget.writer.editor;
    if (editor == null) return;
    final String after;
    try {
      after = withMeta(
        widget.base.text,
        widget.node,
        NodeMeta(
          title: _title.text,
          tags: parseTags(_tags.text),
          aliases: [
            for (final line in _aliases.text.split('\n'))
              if (line.trim().isNotEmpty) line.trim(),
          ],
        ),
      );
    } on MetaError catch (e) {
      _tell(e.message);
      return;
    }
    final save = await DiffScreen.confirm(
      context,
      title: 'Head of ${widget.node.displayTitle}',
      before: widget.base.text,
      after: after,
    );
    if (!save || !mounted) return;
    // The folder may have changed meanwhile.
    if (editor.store.historyKey(widget.node.file) != widget.noteKey) {
      _tell('Another folder is open now; nothing was saved.');
      return;
    }
    setState(() => _saving = true);
    final SaveResult result;
    try {
      result = await editor.save(widget.node.file, widget.base, after,
          aliasesMayChange: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    final message = saveMessage(result, widget.node.file);
    if (result is Saved || result is NothingToSave || result is SavedNotIndexed) {
      Navigator.of(context).pop(message ?? 'Saved ${_title.text.trim()}.');
      return;
    }
    if (message != null) _tell(message);
    if (result is NoWriteAccessToEdit) await widget.writer.allowWriting();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Title, tags and aliases'),
        actions: [
          IconButton(
            tooltip: 'Review',
            icon: const Icon(Icons.difference_outlined),
            onPressed: _saving ? null : _review,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.node.isFile
              ? 'The note\'s #+title, #+filetags and aliases. The :ID: and '
                  'the file name stay.'
              : 'The heading\'s text and own tags, and its aliases. Its TODO '
                  'keyword, priority and :ID: stay.'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('meta-title'),
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            key: const ValueKey('meta-tags'),
            controller: _tags,
            decoration: const InputDecoration(
                labelText: 'Tags', hintText: 'Separated by spaces'),
          ),
          TextField(
            key: const ValueKey('meta-aliases'),
            controller: _aliases,
            minLines: 2,
            maxLines: null,
            decoration: const InputDecoration(
                labelText: 'Aliases', hintText: 'One per line'),
          ),
          if (_saving) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
