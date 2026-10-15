import 'package:material_ui/material_ui.dart';

import 'new_node.dart';

/// What happened when a note was to be written.
sealed class CreateResult {
  const CreateResult();
}

/// The file was written and indexed; [path] is relative to `roam/`.
class Created extends CreateResult {
  const Created(this.path);

  final String path;
}

/// The file was written, but indexing the folder afterwards failed, so the
/// node cannot be opened yet; it appears with the next scan.
class WrittenNotIndexed extends CreateResult {
  const WrittenNotIndexed(this.path, this.message);

  final String path;
  final String message;
}

/// The app may only read the folder: it was chosen before v2.
class NoWriteAccess extends CreateResult {
  const NoWriteAccess();
}

/// A file of that name exists already; nothing was written.
class FileExists extends CreateResult {
  const FileExists();
}

class CreateFailed extends CreateResult {
  const CreateFailed(this.message);

  final String message;
}

/// Writes new notes into `roam/` (#11) and indexes them.
class NoteWriter {
  const NoteWriter({required this.create, required this.allowWriting});

  /// Writes [text] as the new file [fileName] in `roam/`, then indexes the
  /// folder, so the graph has the new node when this returns.
  final Future<CreateResult> Function(String fileName, String text) create;

  /// Asks Android for write access: opens the folder picker.
  final Future<void> Function() allowWriting;
}

/// Creates a new node (#11), as org-roam's default capture template does
/// on the laptop: `roam/<%Y%m%d%H%M%S>-<slug>.org`, with a new `:ID:`,
/// `#+title:` and `#+filetags:`. Returns the new node's ID.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.writer,
    this.now = DateTime.now,
    this.linkTo,
    this.linkByDefault = true,
    this.initialTitle = '',
    this.initialBody = '',
  });

  final NoteWriter writer;

  /// The node the capture starts from (#12): the new file can link to it,
  /// so it shows the new node as a backlink. The existing file is never
  /// changed.
  final ({String id, String title})? linkTo;

  /// Whether the link is on at first.
  final bool linkByDefault;

  /// What the fields start with, for shared text (#15).
  final String initialTitle;
  final String initialBody;

  /// The clock, for the file name; tests replace it.
  final DateTime Function() now;

  /// Opens the capture screen; completes with the new node's ID, or null.
  static Future<String?> open(
    BuildContext context,
    NoteWriter writer, {
    ({String id, String title})? linkTo,
    bool linkByDefault = true,
    String initialTitle = '',
    String initialBody = '',
  }) =>
      Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (context) => CaptureScreen(
            writer: writer,
            linkTo: linkTo,
            linkByDefault: linkByDefault,
            initialTitle: initialTitle,
            initialBody: initialBody,
          ),
        ),
      );

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late final _title = TextEditingController(text: widget.initialTitle);
  final _tags = TextEditingController();
  late final _body = TextEditingController(text: widget.initialBody);
  bool _saving = false;
  late bool _link = widget.linkByDefault;

  /// True once the file is written, so it is not written twice.
  bool _written = false;

  /// Why the last save failed, shown above the fields.
  String? _problem;
  bool _needsWriteAccess = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _tags.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = oneLine(_title.text);
    if (title.isEmpty || _saving || _written) return;
    setState(() {
      _saving = true;
      _problem = null;
      _needsWriteAccess = false;
    });
    final id = newOrgId();
    final fileName = nodeFileName(widget.now(), title);
    final text = nodeFileText(
      id: id,
      title: title,
      tags: parseTags(_tags.text),
      body: _body.text,
      linkTo: _link ? widget.linkTo : null,
    );
    final result = await widget.writer.create(fileName, text);
    if (!mounted) return;
    switch (result) {
      case Created():
        Navigator.pop(context, id);
        return;
      case NoWriteAccess():
        _problem = 'The app may only read the folder. Choose it again and '
            'allow access, then save.';
        _needsWriteAccess = true;
      case WrittenNotIndexed(:final path, :final message):
        _problem = 'Saved as roam/$path, but the folder could not be '
            'indexed: $message. The node appears after the next scan.';
        _written = true;
      case FileExists():
        _problem = '$fileName exists already. Wait a second and save again.';
      case CreateFailed(:final message):
        _problem = 'Could not write $fileName: $message';
    }
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final title = oneLine(_title.text);
    return Scaffold(
      appBar: AppBar(
        title: const Text('New node'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed: title.isEmpty || _saving || _written ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_problem case final problem?)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(
                    problem,
                    key: const ValueKey('capture-problem'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error),
                  ),
                  if (_needsWriteAccess)
                    OutlinedButton(
                      onPressed: widget.writer.allowWriting,
                      child: const Text('Choose folder'),
                    ),
                ],
              ),
            ),
          TextField(
            key: const ValueKey('capture-title'),
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
            textInputAction: TextInputAction.next,
          ),
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'File: roam/${nodeFileName(widget.now(), title)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('capture-tags'),
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags',
              hintText: 'Separated by spaces or commas',
            ),
            textInputAction: TextInputAction.next,
          ),
          if (widget.linkTo case final linkTo?)
            CheckboxListTile(
              key: const ValueKey('capture-link'),
              contentPadding: EdgeInsets.zero,
              value: _link,
              onChanged: (on) => setState(() => _link = on ?? false),
              title: Text('Link to ${linkTo.title}'),
              subtitle: const Text('In the new file; it shows as a backlink.'),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('capture-body'),
            controller: _body,
            decoration: const InputDecoration(
              labelText: 'Text',
              alignLabelWithHint: true,
            ),
            minLines: 6,
            maxLines: null,
            keyboardType: TextInputType.multiline,
          ),
        ],
      ),
    );
  }
}
