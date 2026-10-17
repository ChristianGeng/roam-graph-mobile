import 'package:material_ui/material_ui.dart';

import '../capture/capture_screen.dart';
import '../graph/roam_graph.dart';
import 'diff_screen.dart';
import 'note_editor.dart';
import 'save_messages.dart';

/// The versions of a note kept before each edit (#35), newest first. One
/// can be restored: the diff (#38) shows what restoring it changes in the
/// note as it is now, and only "Restore" saves it, as every edit is saved.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.writer, required this.node});

  final NoteWriter writer;
  final RoamNode node;

  static Future<void> open(
          BuildContext context, NoteWriter writer, RoamNode node) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => HistoryScreen(writer: writer, node: node),
      ));

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<KeptVersion>> _versions = _load();

  /// The note's folder and path when the screen opened. Its versions are
  /// that note's; after another folder is chosen, the same path there is
  /// another note, and nothing is restored into it.
  String? _noteKey;

  @override
  void initState() {
    super.initState();
    _noteKey = widget.writer.editor?.store.historyKey(widget.node.file);
  }

  Future<List<KeptVersion>> _load() async =>
      await widget.writer.editor?.versions(widget.node.file) ?? const [];

  void _tell(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _restore(KeptVersion version) async {
    final editor = widget.writer.editor;
    final file = widget.node.file;
    if (editor == null) return;
    if (editor.store.historyKey(file) != _noteKey) {
      _tell('Another folder is open now. These versions belong to the '
          'note in the folder opened before; nothing was restored.');
      return;
    }
    final current = await editor.read(file);
    if (!mounted) return;
    if (current == null) {
      _tell('Could not read $file.');
      return;
    }
    final restore = await DiffScreen.confirm(
      context,
      title: 'Restore ${_when(version.time)}',
      before: current.text,
      after: version.text,
      saveLabel: 'Restore',
      backLabel: 'Back',
    );
    if (!restore || !mounted) return;
    final result = await editor.save(file, current, version.text);
    if (!mounted) return;
    final message = saveMessage(result, file);
    if (message == null) {
      _tell('Restored the version of ${_when(version.time)}.');
      // Restoring kept the version it replaced: show it in the list.
      setState(() {
        _versions = _load();
      });
    } else {
      _tell(message);
      if (result is NoWriteAccessToEdit) await widget.writer.allowWriting();
    }
  }

  static String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Earlier versions of ${widget.node.file}')),
      body: FutureBuilder<List<KeptVersion>>(
        future: _versions,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final versions = snapshot.data ?? const [];
          if (versions.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No earlier versions. The app keeps the version '
                  'a note had before each edit made here, the newest '
                  '$keptVersionsPerNote.'),
            );
          }
          return ListView(
            children: [
              for (final (i, version) in versions.indexed)
                ListTile(
                  key: ValueKey('version-$i'),
                  title: Text(_when(version.time)),
                  subtitle: Text(
                    'Before an edit made here; '
                    '${'\n'.allMatches(version.text).length} lines',
                  ),
                  trailing: const Icon(Icons.restore),
                  onTap: () => _restore(version),
                ),
            ],
          );
        },
      ),
    );
  }
}
