import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessException;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../ai/ai_settings.dart';
import '../ai/chat_list_screen.dart';
import '../help/help.dart';
import '../capture/capture_screen.dart';
import '../capture/new_node.dart' show newOrgId;
import '../capture/share_inbox.dart';
import '../capture/text_files.dart';
import '../edit/append_screen.dart';
import '../edit/edit_proposal.dart';
import '../edit/edit_screen.dart';
import '../edit/node_picker.dart';
import '../edit/note_editor.dart';
import '../edit/unsaved_text.dart';
import '../graph/graph_index.dart';
import '../graph/roam_db.dart' show TextHit;
import '../graph/roam_graph.dart';
import '../graph_view/graph_screen.dart';
import '../graph_view/node_memory.dart';
import '../node_view/node_screen.dart';
import '../node_view/note_images.dart';
import '../platform/desktop.dart';
import '../platform/text_drop.dart';
import '../settings/view_settings.dart';
import 'folder_access.dart';
import 'folder_report.dart';
import 'org_files.dart';

/// Builds the graph view, for [FolderScreen.graphScreen].
typedef GraphScreenBuilder = Widget Function(
  ValueListenable<RoamGraph> graph,
  NoteReader readNote,
  NoteOpener openElsewhere,
  NoteWriter writer,
  NoteFiles files,
  FolderControls folder,
);

