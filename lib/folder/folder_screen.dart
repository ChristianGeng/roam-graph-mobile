import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../ai/ai_settings.dart';
import '../help/help.dart';
import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../edit/append_screen.dart';
import '../edit/edit_proposal.dart';
import '../edit/edit_screen.dart';
import '../edit/node_picker.dart';
import '../edit/note_editor.dart';
import '../graph/graph_index.dart';
import '../graph/roam_graph.dart';
import '../graph_view/graph_screen.dart';
import '../graph_view/node_memory.dart';
import '../node_view/node_screen.dart';
import '../node_view/note_images.dart';
import 'folder_access.dart';
import 'org_files.dart';

/// Builds the graph view, for [FolderScreen.graphScreen].
typedef GraphScreenBuilder = Widget Function(
  ValueListenable<RoamGraph> graph,
  NoteReader readNote,
  NoteOpener openInOrgro,
  NoteWriter writer,
  NoteFiles files,
);

/// Lets the user choose the org folder (#3), keeps the graph's database up
/// to date with it (#4, #5) and shows what it holds, to compare with
/// org-roam on the laptop. From there, the graph view (#6) opens.
class FolderScreen extends StatefulWidget {
  const FolderScreen({
    super.key,
    required this.folderAccess,
    required this.version,
    this.graphIndex = const SqliteGraphIndex(),
    this.graphScreen = defaultGraphScreen,
    this.shareInbox = const PlatformShareInbox(),
    this.nodeMemory = const FileNodeMemory(),
    this.editHistory = const FileEditHistory(),
  });

  final FolderAccess folderAccess;

  /// Where old versions of edited notes are kept (#35).
  final EditHistory editHistory;
  final String version;
  final GraphIndex graphIndex;

  /// Builds the graph view; tests replace it. The graph it gets follows
  /// the index, also while the graph view is open; [NoteReader] reads the
  /// notes of the chosen folder, and [NoteOpener] opens them in Orgro;
  /// [NoteFiles] reads the folder's other files, for images (#46).
  final GraphScreenBuilder graphScreen;

  /// Text shared with the app, which becomes a new node (#15).
  final ShareInbox shareInbox;

  /// The node viewed last, which a shared node may link to.
  final NodeMemory nodeMemory;

  static Widget defaultGraphScreen(
    ValueListenable<RoamGraph> graph,
    NoteReader readNote,
    NoteOpener openInOrgro,
    NoteWriter writer,
    NoteFiles files,
  ) =>
      GraphScreen(
        graph: graph,
        readNote: readNote,
        files: files,
        openInOrgro: openInOrgro,
        writer: writer,
      );

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

enum _Status { loading, noFolder, accessLost, noRoam, indexed, failed }

/// What the screen shows after reading a folder: the graph, and the files
/// that could not be read.
typedef _Result = ({
  RoamGraph? graph,
  List<String> unreadable,
  List<String> conflicts,
});

const _noResult = (graph: null, unreadable: <String>[], conflicts: <String>[]);

class _FolderScreenState extends State<FolderScreen>
    with WidgetsBindingObserver {
  _Status _status = _Status.loading;
  ChosenFolder? _folder;
  _Result _result = _noResult;
  String _error = '';

  /// Counts operations; only the latest one may change what is shown, so a
  /// slow, older scan cannot replace a newer result.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.shareInbox.listen(_takeShare);
    _start();
  }

  /// The latest graph, for an open graph view; null before the first.
  ValueNotifier<RoamGraph>? _graph;

  /// The files of the latest graph, by path relative to roam/.
  Map<String, FolderFile> _roamFiles = {};

  /// Every file of the chosen folder at the latest scan, by path relative
  /// to it, for images in notes (#46).
  Map<String, FolderFile> _folderFiles = {};

  /// The path of roam/ in the chosen folder at the latest scan: `roam/`,
  /// or empty when the chosen folder is roam/ itself.
  String _roamPrefix = '';

  /// The number of scans that found roam/, for images whose folder gives
  /// no modification time (#46).
  int _scans = 0;

  late final NoteFiles _files = _FolderNoteFiles(this);

  /// The URI of roam/ itself, where new notes go (#11).
  String? _roamDir;

  /// The conflict copies of the last scan; null before the first scan of a
  /// folder.
  Set<String>? _conflictsSeen;

  /// The folder [_conflictsSeen] belongs to.
  String? _conflictsFolder;

