/// Which files in the chosen folder belong to the graph (#3).
///
/// The rules live here, apart from the Android folder access, so they can be
/// unit-tested.
library;

/// A file below the chosen folder, as the folder access lists it.
class FolderFile {
  const FolderFile({
    required this.path,
    required this.uri,
    this.modified = 0,
    this.size = 0,
  });

  /// Path relative to the chosen folder, with `/` between parts.
  final String path;

  /// Android content URI to read the file.
  final String uri;

  /// Last change, in milliseconds since the epoch (0 if unknown).
  final int modified;

  /// Size in bytes (0 if unknown).
  final int size;
}

/// Directories the folder access does not enter at all: Syncthing's own
/// marker and version folders.
const skippedDirectories = {'.stfolder', '.stversions'};

/// The folder that org-roam indexes (`org-roam-directory`).
const roamDirectory = 'roam';

/// The files of the graph: the `.org` files in `roam/`, recursively.
///
/// The chosen folder can be the org root (which contains `roam/`) or
/// `roam/` itself. Paths in the result stay relative to the chosen folder.
List<FolderFile> selectRoamFiles(Iterable<FolderFile> files) {
  final all = files.toList();
  final prefix = all.any((f) => f.path.startsWith('$roamDirectory/'))
      ? '$roamDirectory/'
      : '';
  return [
    for (final file in all)
      if (file.path.startsWith(prefix) &&
          isRoamFile(file.path.substring(prefix.length)))
        file,
  ];
}

/// Whether [path], relative to `roam/`, is a file org-roam would index.
///
/// Skips Syncthing's files (`.stfolder`, `.stversions`,
/// `*.sync-conflict-*`) and editor leftovers (`*~`, `.#*`, `#*#`).
bool isRoamFile(String path) {
  final parts = path.split('/');
  if (parts.any(skippedDirectories.contains)) return false;
  final name = parts.last;
  if (name.contains('.sync-conflict-')) return false;
  if (name.endsWith('~')) return false;
  if (name.startsWith('.#')) return false;
  if (name.startsWith('#') && name.endsWith('#')) return false;
  return name.endsWith('.org');
}