/// Lets the user choose the org folder (#3) and keeps the graph's database
/// up to date with it (#4, #5). Once the folder is indexed, it shows the
/// graph view (#6) at once (#196); what the scan found is in the sheet
/// "Folder and index" of the graph. This page itself shows only the states
/// without a graph: no folder, access lost, no roam/ folder, a failed scan.
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
    this.startProcess = startDetached,
    this.pickTextFiles = pickTextFilesOnDesktop,
  });

  /// "Open files…" on the desktop (#220): the paths the user chose; tests
  /// replace it.
  final Future<List<String>> Function() pickTextFiles;

  final FolderAccess folderAccess;

  /// Starts Emacs on the desktop (#116); tests replace it.
  final ProcessStarter startProcess;

  /// Where old versions of edited notes are kept (#35).
  final EditHistory editHistory;
  final String version;
  final GraphIndex graphIndex;

  /// Builds the graph view; tests replace it. The graph it gets follows
  /// the index, also while the graph view is open; [NoteReader] reads the
  /// notes of the chosen folder, and [NoteOpener] opens them in another app;
  /// [NoteFiles] reads the folder's other files, for images (#46).
  final GraphScreenBuilder graphScreen;

  /// Text shared with the app, which becomes a new node (#15).
  final ShareInbox shareInbox;

  /// The node viewed last, which a shared node may link to.
  final NodeMemory nodeMemory;

  static Widget defaultGraphScreen(
    ValueListenable<RoamGraph> graph,
    NoteReader readNote,
    NoteOpener openElsewhere,
    NoteWriter writer,
    NoteFiles files,
    FolderControls folder,
  ) =>
      GraphScreen(
        graph: graph,
        readNote: readNote,
        files: files,
        openElsewhere: openElsewhere,
        writer: writer,
        folder: folder,
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

/// How often the indexed folder is checked for files changed from outside
/// while the app is in the foreground (#133).
const changeCheckInterval = Duration(seconds: 30);

class _FolderScreenState extends State<FolderScreen>
    with WidgetsBindingObserver {
  _Status _status = _Status.loading;
  ChosenFolder? _folder;
  _Result _result = _noResult;
  String _error = '';

  /// The last state that was not [_Status.loading]. While a scan runs over
  /// an open graph, the graph stays on show (#196).
  _Status _settled = _Status.loading;

  /// Tells the open sheet "Folder and index" that something changed.
  final _revision = ValueNotifier<int>(0);

  /// The number of problems of the last scan, for the graph's warning icon.
  final _problems = ValueNotifier<int>(0);

  /// True while the sheet "Folder and index" is open.
  bool _sheetOpen = false;

  /// True once the sheet has been asked to close, because the folder is no
  /// longer indexed.
  bool _sheetClosing = false;

  /// Counts operations; only the latest one may change what is shown, so a
  /// slow, older scan cannot replace a newer result.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.shareInbox.listen(_takeShare);
    TextDrop.add(_takeDrop);
    _start();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _startChecking();
    }
  }

  /// Checks the folder for changed files every [changeCheckInterval] while
  /// the app is in the foreground; null in the background.
  Timer? _changeTimer;

  /// True while a check lists the folder.
  bool _checking = false;

  void _startChecking() {
    _changeTimer ??=
        Timer.periodic(changeCheckInterval, (_) => _checkForChanges());
  }

  void _stopChecking() {
    _changeTimer?.cancel();
    _changeTimer = null;
  }

  /// Files that Syncthing brings, changed in Emacs, while the app stays
  /// open (#133): lists the folder and compares the modification times
  /// with the last scan, as [_checkSavedFolder] does on resume. Only when
  /// something changed is the folder indexed again, which reads only the
  /// changed files. No check while a scan runs, or while an editor has
  /// text not saved yet: its note must not change under it.
  Future<void> _checkForChanges() async {
    final folder = _folder;
    if (folder == null ||
        _checking ||
        _status != _Status.indexed ||
        UnsavedText.any) {
      return;
    }
    _checking = true;
    try {
      final generation = _generation;
      final entries = await widget.folderAccess.listFiles(folder);
      if (!mounted ||
          generation != _generation ||
          _status != _Status.indexed ||
          UnsavedText.any) {
        return;
      }
      final files = selectRoamFiles(folder.name, entries);
      final prefix = roamPrefix(folder.name, entries);
      final changed = files == null ||
          prefix == null ||
          _changedSinceScan({
            for (final file in files)
              file.path.substring(prefix.length): file.modified,
          }) ||
          !_sameSet(conflictCopies(entries), _result.conflicts);
      if (changed) await _rescan();
    } on PlatformException {
      // Not now; the next check or "Scan again" tries again.
    } finally {
      _checking = false;
    }
  }

  /// Whether [listing], modification times by path relative to roam/,
  /// differs from the last scan's: a file added, gone or changed.
  bool _changedSinceScan(Map<String, int> listing) =>
      listing.length != _roamFiles.length ||
      listing.entries.any((e) => _roamFiles[e.key]?.modified != e.value);

  static bool _sameSet(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

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
    createFile: _createRoamFile,
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

  /// Shares from the desktop itself (#220): drops onto the window, "New
  /// note from clipboard" and "Open files…". They are taken before those
  /// of [FolderScreen.shareInbox], in the same queue.
  final _localShares = <Share>[];

  /// Brings [share] in as if another app had shared it (#220).
  void _bringIn(Share share) {
    _localShares.add(share);
    _takeShare();
  }

  /// A drop onto the window that no chat took (#220).
  bool _takeDrop(Share share) {
    _bringIn(share);
    return true;
  }

  /// "New note from clipboard" and its keys on the desktop (#220).
  Future<void> _newFromClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      _tell('The clipboard has no text.');
      return;
    }
    _bringIn(SharedText(text));
  }

  /// "Open files…" on the desktop (#220).
  Future<void> _openFiles() async {
    final paths = await widget.pickTextFiles();
    if (paths.isEmpty || !mounted) return;
    _bringIn(await readLocalFiles(paths));
  }

  void _tell(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  /// Takes one share and lets the user capture it; false if there was none
  /// to take, or the folder is not indexed yet.
  Future<bool> _captureShare() async {
    final notifier = _graph;
    if (_status != _Status.indexed || notifier == null) return false;
    final share = _localShares.isNotEmpty
        ? _localShares.removeAt(0)
        : await widget.shareInbox.take();
    if (share == null || !mounted) return false;
    switch (share) {
      case SharedText(:final text):
        await _captureText(notifier, text, proposeNode(share));
      case SharedFiles(:final files):
        await _captureFiles(notifier, readTextFiles(files));
    }
    return true;
  }

  /// Text files shared or brought in (#220): one file as shared text with
  /// the file name as the proposed title; for several files, the user
  /// chooses one note per file or one note.
  Future<void> _captureFiles(
      ValueNotifier<RoamGraph> notifier, TextFiles read) async {
    final notes = read.notes;
    final files = read.files;
    if (files.isEmpty) {
      _tell(notes.isEmpty ? 'No files.' : notes.join('\n'));
      return;
    }
    if (files.length == 1) {
      await _captureFile(notifier, files.single,
          notice: notes.isEmpty ? null : notes.join('\n'));
      return;
    }
    final choice = await showDialog<_SeveralFiles>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${files.length} text files'),
        content: Text([
          ...notes,
          'Make one note per file, or one note with a heading for each '
              'file?',
        ].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _SeveralFiles.oneNote),
            child: const Text('One note'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _SeveralFiles.perFile),
            child: const Text('One note per file'),
          ),
        ],
      ),
    );
    switch (choice) {
      case null:
        return;
      case _SeveralFiles.perFile:
        // One after the other: the next opens when a capture closes.
        for (final (i, file) in files.indexed) {
          if (!mounted) return;
          await _captureFile(notifier, file,
              notice: 'File ${i + 1} of ${files.length}: ${file.name}');
        }
      case _SeveralFiles.oneNote:
        final text = joinFiles(files);
        await _captureText(notifier, text, (
          title: [for (final file in files) file.baseName].join(', '),
          body: text,
        ));
    }
  }

  Future<void> _captureFile(ValueNotifier<RoamGraph> notifier, TextFile file,
      {String? notice}) {
    final proposal = proposeFromFile(file);
    return _captureText(
      notifier,
      file.text,
      (title: proposal.title, body: proposal.body),
      tags: proposal.tags,
      name: file.name,
      orgFile: file.isOrg ? file : null,
      notice: notice,
    );
  }

  /// Opens the capture screen for shared [text], or a choice of its
  /// "Other uses of the text" menu: an existing node (#39), a chat, or,
  /// for [orgFile], an import as it is (#220).
  Future<void> _captureText(
    ValueNotifier<RoamGraph> notifier,
    String text,
    ({String title, String body}) proposal, {
    List<String> tags = const [],
    String? name,
    TextFile? orgFile,
    String? notice,
  }) async {
    final last = notifier.value.nodes[await widget.nodeMemory.lastNode()];
    if (!mounted) return;
    // Set when the share goes elsewhere; the next share waits until that
    // is done.
    Future<void>? instead;
    final id = await CaptureScreen.open(
      context,
      _writer,
      graph: notifier.value,
      initialTitle: proposal.title,
      initialBody: proposal.body,
      initialTags: tags,
      // Offered, not on: a shared text is often about something else.
      linkTo: last == null ? null : (id: last.id, title: last.displayTitle),
      linkByDefault: false,
      notice: notice,
      uses: {
        ShareUse.append,
        ShareUse.replace,
        ShareUse.askAi,
        ShareUse.addToChat,
        if (orgFile != null) ShareUse.importAsIs,
      },
      useForExisting: (use) => instead = switch (use) {
        ShareUse.append ||
        ShareUse.replace =>
          _shareIntoNode(use, text, last),
        ShareUse.askAi || ShareUse.addToChat => _shareIntoChat(
            sharedTextMessage(text, name: name),
            newChat: use == ShareUse.askAi),
        ShareUse.importAsIs => _importAsIs(orgFile!),
      },
    );
    if (instead case final instead?) {
      await instead;
      return;
    }
    if (id != null && mounted) _openNode(notifier, id);
  }

  void _openNode(ValueNotifier<RoamGraph> notifier, String id) =>
      NodeScreen.open(
        context,
        graph: notifier,
        id: id,
        readNote: _readNote,
        files: _files,
        nodeMemory: widget.nodeMemory,
        openElsewhere: _openElsewhere,
        writer: _writer,
      );

  /// "Ask AI" (a new chat) or "Add to a chat…" (a chat the user chooses)
  /// for shared text (#220): [message] goes into the message field, and
  /// nothing is sent until the user sends it.
  Future<void> _shareIntoChat(String message, {required bool newChat}) async {
    final notifier = _graph;
    if (notifier == null || !mounted) return;
    await ChatListScreen.open(
      context,
      graph: notifier,
      readNote: _readNote,
      openNewChat: newChat,
      initialInput: message,
      writer: _writer,
      searchText: _files.searchText,
      openNode: (_, id) {
        widget.nodeMemory.remember(id);
        _openNode(notifier, id);
      },
    );
  }

  /// "Import as a note as it is" for an Org file (#220): the file goes
  /// into roam/ under its own name, unchanged, with a new ID at the top if
  /// it has none, as a new node gets. An existing file is never replaced.
  Future<void> _importAsIs(TextFile file) async {
    final (:id, :text) = importText(file.text, newOrgId());
    final result = await _writer.create(file.name, text);
    if (!mounted) return;
    switch (result) {
      case Created():
        final notifier = _graph;
        if (notifier != null) _openNode(notifier, id);
        _tell('Imported ${file.name}.');
      case FileExists():
        _tell('Not imported: roam/${file.name} exists already. Rename the '
            'file, or use "New node".');
      case NoWriteAccess():
        _tell('Not imported: the app may not write to this folder. Choose '
            'it again in "Folder and index" to allow writing.');
      case WrittenNotIndexed(:final message):
        _tell('Imported ${file.name}, but it is not indexed: $message');
      case CreateFailed(:final message):
        _tell('Not imported: $message');
    }
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

  /// Writes [bytes] as the new file [path], relative to roam/, making its
  /// folders first (#112), then indexes the folder, so the node view finds
  /// the file. Never replaces a file.
  Future<CreateResult> _createRoamFile(String path, Uint8List bytes) async {
    final folder = _folder;
    if (folder == null || _roamDir == null) {
      return const CreateFailed('No folder is indexed.');
    }
    if (!folder.canWrite) return const NoWriteAccess();
    final clean = normalizePath(path);
    if (clean.isEmpty || clean == '..' || clean.startsWith('../') ||
        clean.startsWith('/')) {
      return CreateFailed('$path is not inside roam/.');
    }
    final parts = clean.split('/');
    final name = parts.removeLast();
    // The folders, from the chosen folder down, made where missing.
    var inFolder = _roamPrefix.endsWith('/')
        ? _roamPrefix.substring(0, _roamPrefix.length - 1)
        : _roamPrefix;
    var dir = _dirs[inFolder] ?? _roamDir!;
    try {
      for (final part in parts) {
        inFolder = inFolder.isEmpty ? part : '$inFolder/$part';
        dir = _dirs[inFolder] ??=
            await widget.folderAccess.createDirectory(dir, part);
      }
      await widget.folderAccess.createFile(dir, name, bytes);
    } on PlatformException catch (e) {
      return switch (e.code) {
        'exists' => const FileExists(),
        'not_a_dir' => CreateFailed('${e.message ?? e.code}.'),
        _ => CreateFailed(e.message ?? e.code),
      };
    }
    await _rescan();
    return Created(clean);
  }

  /// Opens the note at [path], relative to roam/, in an app chosen in
  /// Android's app chooser (#218); on the desktop in Emacs, at [line]
  /// (#116).
  Future<OpenResult> _openElsewhere(String path, {int line = 1}) async {
    final file = _roamFiles[path];
    if (file == null) return OpenResult.noFile;
    if (isDesktop) {
      final command = ViewSettingsScope.of(context).emacsCommand;
      try {
        await widget.startProcess(command, emacsArguments(file.uri, line));
        return OpenResult.opened;
      } on ProcessException {
        return OpenResult.noApp;
      }
    }
    try {
      return await widget.folderAccess.openElsewhere(file)
          ? OpenResult.opened
          : OpenResult.noApp;
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
    TextDrop.remove(_takeDrop);
    WidgetsBinding.instance.removeObserver(this);
    _stopChecking();
    _graph?.dispose();
    _revision.dispose();
    _problems.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _startChecking();
        _checkSavedFolder();
      case AppLifecycleState.paused ||
            AppLifecycleState.hidden ||
            AppLifecycleState.detached:
        _stopChecking();
      case AppLifecycleState.inactive:
        break;
    }
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
    // While a scan runs, the state to come back to is the settled one.
    final previous = (
      _status == _Status.loading ? _settled : _status,
      _folder,
      _result,
    );
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
      _revision.value++;
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
    final graph = result.graph;
    _problems.value = status == _Status.indexed && graph != null
        ? problemCount(graph, result.unreadable, result.conflicts)
        : 0;
    setState(() {
      _status = status;
      if (status != _Status.loading) _settled = status;
      _folder = folder;
      _result = result;
    });
    _revision.value++;
    // Conflict copies that appear later, for example on resume, are
    // reported wherever the user is, also over the graph (#13): those not
    // seen by the last scan of the folder, also when another one was
    // resolved meanwhile. Those found by the first scan of a folder are
    // shown by the warning icon of the graph (#196).
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
                'Resolve it in Emacs; "Folder and index" lists it.'
            : 'Syncthing made ${fresh.length} new conflict copies in the '
                'folder. Resolve them in Emacs; "Folder and index" lists '
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
    if (graph != null) {
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
      _settled = _Status.failed;
      _error = message;
    });
    _revision.value++;
  }

  /// The controls the graph gets for "Folder and index" (#196).
  late final _controls = FolderControls(
    problems: _problems,
    open: _showFolderSheet,
    newFromClipboard: _newFromClipboard,
    openFiles: _openFiles,
  );

  @override
  Widget build(BuildContext context) {
    // The graph is the home screen once the folder is indexed, and stays
    // while a scan runs over it (#196).
    final notifier = _graph;
    if (notifier != null &&
        (_status == _Status.indexed ||
            (_status == _Status.loading && _settled == _Status.indexed))) {
      final graph = widget.graphScreen(
          notifier, _readNote, _openElsewhere, _writer, _files, _controls);
      if (!isDesktop) return graph;
      return CallbackShortcuts(
        bindings: {pasteShortcut: _newFromClipboard},
        child: Focus(autofocus: true, child: graph),
      );
    }
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
            onPressed: () =>
                AiSettingsScreen.open(context, graph: _graph?.value),
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

  /// Opens the sheet "Folder and index" (#196): what the scan found, and
  /// "Scan again", "Rebuild index" and "Change folder". It follows the
  /// scan, so it shows progress while one runs.
  Future<void> _showFolderSheet() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    _sheetClosing = false;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          builder: (context, controller) => ListenableBuilder(
            listenable: _revision,
            builder: (context, _) => _sheetContent(sheetContext, controller),
          ),
        ),
      );
    } finally {
      _sheetOpen = false;
    }
  }

  Widget _sheetContent(BuildContext sheetContext, ScrollController controller) {
    final graph = _result.graph;
    if (_status == _Status.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_status != _Status.indexed || graph == null) {
      // The folder cannot be shown any more, for example after access was
      // lost: the start page shows why.
      if (!_sheetClosing) {
        _sheetClosing = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (sheetContext.mounted &&
              ModalRoute.of(sheetContext)?.isCurrent == true) {
            Navigator.of(sheetContext).pop();
          }
        });
      }
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            FolderReport(
              graph: graph,
              unreadable: _result.unreadable,
              conflicts: _result.conflicts,
            ),
            Text('Folder: ${_folder?.name}'),
            OutlinedButton(
                onPressed: _rescan, child: const Text('Scan again')),
            TextButton(
              onPressed: _rebuild,
              child: const Text('Rebuild index'),
            ),
            TextButton(
                onPressed: _choose, child: const Text('Change folder')),
            Text(
              'Version ${widget.version}',
              style: Theme.of(sheetContext).textTheme.bodySmall,
            ),
          ],
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
          if (_result.conflicts.isNotEmpty)
            ConflictList(conflicts: _result.conflicts),
          OutlinedButton(onPressed: _rescan, child: const Text('Scan again')),
          chooseButton,
        ]);
      case _Status.indexed:
        // The graph is shown instead; see [build].
        return const SizedBox.shrink();
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

  Widget _column(List<Widget> children) => Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: children,
      );
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
  Future<List<TextHit>> searchText(String query, {int limit = 30}) =>
      _state.widget.graphIndex.searchText(query, limit: limit);

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

/// The choice for several text files (#220).
enum _SeveralFiles { perFile, oneNote }