  late final _writer = NoteWriter(
    create: _createNote,
    allowWriting: _choose,
    editor: NoteEditor(
      store: _FolderNoteStore(this),
      history: widget.editHistory,
    ),
  );

  /// Notes to read at the next scan whatever their modification time: the
  /// ones an edit just replaced.
  final _mustRead = <String>{};

  /// The URIs of the chosen folder's directories at the latest scan, by
  /// path relative to it; the folder itself is "".
  Map<String, String> _dirs = {};

  /// True while a share is being turned into a node.
  bool _sharing = false;

  /// Opens the capture for text shared with the app (#15), once the folder
  /// is indexed; until then, shares wait. Shares that came during a
  /// capture are taken one after another when it closes.
  Future<void> _takeShare() async {
    if (_sharing) return;
    _sharing = true;
    try {
      // The next share, as long as one came meanwhile.
      while (mounted && await _captureShare()) {}
    } on PlatformException {
      // No share to take; nothing to show.
    } on MissingPluginException {
      // Not on Android, as in tests without a share inbox.
    } finally {
      _sharing = false;
    }
  }

  /// Takes one share and lets the user capture it; false if there was none
  /// to take, or the folder is not indexed yet.
  Future<bool> _captureShare() async {
    final notifier = _graph;
    if (_status != _Status.indexed || notifier == null) return false;
    final shared = await widget.shareInbox.take();
    if (shared == null || !mounted) return false;
    final proposal = proposeNode(shared);
    final last = notifier.value.nodes[await widget.nodeMemory.lastNode()];
    if (!mounted) return false;
    // Set when the share goes to an existing node instead; the next share
    // waits until that is done.
    Future<void>? intoNode;
    final id = await CaptureScreen.open(
      context,
      _writer,
      initialTitle: proposal.title,
      initialBody: proposal.body,
      // Offered, not on: a shared text is often about something else.
      linkTo: last == null ? null : (id: last.id, title: last.displayTitle),
      linkByDefault: false,
      // Or the share changes an existing node (#39).
      useForExisting: (use) =>
          intoNode = _shareIntoNode(use, shared.text, last),
    );
    if (intoNode != null) {
      await intoNode;
      return true;
    }
    if (id != null && mounted) {
      NodeScreen.open(
        context,
        graph: notifier,
        id: id,
        readNote: _readNote,
        files: _files,
        nodeMemory: widget.nodeMemory,
        openInOrgro: _openInOrgro,
        writer: _writer,
      );
    }
    return true;
  }

