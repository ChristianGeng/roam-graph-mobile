/// Finding nodes by title, alias and tag (#9), like `org-roam-node-find`.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'roam_graph.dart';

/// A node found by its title, or by one of its aliases.
class SearchHit {
  const SearchHit(this.node, {this.alias});

  final RoamNode node;

  /// The alias that matched, or null when it was the title.
  final String? alias;

  /// The text shown and searched: the alias, or the node's title.
  String get text => alias ?? node.displayTitle;
}

/// The nodes of [graph] whose title or alias contains every word of
/// [query], and that have every tag in [tags].
///
/// As in `org-roam-node-find`:
/// - Each alias is a candidate of its own, as in `org-roam-node-list`, so
///   a node can be found twice, by its title and by an alias.
/// - The newest file comes first (`org-roam-node-default-sort` is
///   `file-mtime`). The sort keeps the order of candidates from files
///   with the same time: the nodes in path order, a title before its
///   aliases.
/// - The words of [query] are separated by spaces and match anywhere, in
///   any order, ignoring case, as Doom Emacs's completion (`orderless`)
///   matches them. An empty query finds every candidate.
///
/// A node without a title is found by its file name, which is what the
/// app shows for it; org-roam's title for it is empty.
List<SearchHit> searchNodes(
  RoamGraph graph,
  String query, {
  Set<String> tags = const {},
}) {
  final words = [
    for (final word in query.toLowerCase().split(RegExp(r'\s+')))
      if (word.isNotEmpty) word,
  ];
  bool matches(String text) {
    final lower = text.toLowerCase();
    return words.every(lower.contains);
  }

  final hits = <SearchHit>[];
  for (final node in graph.nodes.values) {
    if (!tags.every(node.tags.contains)) continue;
    for (final hit in [
      SearchHit(node),
      for (final alias in node.aliases) SearchHit(node, alias: alias),
    ]) {
      if (matches(hit.text)) hits.add(hit);
    }
  }
  int mtime(SearchHit hit) => graph.fileMtimes[hit.node.file] ?? 0;
  final indexed = [for (var i = 0; i < hits.length; i++) (i, hits[i])];
  indexed.sort((a, b) {
    final byTime = mtime(b.$2).compareTo(mtime(a.$2));
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });
  return [for (final (_, hit) in indexed) hit];
}

/// The tags of the nodes of [graph], the most used first, then by name.
List<String> tagsByUse(RoamGraph graph) {
  final count = <String, int>{};
  for (final node in graph.nodes.values) {
    for (final tag in node.tags) {
      count[tag] = (count[tag] ?? 0) + 1;
    }
  }
  return count.keys.toList()
    ..sort((a, b) {
      final byCount = count[b]!.compareTo(count[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
}
