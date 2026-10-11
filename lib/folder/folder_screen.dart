import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'folder_access.dart';
import 'org_files.dart';

/// Lets the user choose the org folder and shows how many files of the
/// graph it holds (#3).
class FolderScreen extends StatefulWidget {
  const FolderScreen({
    super.key,
    required this.folderAccess,
    required this.version,
  });

  final FolderAccess folderAccess;
  final String version;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

enum _Status { loading, noFolder, accessLost, noRoam, indexed, failed }

class _FolderScreenState extends State<FolderScreen>
    with WidgetsBindingObserver {
  _Status _status = _Status.loading;
  ChosenFolder? _folder;
  int _fileCount = 0;
  String _error = '';

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
        await _guard(() => _index(saved));
      }
    } on PlatformException {
      // Keep what is shown; the next action reports the error.
    }
  }

  /// On start: index the folder chosen earlier, if there is one.
  Future<void> _start() => _guard(() async {
        final folder = await widget.folderAccess.savedFolder();
        if (folder == null) {
          _show(_Status.noFolder, null, 0);
        } else {
          await _index(folder);
        }
      });

  /// Opens the folder picker. If the user cancels, nothing changes.
  Future<void> _choose() {
    final previous = (_status, _folder, _fileCount);
    return _guard(() async {
      final folder = await widget.folderAccess.pickFolder();
      if (folder == null) {
        _show(previous.$1, previous.$2, previous.$3);
      } else {
        await _index(folder);
      }
    });
  }

  Future<void> _rescan() async {
    final folder = _folder;
    if (folder != null) await _guard(() => _index(folder));
  }

  Future<void> _index(ChosenFolder folder) async {
    // Remember the folder first, so "Try again" works if listing fails.
    _folder = folder;
    if (!folder.hasAccess) {
      _show(_Status.accessLost, folder, 0);
      return;
    }
    final files = selectRoamFiles(
      folder.name,
      await widget.folderAccess.listFiles(folder),
    );
    if (files == null) {
      _show(_Status.noRoam, folder, 0);
    } else {
      _show(_Status.indexed, folder, files.length);
    }
  }

  /// Shows the spinner while [work] runs, and an error if it fails.
  Future<void> _guard(Future<void> Function() work) async {
    if (_status != _Status.loading) {
      setState(() => _status = _Status.loading);
    }
    try {
      await work();
    } on PlatformException catch (e) {
      _fail(e.message ?? e.code);
    } catch (e) {
      _fail('$e');
    }
  }

  void _show(_Status status, ChosenFolder? folder, int count) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _folder = folder;
      _fileCount = count;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
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
          child: Padding(
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
          Text('$_fileCount', style: text.displayMedium),
          Text('files indexed in roam/', style: text.titleMedium),
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