  /// Shared text added to, or replacing the text of, a node the user
  /// chooses (#39); the node viewed last is proposed. Replacing goes
  /// through the editor and its diff, so nothing is saved unseen.
  Future<void> _shareIntoNode(ShareUse use, String text, RoamNode? last) async {
    final graph = _graph?.value;
    if (graph == null || !mounted) return;
    final node = await NodePicker.pick(context, graph,
        proposed: last,
        title: use == ShareUse.append
            ? 'Add the shared text to'
            : 'Replace the text of');
    if (node == null || !mounted) return;
    final message = use == ShareUse.append
        ? await AppendScreen.open(context, _writer, node, initialText: text)
        : await EditScreen.open(context, _writer, node,
            initialBody: bodyFor(text, node));
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Writes a new note into roam/ and indexes the folder (#11).
  Future<CreateResult> _createNote(String fileName, String text) async {
    final folder = _folder;
    final dir = _roamDir;
    if (folder == null || dir == null) {
      return const CreateFailed('No folder is indexed.');
    }
    if (!folder.canWrite) return const NoWriteAccess();
    try {
      await widget.folderAccess
          .createFile(dir, fileName, Uint8List.fromList(utf8.encode(text)));
    } on PlatformException catch (e) {
      return e.code == 'exists'
          ? const FileExists()
          : CreateFailed(e.message ?? e.code);
    }
    await _rescan();
    // The file is written; if indexing failed, it must not be written
    // again, but it cannot be opened yet either.
    if (!(_result.graph?.files.contains(fileName) ?? false)) {
      return WrittenNotIndexed(
          fileName, _status == _Status.failed ? _error : 'it was not found');
    }
    return Created(fileName);
  }

  /// Opens the note at [path], relative to roam/, in Orgro.
  Future<OpenResult> _openInOrgro(String path) async {
    final file = _roamFiles[path];
    if (file == null) return OpenResult.noFile;
    try {
      return await widget.folderAccess.openWith(file, orgroPackage)
          ? OpenResult.opened
          : OpenResult.noOrgro;
    } on PlatformException {
      return OpenResult.noFile;
    }
  }

  /// Reads the note at [path], relative to roam/, for the node view.
  Future<String?> _readNote(String path) async {
    final file = _roamFiles[path];
    if (file == null) return null;
    try {
      final bytes = await widget.folderAccess.readFiles([file]);
      final content = bytes.firstOrNull;
      return content == null ? null : utf8.decode(content, allowMalformed: true);
    } on PlatformException {
      return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _graph?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkSavedFolder();
  }

  /// When the app comes back, the saved folder may have changed: a folder
  /// chosen while Android recreated the app, or a permission revoked in the
  /// system settings. Syncthing may also have brought new files, or the
  /// roam/ folder itself, and a failed scan may work now. So index again;
  /// unchanged files are not read again.
  Future<void> _checkSavedFolder() async {
    if (_status == _Status.loading) return;
    try {
      final saved = await widget.folderAccess.savedFolder();
      if (saved == null || !mounted || _status == _Status.loading) return;
      final current = _folder;
      if (current == null ||
          saved.uri != current.uri ||
          saved.hasAccess != current.hasAccess ||
          _status == _Status.indexed ||
          _status == _Status.noRoam ||
          _status == _Status.failed) {
        await _guard((generation) => _index(generation, saved));
      }
    } on PlatformException {
      // Keep what is shown; the next action reports the error.
    }
  }

  /// On start: index the folder chosen earlier, if there is one.
  Future<void> _start() => _guard((generation) async {
        final folder = await widget.folderAccess.savedFolder();
        if (folder == null) {
          _show(generation, _Status.noFolder, null, _noResult);
        } else {
          await _index(generation, folder);
        }
      });

  /// Opens the folder picker. If the user cancels, nothing changes.
  Future<void> _choose() {
    final previous = (_status, _folder, _result);
    return _guard((generation) async {
      final folder = await widget.folderAccess.pickFolder();
      if (folder == null) {
        _show(generation, previous.$1, previous.$2, previous.$3);
      } else {
        await _index(generation, folder);
      }
    });
  }

  Future<void> _rescan() async {
    final folder = _folder;
    if (folder != null) {
      await _guard((generation) => _index(generation, folder));
    }
  }

  /// Reads every file again and replaces the whole index. The old index
  /// stays until the new one is complete.
  Future<void> _rebuild() async {
    final folder = _folder;
    if (folder != null) {
      await _guard(
          (generation) => _index(generation, folder, rebuild: true));
    }
  }

  Future<void> _index(
    int generation,
    ChosenFolder folder, {
    bool rebuild = false,
  }) async {
    // Remember the folder first, so "Try again" works if listing fails.
    if (generation == _generation) {
      // roam/ of another folder must not receive a capture (#11).
      if (_folder?.uri != folder.uri) _roamDir = null;
      _folder = folder;
    }
    if (!folder.hasAccess) {
      _show(generation, _Status.accessLost, folder, _noResult);
      return;
    }
    final entries = await widget.folderAccess.listFiles(folder);
    final files = selectRoamFiles(folder.name, entries);
    if (files == null) {
      // No graph, but conflict copies can be anywhere in the folder.
      _show(generation, _Status.noRoam, folder, (
        graph: null,
        unreadable: const [],
        conflicts: conflictCopies(entries),
      ));
      return;
    }
    // Paths in the graph are relative to roam/, as in org-roam.
    final prefix = roamPrefix(folder.name, entries)!;
    final byPath = {
      for (final file in files) file.path.substring(prefix.length): file,
    };
    final listing = {
      for (final MapEntry(key: path, value: file) in byPath.entries)
        path: file.modified,
    };
    // Read only what is new or changed since the last time, unless the
    // index is rebuilt or holds another folder's files.
    final index = widget.graphIndex;
    final replace =
        rebuild || await index.indexedFolder() != folder.uri;
    // Notes saved by an edit (#35), even if their folder reports the same
    // modification time as before. They stay in [_mustRead] until an
    // update has stored them, so a failed or superseded scan keeps them.
    final forced = {..._mustRead};
    final toRead = replace
        ? listing.keys.toList()
        : {
            ...await index.filesToRead(listing),
            ...forced.where(listing.containsKey),
          }.toList();
    final bytes = await widget.folderAccess
        .readFiles([for (final path in toRead) byPath[path]!]);
    final contents = {
      for (var i = 0; i < toRead.length; i++)
        toRead[i]: i < bytes.length ? bytes[i] : null,
    };
    // A newer operation has started and reads the files again; an older
    // scan must not store its contents after the newer one. The index runs
    // its calls in order, so checking here, before the call, is enough.
    if (generation != _generation) return;
    final graph = await index.update(listing, contents,
        folder: folder.uri, replace: replace);
    _mustRead.removeAll(forced);
    final unreadable = [
      for (final MapEntry(key: path, value: content) in contents.entries)
        if (content == null) path,
    ];
    if (generation == _generation) {
      _roamFiles = byPath;
      _folderFiles = {
        for (final entry in entries)
          if (!entry.isDirectory) entry.path: entry,
      };
      _roamPrefix = prefix;
      _dirs = {
        '': folder.uri,
        for (final entry in entries)
          if (entry.isDirectory) entry.path: entry.uri,
      };
      _scans++;
      // roam/ itself: the folder, or its roam/ subfolder.
      _roamDir = prefix.isEmpty
          ? folder.uri
          : entries
              .firstWhere((e) => e.isDirectory && '${e.path}/' == prefix,
                  orElse: () => FolderFile(path: '', uri: folder.uri))
              .uri;
    }
    _show(generation, _Status.indexed, folder,
        (
          graph: graph,
          unreadable: unreadable,
          conflicts: conflictCopies(entries),
        ));
  }

  /// Runs [work] with the spinner showing, and shows its error if it fails.
  /// [work] gets the operation's generation: once a newer operation has
  /// started, an older one can no longer change what is shown.
  Future<void> _guard(Future<void> Function(int generation) work) async {
    final generation = ++_generation;
    if (_status != _Status.loading) {
      setState(() => _status = _Status.loading);
    }
    try {
      await work(generation);
    } on PlatformException catch (e) {
      _fail(generation, e.message ?? e.code);
    } catch (e) {
      _fail(generation, '$e');
    }
  }

  void _show(
    int generation,
    _Status status,
    ChosenFolder? folder,
    _Result result,
  ) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _status = status;
      _folder = folder;
      _result = result;
    });
    // Conflict copies that appear later, for example on resume, are
    // reported wherever the user is, also over the graph (#13): those not
    // seen by the last scan of the folder, also when another one was
    // resolved meanwhile. Those found by the first scan of a folder are
    // listed on this screen, which is then the one on show.
    final scanned = status == _Status.indexed || status == _Status.noRoam;
    final seen = _conflictsFolder == folder?.uri ? _conflictsSeen : null;
    final fresh = seen == null
        ? const <String>[]
        : [
            for (final path in result.conflicts)
              if (!seen.contains(path)) path,
          ];
    if (scanned && fresh.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(fresh.length == 1
            ? 'Syncthing made a new conflict copy in the folder. '
                'Resolve it in Emacs; the counts screen lists it.'
            : 'Syncthing made ${fresh.length} new conflict copies in the '
                'folder. Resolve them in Emacs; the counts screen lists '
                'them.'),
      ));
    }
    if (scanned) {
      _conflictsSeen = result.conflicts.toSet();
      _conflictsFolder = folder?.uri;
    }
    // A share that waited for the index (#15).
    if (status == _Status.indexed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeShare());
    }
    // An open graph view shows the new graph. Other results, such as a
    // failed scan, leave it as it is.
    if (result.graph case final graph?) {
      if (_graph case final notifier?) {
        notifier.value = graph;
      } else {
        _graph = ValueNotifier(graph);
      }
    }
  }

  void _fail(int generation, String message) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _status = _Status.failed;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roam Graph'),
        actions: [
          IconButton(
            tooltip: 'Help',
            icon: const Icon(Icons.help_outline),
            onPressed: () => openHelp(context),
          ),
          IconButton(
            tooltip: 'AI settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => AiSettingsScreen.open(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _body(context),
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Version ${widget.version}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final chooseButton = FilledButton(
      onPressed: _choose,
      child: const Text('Choose org folder'),
    );
    switch (_status) {
      case _Status.loading:
        return const CircularProgressIndicator();
      case _Status.noFolder:
        return _column([
          Text('Choose your org folder', style: text.titleLarge),
          const Text(
            'Pick the folder Syncthing keeps in sync: the org folder that '
            'contains roam/, or roam/ itself.',
            textAlign: TextAlign.center,
          ),
          chooseButton,
        ]);
      case _Status.accessLost:
        return _column([
          Text('Access to the folder was lost', style: text.titleLarge),
          Text(
            'Android no longer lets the app read "${_folder?.name}". '
            'Choose the folder again.',
            textAlign: TextAlign.center,
          ),
          chooseButton,
        ]);
      case _Status.noRoam:
        return _column([
          Text('No roam/ folder here', style: text.titleLarge),
          Text(
            '"${_folder?.name}" has no roam/ folder and is not roam/ itself. '
            'Choose the org folder that contains roam/, or roam/ itself.',
            textAlign: TextAlign.center,
          ),
          if (_result.conflicts.isNotEmpty) _conflictList(),
          OutlinedButton(onPressed: _rescan, child: const Text('Scan again')),
          chooseButton,
        ]);
      case _Status.indexed:
        return _column([
          Text('Graph in roam/', style: text.titleLarge),
          // Also without nodes: the graph offers "New node" (#11).
          if ((_result.graph, _graph) case (_?, final notifier?))
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) =>
                      widget.graphScreen(
                          notifier, _readNote, _openInOrgro, _writer, _files),
                ),
              ),
              icon: const Icon(Icons.hub_outlined),
              label: const Text('Show graph'),
            ),
          if (_result.graph case final graph?)
            _GraphSummary(
              graph: graph,
              unreadable: _result.unreadable,
              conflicts: _result.conflicts.length,
            ),
          if (_result.graph case final graph? when graph.failedFiles.isNotEmpty)
            _FileList(
              title: 'Files org-roam skips',
              files: [
                for (final entry in graph.failedFiles.entries)
                  '${entry.key}: ${entry.value}',
              ],
            ),
          if (_result.unreadable.isNotEmpty)
            _FileList(title: 'Unreadable files', files: _result.unreadable),
          if (_result.conflicts.isNotEmpty) _conflictList(),
          Text('Folder: ${_folder?.name}'),
          OutlinedButton(onPressed: _rescan, child: const Text('Scan again')),
          TextButton(
            onPressed: _rebuild,
            child: const Text('Rebuild index'),
          ),
          TextButton(onPressed: _choose, child: const Text('Change folder')),
        ]);
      case _Status.failed:
        return _column([
          Text('Could not read the folder', style: text.titleLarge),
          Text(_error, textAlign: TextAlign.center),
          if (_folder != null)
            OutlinedButton(onPressed: _rescan, child: const Text('Try again')),
          chooseButton,
        ]);
    }
  }

  /// Every conflict copy, so each can be found and resolved (#13).
  Widget _conflictList() => _FileList(
        title: 'Syncthing conflict copies: resolve them in Emacs',
        files: _result.conflicts,
        shown: null,
      );

  Widget _column(List<Widget> children) => Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: children,
      );
}

