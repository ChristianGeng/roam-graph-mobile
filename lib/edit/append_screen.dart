import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import 'append.dart';
import 'note_editor.dart';

/// "Add to this node" (#36): text typed here goes to the end of the node,
/// and nothing that is there changes. The note is read again when saving,
/// so what the laptop wrote meanwhile stays: the text is added to the
/// newest version. It is saved as every edit is (#35).
class AppendScreen extends StatefulWidget {
  const AppendScreen({
    super.key,
    required this.writer,
    required this.node,
    this.initialText = '',
  });

  final NoteWriter writer;
  final RoamNode node;

  /// The text to start with, such as text shared from an AI app (#39).
  final String initialText;

  /// Opens the screen; true if text was added.
  static Future<bool> open(
          BuildContext context, NoteWriter writer, RoamNode node,
          {String initialText = ''}) async =>
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => AppendScreen(
            writer: writer, node: node, initialText: initialText),
      )) ??
      false;

  @override
  State<AppendScreen> createState() => _AppendScreenState();
}

class _AppendScreenState extends State<AppendScreen> {
  late final _text = TextEditingController(text: widget.initialText);
  bool _saving = false;

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

  Future<void> _save() async {
    final editor = widget.writer.editor;
    final node = widget.node;
    if (editor == null || _text.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final base = await editor.read(node.file);
      if (!mounted) return;
      if (base == null) {
        _tell('Could not read ${node.file}.');
        return;
      }
      final text = appendToNode(base.text, node, _text.text);
      if (text == null) {
        _tell('The heading is no longer in ${node.file}; the file changed '
            'since the app read it.');
        return;
      }
      final result = await editor.save(node.file, base, text);
      if (!mounted) return;
      switch (result) {
        case Saved() || NothingToSave():
          Navigator.of(context).pop(true);
        case SavedNotIndexed(:final message):
          _tell('Added; the graph shows it after the next scan ($message).');
          Navigator.of(context).pop(true);
        case ChangedMeanwhile():
          _tell('${node.file} changed while saving. Your text is still '
              'here: save again to add it to the new version.');
        case NoteGone():
          _tell('${node.file} is no longer in the folder.');
        case LockedPartChanged():
          _tell('The text must not hold a property drawer: the :ID: and '
              'the drawers stay as they are.');
        case NoWriteAccessToEdit():
          _tell('The app may only read the folder. Choose it again to '
              'allow writing.');
          await widget.writer.allowWriting();
        case SaveFailed(:final message):
          _tell('Could not save: $message');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    return Scaffold(
      appBar: AppBar(
        title: Text('Add to ${node.displayTitle}'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed:
                _saving || _text.text.trim().isEmpty ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            node.isFile
                ? 'Goes to the end of ${node.file}.'
                : 'Goes to the end of the heading "${node.displayTitle}", '
                    'after its subheadings.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('append-text'),
            controller: _text,
            autofocus: true,
            minLines: 6,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Org text, for example a thought or [[id:…][a link]]',
            ),
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
