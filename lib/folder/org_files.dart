/// Which files in the chosen folder belong to the graph (#3).
///
/// The rules live here, apart from the Android folder access, so they can be
/// unit-tested.
library;

/// A file or directory below the chosen folder, as the folder access lists
/// it.
class FolderFile {
  const FolderFile({
    required this.path,
    required this.uri,
    this.isDirectory = false,
    this.modified = 0,
    this.size = 0,
  });

  /// Path relative to the chosen folder, with `/` between parts.
  final String path;

  /// Android content URI to read the file.
  final String uri;

  /// True for a directory.
  final bool isDirectory;

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

/// The path prefix of `roam/` inside the chosen folder, or null if the
/// chosen folder is neither.
///
/// - The chosen folder is `roam/` itself (its name is `roam`): no prefix,
///   even if it contains another directory named `roam`.
/// - It contains a `roam` directory: the org root, so `roam/`. This holds
///   even when `roam/` is empty.
/// - Neither: null. Its notes are not the graph, so nothing is counted;
///   for example the org root before Syncthing has created `roam/`.
String? roamPrefix(String folderName, Iterable<FolderFile> entries) {
  if (folderName == roamDirectory) return '';
  final hasRoam = entries.any((e) => e.isDirectory && e.path == roamDirectory);
  return hasRoam ? '$roamDirectory/' : null;
}

/// The files of the graph: the `.org` files in `roam/`, recursively.
///
/// [folderName] is the name of the chosen folder, which can be the org root
/// (containing `roam/`) or `roam/` itself; see [roamPrefix]. Null if it is
/// neither. Paths in the result stay relative to the chosen folder.
List<FolderFile>? selectRoamFiles(
  String folderName,
  Iterable<FolderFile> entries,
) {
  final all = entries.toList();
  final prefix = roamPrefix(folderName, all);
  if (prefix == null) return null;
  return [
    for (final entry in all)
      if (!entry.isDirectory &&
          entry.path.startsWith(prefix) &&
          isRoamFile(entry.path.substring(prefix.length)))
        entry,
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