/// The counts to compare with org-roam's database on the laptop.
class _GraphSummary extends StatelessWidget {
  const _GraphSummary({
    required this.graph,
    required this.unreadable,
    required this.conflicts,
  });

  final RoamGraph graph;
  final List<String> unreadable;

  /// The number of Syncthing conflict copies in the folder (#13).
  final int conflicts;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('files', 'Files', graph.files.length),
      ('nodes', 'Nodes', graph.nodes.length),
      ('file-nodes', '  in files', graph.fileNodeCount),
      ('heading-nodes', '  in headings', graph.headingNodeCount),
      ('links', 'id: links', graph.links.length),
      ('dangling', 'Links to missing notes', graph.danglingLinks.length),
      ('tags', 'Tags', graph.tagCount),
      ('refs', 'Refs', graph.refCount),
      ('aliases', 'Aliases', graph.aliasCount),
      if (graph.duplicateIds.isNotEmpty)
        ('duplicates', 'IDs used twice', graph.duplicateIds.length),
      if (graph.failedFiles.isNotEmpty)
        ('skipped', 'Files org-roam skips', graph.failedFiles.length),
      if (unreadable.isNotEmpty)
        ('unreadable', 'Unreadable files', unreadable.length),
      if (conflicts > 0) ('conflicts', 'Syncthing conflict copies', conflicts),
    ];
    final bold = Theme.of(context)
        .textTheme
        .bodyLarge
        ?.copyWith(fontWeight: FontWeight.bold);
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        for (final (key, label, value) in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 24, 4),
                child: Text(label),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '$value',
                  key: ValueKey('stat-$key'),
                  textAlign: TextAlign.end,
                  style: bold,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Names of files with a problem, so they can be found and fixed.
