/// "Create image" (#112): an AI image model draws what I describe; after I
/// have seen it, the image goes into the image folder and the note gets a
/// link to it, shown inline as every image in the notes (#46).
library;

import 'package:material_ui/material_ui.dart';

import '../ai/ai_chat.dart';
import '../ai/ai_images.dart';
import '../ai/ai_settings.dart';
import '../capture/capture_screen.dart';
import '../capture/new_node.dart';
import '../graph/roam_graph.dart';
import '../settings/view_settings.dart';
import 'node_text.dart';
import 'note_editor.dart';
import 'save_messages.dart';

/// The image's path, relative to `roam/`: in [folder] (`.` is `roam/`),
/// named as capture names notes, `<time>-<slug of title>.<ext>`.
String imagePath(String folder, DateTime time, String title, String ext) {
  final name = nodeFileName(time, title.isEmpty ? 'image' : title)
      .replaceFirst(RegExp(r'\.org$'), '.$ext');
  return folder == '.' ? name : '$folder/$name';
}

/// [target], a path relative to `roam/`, as a link from the note [note]
/// (also relative to `roam/`): relative to the note's own folder, as Org
/// reads file links.
String relativeLink(String note, String target) {
  final from = note.split('/')..removeLast();
  final to = target.split('/');
  var same = 0;
  while (same < from.length &&
      same < to.length - 1 &&
      from[same] == to[same]) {
    same++;
  }
  return [
    for (var i = same; i < from.length; i++) '..',
    ...to.sublist(same),
  ].join('/');
}

/// What the image model is asked: [description], and, when [title] is
/// given, the note it is for, so a description such as "an image for this
/// note" can be drawn.
String imagePrompt(String description, String? title) =>
    title == null || title.trim().isEmpty
        ? description
        : '$description\n\nThe image is for a note titled "${oneLine(title)}".';

/// What is added to the note: the description as the caption, and the
/// link, each on its own line.
String imageAddition(String prompt, String link) =>
    '#+caption: ${oneLine(prompt)}\n[[file:$link]]\n';

class ImageScreen extends StatefulWidget {
  const ImageScreen({
    super.key,
    required this.writer,
    required this.node,
    this.post = postWithDartIo,
    this.download = downloadWithDartIo,
    this.now = DateTime.now,
  });

  /// Downloads an image a provider gives as a link (Qwen); tests replace
  /// it.
  final ImageDownload download;

  final NoteWriter writer;
  final RoamNode node;
  final HttpPost post;
  final DateTime Function() now;

  /// Opens the screen; completes with what to tell, or null.
  static Future<String?> open(
          BuildContext context, NoteWriter writer, RoamNode node,
          {HttpPost post = postWithDartIo}) =>
      Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => ImageScreen(writer: writer, node: node, post: post),
      ));

  @override
  State<ImageScreen> createState() => _ImageScreenState();
}

class _ImageScreenState extends State<ImageScreen> {
  final _prompt = TextEditingController();
  bool _working = false;

  /// Whether the image model is told the note's title, so "an image for
  /// this note" works (#112).
  bool _withTitle = true;
  String? _error;
  MadeImage? _image;

