/// The org-roam graph built from the org files (#4), with what org-roam's
/// database stores about it (#5).
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
    this.pos = 1,
    this.todo,
    this.priority,
    this.scheduled,
    this.deadline,
    this.olp = const [],
    this.properties = 'nil',
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

  /// org-roam's `pos`: the node's character position in the file, from 1.
  final int pos;

  /// The TODO keyword, if any.
  final String? todo;

  /// The priority cookie's character code (`[#A]` is 65), if any.
  final int? priority;

  /// SCHEDULED and DEADLINE as `2026-03-01T10:30:00`, if any.
  final String? scheduled;
  final String? deadline;

  /// Titles of the headings above a heading node (org-roam's `olp`).
  final List<String> olp;

  /// Org's property list of the node, printed as Emacs Lisp (org-roam's
  /// `properties` column).
  final String properties;

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

/// A link from the node [source]. The graph's edges are the links of type
/// `id`; org-roam's `links` table holds every type.
class RoamLink {
  const RoamLink({
    required this.source,
    required this.dest,
    required this.file,
    required this.line,
    this.type = 'id',
    this.pos = 0,
    this.outline = const [],
    this.searchOption,
  });

  /// ID of the node that contains the link.
  final String source;

  /// The link's path: for an `id` link the linked ID, which may not exist
  /// (see [RoamGraph.danglingLinks]); for `https://x` it is `//x`.
  final String dest;

  /// File that contains the link, relative to `roam/`.
  final String file;

  /// Line of the link, starting at 1; 0 when read back from the database.
  final int line;

  /// The link type: `id`, `https`, `file`, `fuzzy`, ...
  final String type;

  /// org-roam's `pos`: the link's character position, from 1.
  final int pos;

  /// Titles of the headings around the link, innermost last.
  final List<String> outline;

  /// The part after `::`, kept for every type but `file`.
  final String? searchOption;
}

/// An org-cite reference like `[cite:@key]` in the text (org-roam's
/// `citations` table).
class RoamCitation {
  const RoamCitation({
    required this.nodeId,
    required this.key,
    required this.pos,
    this.outline = const [],
  });

  final String nodeId;
  final String key;
  final int pos;
  final List<String> outline;
}

/// What the parser found in one file.
class RoamFileData {
  const RoamFileData({
    required this.path,
    this.nodes = const [],
    this.links = const [],
    this.citations = const [],
    this.title = '',
    this.error,
    this.mtime = 0,
  });

  /// Path relative to `roam/`.
  final String path;
  final List<RoamNode> nodes;

  /// When the file was last modified, in milliseconds since 1970; 0 when
  /// unknown.
  final int mtime;

  /// Links of every type; the graph uses those of type `id`.
  final List<RoamLink> links;
  final List<RoamCitation> citations;

  /// The file's title, as org-roam's `files` table stores it.
  final String title;

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
    required this.fileMtimes,
  });

  /// Builds the graph from parsed files.
  ///
  /// An ID used by more than one node keeps the first one, in path order,
  /// and is reported in [duplicateIds]. org-roam also keeps only one of
  /// them, but which one depends on the order it reads the files.
  ///
  /// [duplicateIds] adds IDs found twice elsewhere, such as while storing
  /// the files in a database, which keeps only one node per ID.
  factory RoamGraph.fromFiles(
    Iterable<RoamFileData> files, {
    Map<String, List<String>> duplicateIds = const {},
  }) {
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
      links.addAll(file.links.where((link) => link.type == 'id'));
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
        ...duplicateIds,
      },
      allNodes: allNodes,
      fileMtimes: {for (final file in sorted) file.path: file.mtime},
      failedFiles: {
        for (final file in all) file.path: ?file.error,
      },
    );
  }

  /// Paths of the parsed files, relative to `roam/`. Without [failedFiles],
  /// which org-roam does not store either.
  final List<String> files;

  /// Files org-roam would skip, with the reason.
  final Map<String, String> failedFiles;

  /// When each file of [files] was last modified, in milliseconds since
  /// 1970; 0 when unknown.
  final Map<String, int> fileMtimes;

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

  /// This graph without the nodes [hide] chooses, and without the links
  /// from and to them (#57). Links to IDs that are no node stay. Files
  /// stay, so paths and modification times are unchanged.
  RoamGraph withoutNodes(bool Function(RoamNode node) hide) {
    final hidden = {
      for (final node in allNodes)
        if (hide(node)) node.id,
    };
    if (hidden.isEmpty) return this;
    bool keep(RoamLink link) =>
        !hidden.contains(link.source) && !hidden.contains(link.dest);
    return RoamGraph._(
      files: files,
      nodes: {
        for (final MapEntry(:key, :value) in nodes.entries)
          if (!hidden.contains(key)) key: value,
      },
      links: links.where(keep).toList(),
      danglingLinks: danglingLinks.where(keep).toList(),
      duplicateIds: {
        for (final MapEntry(:key, :value) in duplicateIds.entries)
          if (!hidden.contains(key)) key: value,
      },
      allNodes: [
        for (final node in allNodes)
          if (!hidden.contains(node.id)) node,
      ],
      failedFiles: failedFiles,
      fileMtimes: fileMtimes,
    );
  }

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
        'link_locations': [
          for (final l in links) [l.source, l.dest, l.file, l.line],
        ],
        'dangling_links': [
          for (final l in danglingLinks) [l.source, l.dest, l.file, l.line],
        ],
        'duplicate_ids': duplicateIds,
        'failed_files': failedFiles,
      };
}
