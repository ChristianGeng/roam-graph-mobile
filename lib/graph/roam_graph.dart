/// The org-roam graph built from the org files (#4).
///
/// Pure Dart (no Flutter), so `tool/roam_graph_dump.dart` can run it on the
/// laptop. The parser that fills it is `org_roam_parser.dart`.
library;

/// A node: a file or a heading with an `:ID:` property, as org-roam stores
/// it in its `nodes` table.
class RoamNode {
  const RoamNode({
    required this.id,
    required this.file,
    required this.level,
    required this.title,
    required this.line,
    this.tags = const [],
    this.aliases = const [],
    this.refs = const [],
  });

  /// The `:ID:` property.
  final String id;

  /// Path of the file, relative to `roam/`.
  final String file;

  /// 0 for a file node, the heading level otherwise.
  final int level;

  /// The title as org-roam stores it. Empty for a file without `#+title`,
  /// because org-roam stores an empty title there; see [displayTitle].
  final String title;

  /// Line of the node in its file, starting at 1.
  final int line;

  /// `#+filetags`, plus inherited and own heading tags for heading nodes.
  final List<String> tags;

  /// `ROAM_ALIASES`.
  final List<String> aliases;

  /// `ROAM_REFS`.
  final List<RoamRef> refs;

  bool get isFile => level == 0;

  /// The title to show: [title], or the file name without `.org` when the
  /// title is empty.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final name = file.split('/').last;
    return name.endsWith('.org') ? name.substring(0, name.length - 4) : name;
  }
}

/// A `ROAM_REFS` entry, as org-roam stores it in its `refs` table: for
/// `https://example.com` the ref is `//example.com` and the type `https`;
/// for `@key` the ref is `key` and the type `cite`.
class RoamRef {
  const RoamRef(this.ref, this.type);

  final String ref;
  final String type;
}

/// An `id:` link from the node [source] to the ID [dest].
class RoamLink {
  const RoamLink({
    required this.source,
    required this.dest,
    required this.file,
    required this.line,
  });

  /// ID of the node that contains the link.
  final String source;

  /// The linked ID. It may not exist; see [RoamGraph.danglingLinks].
  final String dest;

  /// File that contains the link, relative to `roam/`.
  final String file;

  /// Line of the link, starting at 1.
  final int line;
}

/// What the parser found in one file.
class RoamFileData {
  const RoamFileData({
    required this.path,
    this.nodes = const [],
    this.links = const [],
    this.error,
  });

  /// Path relative to `roam/`.
  final String path;
  final List<RoamNode> nodes;
  final List<RoamLink> links;

  /// Why org-roam would skip this file, or null. A skipped file has no
  /// nodes and links.
  final String? error;
}

/// The whole graph.
class RoamGraph {
  RoamGraph._({
    required this.files,
    required this.nodes,
    required this.links,
    required this.danglingLinks,
    required this.duplicateIds,
    required this.allNodes,
    required this.failedFiles,
  });

  /// Builds the graph from parsed files.
  ///
  /// An ID used by more than one node keeps the first one, in path order,
  /// and is reported in [duplicateIds]. org-roam also keeps only one of
  /// them, but which one depends on the order it reads the files.
  factory RoamGraph.fromFiles(Iterable<RoamFileData> files) {
    final all = files.toList()..sort((a, b) => a.path.compareTo(b.path));
    final sorted = [
      for (final file in all)
        if (file.error == null) file,
    ];
    final nodes = <String, RoamNode>{};
    final idFiles = <String, List<String>>{};
    final allNodes = <RoamNode>[];
    final links = <RoamLink>[];
    for (final file in sorted) {
      for (final node in file.nodes) {
        allNodes.add(node);
        nodes.putIfAbsent(node.id, () => node);
        idFiles.putIfAbsent(node.id, () => []).add(file.path);
      }
      links.addAll(file.links);
    }
    return RoamGraph._(
      files: [for (final file in sorted) file.path],
      nodes: nodes,
      links: links,
      danglingLinks: [
        for (final link in links)
          if (!nodes.containsKey(link.dest)) link,
      ],
      duplicateIds: {
        for (final entry in idFiles.entries)
          if (entry.value.length > 1) entry.key: entry.value,
      },
      allNodes: allNodes,
      failedFiles: {
        for (final file in all)
          if (file.error case final error?) file.path: error,
      },
    );
  }

  /// Paths of the parsed files, relative to `roam/`. Without [failedFiles],
  /// which org-roam does not store either.
  final List<String> files;

  /// Files org-roam would skip, with the reason.
  final Map<String, String> failedFiles;

  /// Nodes by ID.
  final Map<String, RoamNode> nodes;

  /// All `id:` links, including links to IDs that do not exist.
  final List<RoamLink> links;

  /// The links whose [RoamLink.dest] is no node.
  final List<RoamLink> danglingLinks;

  /// IDs used by more than one node, with the files that use them.
  final Map<String, List<String>> duplicateIds;

  /// Every node found, duplicates included. org-roam also stores the tags,
  /// aliases and refs of a duplicate.
  final List<RoamNode> allNodes;

  int get fileNodeCount => nodes.values.where((n) => n.isFile).length;
  int get headingNodeCount => nodes.length - fileNodeCount;

  /// Rows org-roam's `tags` table would have.
  int get tagCount => allNodes.fold(0, (sum, n) => sum + n.tags.length);

  /// Rows org-roam's `aliases` table would have.
  int get aliasCount => allNodes.fold(0, (sum, n) => sum + n.aliases.length);

  /// Rows org-roam's `refs` table would have.
  int get refCount => allNodes.fold(0, (sum, n) => sum + n.refs.length);

  /// The graph in the JSON format of `tool/org_roam_parity.py`, which
  /// compares it with an org-roam database.
  Map<String, Object> toNormalizedJson() => {
        'files': [...files]..sort(),
        'nodes': [
          for (final n in nodes.values) [n.id, n.file, n.level, n.title],
        ],
        'links': [
          for (final l in links) [l.source, l.dest],
        ],
        'tags': [
          for (final n in allNodes)
            for (final t in n.tags) [n.id, t],
        ],
        'aliases': [
          for (final n in allNodes)
            for (final a in n.aliases) [n.id, a],
        ],
        'refs': [
          for (final n in allNodes)
            for (final r in n.refs) [n.id, r.ref, r.type],
        ],
        'dangling_links': [
          for (final l in danglingLinks) [l.source, l.dest, l.file, l.line],
        ],
        'duplicate_ids': duplicateIds,
        'failed_files': failedFiles,
      };
}