class _FileList extends StatelessWidget {
  const _FileList({required this.title, required this.files, this.shown = 10});

  /// How many files are listed by name; all when null.
  final int? shown;

  final String title;
  final List<String> files;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        for (final file in files.take(shown ?? files.length)) Text(file),
        if (shown case final limit? when files.length > limit)
          Text('and ${files.length - limit} more'),
      ],
    );
  }
}

/// The files of the chosen folder at the latest scan, for images in notes
/// (#46): what [FolderAccess.listFiles] listed, read with
/// [FolderAccess.readFiles] by content URI.
class _FolderNoteFiles implements NoteFiles {
  _FolderNoteFiles(this._state);

  final _FolderScreenState _state;

  /// [path], relative to roam/, as a path relative to the chosen folder.
  String _inFolder(String path) =>
      normalizePath('${_state._roamPrefix}$path');

  @override
  bool reaches(String path) {
    final inFolder = _inFolder(path);
    return inFolder != '..' && !inFolder.startsWith('../');
  }

  @override
  FolderFile? find(String path) =>
      reaches(path) ? _state._folderFiles[_inFolder(path)] : null;

  @override
  int version(FolderFile file) =>
      file.modified != 0 ? file.modified : -_state._scans;

  @override
  Future<Uint8List?> read(FolderFile file) async {
    try {
      return (await _state.widget.folderAccess.readFiles([file])).firstOrNull;
    } on PlatformException {
      return null;
    }
  }
}

