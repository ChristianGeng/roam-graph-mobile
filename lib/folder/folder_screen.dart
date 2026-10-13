import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../graph/build_graph.dart';
import '../graph/roam_graph.dart';
import 'folder_access.dart';
import 'org_files.dart';

/// Lets the user choose the org folder (#3), reads the graph from it (#4)
/// and shows what it found, to compare with org-roam on the laptop.
class FolderScreen extends StatefulWidget {
  const FolderScreen({
    super.key,
    required this.folderAccess,
    required this.version,
    this.graphBuilder = buildGraphInBackground,
  });

  final FolderAccess folderAccess;
  final String version;
  final GraphBuilder graphBuilder;

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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkSavedFolder();
  }

  /// When the app comes back, the saved folder may have changed: a folder
  /// chosen while Android recreated the app, or a permission revoked in the
  /// system settings. Re-index only if it did.
  Future<void> _checkSavedFolder() async {
    if (_status == _Status.loading) return;
    try {
      final saved = await widget.folderAccess.savedFolder();
      if (saved == null || !mounted || _status == _Status.loading) return;
      final current = _folder;
      if (current == null ||
          saved.uri != current.uri ||
          saved.hasAccess != current.hasAccess) {
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

  Future<void> _index(int generation, ChosenFolder folder) async {
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
    final texts = await widget.folderAccess.readTexts(files);
    final sources = <SourceFile>[];
    final unreadable = <String>[];
    for (var i = 0; i < files.length; i++) {
      final path = files[i].path.substring(prefix.length);
      final text = i < texts.length ? texts[i] : null;
      if (text == null) {
        unreadable.add(path);
      } else {
        sources.add((path: path, text: text));
      }
    }
    final graph = await widget.graphBuilder(sources);
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