  /// The description [_image] was made from.
  String _madeFrom = '';

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() work) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final error = await work();
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Asks the image model; the image is only shown, not saved.
  Future<String?> _make() async {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) return 'Describe the image first.';
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return null;
    final keys = AiSettingsScope.keysOf(context);
    if (keys == null) return 'The AI settings are not available.';
    // The note may be hidden from AI meanwhile: nothing is sent then.
    final editor = widget.writer.editor;
    final text = editor == null ? null : await editor.read(widget.node.file);
    if (settings.visibility.hides(widget.node) ||
        (text != null &&
            settings.visibility.hidesInText(widget.node, text.text))) {
      return 'This note is hidden from AI; nothing was sent.';
    }
    if (!mounted) return null;
    // A new attempt: the image shown before is not saved by mistake.
    setState(() {
      _image = null;
      _madeFrom = '';
    });
    final config = await imageConfig(settings, keys);
    if (config == null) {
      return '${settings.preset.name} cannot make images in the app. '
          'Choose Vercel AI Gateway, OpenRouter or Custom in AI settings.';
    }
    try {
      final image = await makeImage(
          config, imagePrompt(prompt, _withTitle ? widget.node.displayTitle : null),
          post: widget.post, download: widget.download);
      if (mounted) {
        setState(() {
          _image = image;
          _madeFrom = prompt;
        });
      }
      return null;
    } on AiError catch (e) {
      return e.message;
    }
  }

  /// Writes the image into the image folder, then adds its link to the
  /// note, as every edit is saved (decision 10).
  Future<String?> _save() async {
    final image = _image;
    final editor = widget.writer.editor;
    final createFile = widget.writer.createFile;
    if (image == null || editor == null || createFile == null) return null;
    final node = widget.node;
    // The saved folder, also when the settings file loads slowly.
    final view = await ViewSettingsScope.current(context,
        limit: const Duration(seconds: 10));
    if (!mounted) return null;
    final base = await editor.read(node.file);
    if (base == null) return 'Could not read ${node.file}.';
    final lines = NodeLines.find(base.text, node);
    if (lines == null) {
      return '${node.displayTitle} is no longer in ${node.file} with its '
          ':ID:; nothing was saved.';
    }
    // A free name: a second later if the name is taken.
    var time = widget.now();
    String? path;
    for (var attempt = 0; attempt < 5 && path == null; attempt++) {
      final candidate =
          imagePath(view.imageFolder, time, node.displayTitle, image.extension);
      switch (await createFile(candidate, image.bytes)) {
        case Created() || WrittenNotIndexed():
          path = candidate;
        case FileExists():
          time = time.add(const Duration(seconds: 1));
        case NoWriteAccess():
          await widget.writer.allowWriting();
          return 'The app may only read the folder. Choose the folder again '
              'to allow writing, then save again.';
        case CreateFailed(:final message):
          return 'The image could not be written: $message';
      }
    }
    if (path == null) return 'No free file name for the image; try again.';
    final after = lines.withAddition(
        imageAddition(_madeFrom, relativeLink(node.file, path)));
    final result = await editor.save(node.file, base, after);
    if (!mounted) return null;
    switch (result) {
      case Saved() || NothingToSave():
        Navigator.of(context).pop('Added the image to ${node.displayTitle}.');
        return null;
      case SavedNotIndexed():
        // Saved: the screen closes, so the image is not added twice.
        Navigator.of(context).pop('Added the image to ${node.displayTitle}. '
            '${saveMessage(result, node.file)}');
        return null;
      default:
        return 'The image is saved as roam/$path, but the note was not '
            'changed: ${saveMessage(result, node.file)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(title: Text('Create image: ${widget.node.displayTitle}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('image-prompt'),
            controller: _prompt,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'What should the image show?',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey('image-with-title'),
            contentPadding: EdgeInsets.zero,
            value: _withTitle,
            onChanged: (on) => setState(() => _withTitle = on ?? true),
            title: Text('Tell the image model the note\'s title '
                '("${widget.node.displayTitle}")'),
          ),
          Text(_withTitle
              ? 'Only this description and the title are sent to the image '
                  'model. The image is saved only when you tap "Add to the '
                  'note".'
              : 'Only this description is sent to the image model. The '
                  'image is saved only when you tap "Add to the note".'),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('image-make'),
                onPressed: _working ? null : () => _run(_make),
                icon: const Icon(Icons.brush_outlined),
                label: Text(image == null ? 'Make image' : 'Try again'),
              ),
              if (image != null)
                FilledButton.icon(
                  key: const ValueKey('image-save'),
                  onPressed: _working ? null : () => _run(_save),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Add to the note'),
                ),
            ],
          ),
          if (_working)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                error,
                key: const ValueKey('image-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (image != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Image.memory(
                image.bytes,
                key: const ValueKey('image-preview'),
                fit: BoxFit.contain,
                errorBuilder: (context, _, _) =>
                    const Text('The image cannot be shown here.'),
              ),
            ),
        ],
      ),
    );
  }
}