/// [NoteStore] on the chosen folder (#35): reads a note's bytes, and
/// replaces the file through `FolderAccess.replaceFile`, which checks the
/// hash just before writing. Then the folder is indexed again, so the
/// graph, the node view and the backlinks show the change.
class _FolderNoteStore implements NoteStore {
  _FolderNoteStore(this._state);

  final _FolderScreenState _state;

  FolderAccess get _access => _state.widget.folderAccess;

  @override
  Future<NoteVersion?> read(String path) async {
    final file = _state._roamFiles[path];
    if (file == null) return null;
    try {
      final bytes = (await _access.readFiles([file])).firstOrNull;
      return bytes == null ? null : NoteVersion.of(bytes);
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<SaveResult> replace(String path, NoteVersion base, String text) async {
    final folder = _state._folder;
    final file = _state._roamFiles[path];
    if (folder == null || file == null) return const NoteGone();
    if (!folder.canWrite) return const NoWriteAccessToEdit();
    final slash = file.path.lastIndexOf('/');
    final dir = _state._dirs[slash < 0 ? '' : file.path.substring(0, slash)];
    if (dir == null) return const SaveFailed('Its folder was not found.');
    try {
      await _access.replaceFile(
        dir,
        file.path.substring(slash + 1),
        file.uri,
        expected: base.hash,
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'changed':
          return ChangedMeanwhile(await read(path));
        case 'missing':
          return const NoteGone();
        default:
          return SaveFailed(e.message ?? e.code);
      }
    }
    _state._mustRead.add(path);
    await _state._rescan();
    if (_state._status != _Status.indexed) {
      return SavedNotIndexed(path, _state._error);
    }
    return Saved(path);
  }

  @override
  Future<SaveResult> delete(String path, NoteVersion base) async {
    final folder = _state._folder;
    final file = _state._roamFiles[path];
    if (folder == null || file == null) return const NoteGone();
    if (!folder.canWrite) return const NoWriteAccessToEdit();
    try {
      await _access.deleteFile(file.uri, expected: base.hash);
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'changed':
          return ChangedMeanwhile(await read(path));
        case 'missing':
          return const NoteGone();
        default:
          return SaveFailed(e.message ?? e.code);
      }
    }
    await _state._rescan();
    if (_state._status != _Status.indexed) {
      return SavedNotIndexed(path, _state._error);
    }
    return Saved(path);
  }

  @override
  String historyKey(String path) => '${_state._folder?.uri ?? ''}\n$path';
}
