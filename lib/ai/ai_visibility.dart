/// What an AI may not see (#57): notes with a hidden tag, and inside the
/// notes it may see, headings with a hidden tag and the titles of hidden
/// notes in links.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import '../graph/roam_graph.dart';

/// The tags that hide a note from AI.
class AiVisibility {
  const AiVisibility(this.hiddenTags);

  /// Nothing hidden.
  static const none = AiVisibility({});

  /// The default: notes tagged `private`.
  static const defaultHiddenTags = ['private'];

  final Set<String> hiddenTags;

  /// Whether [node] is hidden: one of its tags is hidden. A node's tags are
  /// those org-roam stores, so a heading node also has the tags of its
  /// file and of the headings above it. Tags are compared as written, as
  /// Org compares them.
  bool hides(RoamNode node) => node.tags.any(hiddenTags.contains);

  /// [graph] without the hidden nodes and the links from and to them.
  RoamGraph visibleGraph(RoamGraph graph) =>
      hiddenTags.isEmpty ? graph : graph.withoutNodes(hides);

  /// The IDs of [graph]'s hidden nodes.
  Set<String> hiddenIds(RoamGraph graph) => {
    for (final node in graph.nodes.values)
      if (hides(node)) node.id,
  };

  /// [text], Org text of a visible note, as an AI may see it:
  /// - Each heading with a hidden tag of its own is left out, with its
  ///   subtree, also when it is no node. A line that starts with stars and
  ///   a space is a heading, also inside a block, as Org and the node view
  ///   read it.
  /// - A link to a node in [hiddenIds] keeps its target, but its
  ///   description becomes `(hidden)`, so the note's title does not show.
  ///
  /// `#+filetags` are not checked here: a file with a hidden file tag is a
  /// hidden node, whose text is never given to an AI.
  String filterText(String text, Set<String> hiddenIds) {
    if (hiddenTags.isEmpty) return text;
    final out = <String>[];
    int? skipLevel;
    for (final line in text.split('\n')) {
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        final level = heading[1]!.length;
        if (skipLevel != null && level <= skipLevel) skipLevel = null;
        if (skipLevel == null && _tagsOf(line).any(hiddenTags.contains)) {
          skipLevel = level;
          out.add('${heading[1]} (hidden)');
          continue;
        }
      }
      if (skipLevel == null) out.add(line);
    }
    final filtered = out.join('\n');
    if (hiddenIds.isEmpty) return filtered;
    return filtered.replaceAllMapped(_idLink, (match) {
      final id = match[1]!.split('::').first.trim();
      return hiddenIds.contains(id)
          ? '[[id:${match[1]}][(hidden)]]'
          : match[0]!;
    });
  }
}

/// An Org heading: stars at the start of the line, then a space or a tab.
final _heading = RegExp(r'^(\*+)[ \t]');

/// The tags at the end of a heading line, as Org's `org-tag-group-re`
/// reads them: `:a:b:` after a space or a tab.
final _headingTags = RegExp(
  r'[ \t](:[\p{L}\p{N}_@#%:]+:)[ \t]*$',
  unicode: true,
);

List<String> _tagsOf(String heading) {
  final match = _headingTags.firstMatch(heading);
  if (match == null) return const [];
  return [
    for (final tag in match[1]!.split(':'))
      if (tag.isNotEmpty) tag,
  ];
}

/// An `id:` bracket link, `[[id:X]]` or `[[id:X][description]]`; group 1
/// is the part after `id:`.
final _idLink = RegExp(r'\[\[id:([^\]\[]+)\](?:\[([\s\S]+?)\])?\]');
