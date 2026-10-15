/// The backlinks of a node (#8), as org-roam's buffer lists them.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'roam_graph.dart';

/// One `id:` link to a node, from the node [source].
class Backlink {
  const Backlink(this.source, this.link);

  final RoamNode source;
  final RoamLink link;

  /// Where in [source] the link is, as org-roam shows it after the title:
  /// the titles of the headings around it, joined by ` > `, or `Top`.
  String get outline => link.outline.isEmpty
      ? 'Top'
      : link.outline.map(linkDisplayFormat).join(' > ');
}

/// The backlinks of the node [id], as `org-roam-backlinks-section` lists
/// them by default: one for each `id:` link to it, not one for each node
/// (`:unique nil`), sorted by the title of the linking node. The sort keeps
/// the order of links with the same title, as Emacs's `sort` does.
List<Backlink> backlinksOf(RoamGraph graph, String id) {
  final found = [
    for (final link in graph.links)
      if (link.dest == id)
        if (graph.nodes[link.source] case final source?) Backlink(source, link),
  ];
  final indexed = [for (var i = 0; i < found.length; i++) (i, found[i])];
  indexed.sort((a, b) {
    final byTitle = a.$2.source.title.compareTo(b.$2.source.title);
    return byTitle != 0 ? byTitle : a.$1.compareTo(b.$1);
  });
  return [for (final (_, backlink) in indexed) backlink];
}

/// [text] with each link `[[target][description]]` replaced by its
/// description, and `[[target]]` by its target, as Emacs's
/// `org-link-display-format` does. The pattern is Org's
/// `org-link-bracket-re`: a description is not empty and may hold
/// brackets, and escapes stay as they are.
String linkDisplayFormat(String text) => text.replaceAllMapped(
      _bracketLink,
      (match) => match[2] ?? match[1]!,
    );

final _bracketLink = RegExp(
  r'\[\[((?:[^\]\[\\]|\\(?:\\\\)*[\]\[]|\\+[^\]\[])+)\]'
  r'(?:\[([\s\S]+?)\])?\]',
);
