import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../graph/graph_index.dart';
import '../graph/roam_graph.dart';
import '../graph_view/graph_screen.dart';
import '../node_view/node_screen.dart';
import 'folder_access.dart';
import 'org_files.dart';

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
  });

  final FolderAccess folderAccess;
  final String version;
  final GraphIndex graphIndex;

  /// Builds the graph view; tests replace it. The graph it gets follows
  /// the index, also while the graph view is open; [NoteReader] reads the
  /// notes of the chosen folder.
  final Widget Function(ValueListenable<RoamGraph> graph, NoteReader readNote)
      graphScreen;

  static Widget defaultGraphScreen(
    ValueListenable<RoamGraph> graph,
    NoteReader readNote,
  ) =>
      GraphScreen(graph: graph, readNote: readNote);

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

enum _Status { loading, noFolder, accessLost, noRoam, indexed, failed }

/// What the screen shows after reading a folder: the graph, and the files
/// that could not be read.
typedef _Result = ({RoamGraph? graph, List<String> unreadable});

const _noResult = (graph: null, unreadable: <String>[]);

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
    _start();
  }

  /// The latest graph, for an open graph view; null before the first.
  ValueNotifier<RoamGraph>? _graph;

  /// The files of the latest graph, by path relative to roam/.
  Map<String, FolderFile> _roamFiles = {};

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
    if (generation == _generation) _folder = folder;
    if (!folder.hasAccess) {
      _show(generation, _Status.accessLost, folder, _noResult);
      return;
    }
    final entries = await widget.folderAccess.listFiles(folder);
    final files = selectRoamFiles(folder.name, entries);
    if (files == null) {
      _show(generation, _Status.noRoam, folder, _noResult);
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
    final toRead =
        replace ? listing.keys.toList() : await index.filesToRead(listing);
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
    final unreadable = [
      for (final MapEntry(key: path, value: content) in contents.entries)
        if (content == null) path,
    ];
    if (generation == _generation) _roamFiles = byPath;
    _show(generation, _Status.indexed, folder,
        (graph: graph, unreadable: unreadable));
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
      appBar: AppBar(title: const Text('Roam Graph')),
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
          OutlinedButton(onPressed: _rescan, child: const Text('Scan again')),
          chooseButton,
        ]);
      case _Status.indexed:
        return _column([
          Text('Graph in roam/', style: text.titleLarge),
          if ((_result.graph, _graph) case (final graph?, final notifier?)
              when graph.nodes.isNotEmpty)
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) =>
                      widget.graphScreen(notifier, _readNote),
                ),
              ),
              icon: const Icon(Icons.hub_outlined),
              label: const Text('Show graph'),
            ),
          if (_result.graph case final graph?)
            _GraphSummary(graph: graph, unreadable: _result.unreadable),
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

  Widget _column(List<Widget> children) => Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: children,
      );
}

/// The counts to compare with org-roam's database on the laptop.
class _GraphSummary extends StatelessWidget {
  const _GraphSummary({required this.graph, required this.unreadable});

  final RoamGraph graph;
  final List<String> unreadable;

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
  const _FileList({required this.title, required this.files});

  static const _shown = 10;

  final String title;
  final List<String> files;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        for (final file in files.take(_shown)) Text(file),
        if (files.length > _shown) Text('and ${files.length - _shown} more'),
      ],
    );
  }
}
