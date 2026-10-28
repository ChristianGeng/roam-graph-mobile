import 'package:material_ui/material_ui.dart';

import '../graph/roam_graph.dart';

/// What a scan found, to compare with org-roam on the laptop and to find
/// the files with a problem (#196): the counts and the lists of files
/// org-roam skips, files that could not be read and conflict copies.
/// Shown in the sheet "Folder and index" of the graph.
class FolderReport extends StatelessWidget {
  const FolderReport({
    super.key,
    required this.graph,
    required this.unreadable,
    required this.conflicts,
  });

  final RoamGraph graph;

  /// Files that could not be read, by path relative to roam/.
  final List<String> unreadable;

  /// The Syncthing conflict copies in the folder (#13).
  final List<String> conflicts;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        GraphSummary(
          graph: graph,
          unreadable: unreadable,
          conflicts: conflicts.length,
        ),
        if (graph.failedFiles.isNotEmpty)
          FileList(
            title: 'Files org-roam skips',
            files: [
              for (final entry in graph.failedFiles.entries)
                '${entry.key}: ${entry.value}',
            ],
          ),
        if (unreadable.isNotEmpty)
          FileList(title: 'Unreadable files', files: unreadable),
        if (conflicts.isNotEmpty) ConflictList(conflicts: conflicts),
      ],
    );
  }
}

/// The number of problems a scan found, shown by the warning icon of the
/// graph (#196): files org-roam skips, unreadable files and conflict
/// copies.
int problemCount(
  RoamGraph graph,
  List<String> unreadable,
  List<String> conflicts,
) =>
    graph.failedFiles.length + unreadable.length + conflicts.length;

/// The counts to compare with org-roam's database on the laptop.
class GraphSummary extends StatelessWidget {
  const GraphSummary({
    super.key,
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
class FileList extends StatelessWidget {
  const FileList({
    super.key,
    required this.title,
    required this.files,
    this.shown = 10,
  });

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

/// Every conflict copy, so each can be found and resolved (#13).
class ConflictList extends StatelessWidget {
  const ConflictList({super.key, required this.conflicts});

  final List<String> conflicts;

  @override
  Widget build(BuildContext context) => FileList(
        title: 'Syncthing conflict copies: resolve them in Emacs',
        files: conflicts,
        shown: null,
      );
}
