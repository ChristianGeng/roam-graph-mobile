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

  /// [graph] without the hidden nodes and the links from and to them. Of
  /// several nodes with one ID, the graph's own (the first) decides.
  RoamGraph visibleGraph(RoamGraph graph) {
    if (hiddenTags.isEmpty) return graph;
    final hidden = hiddenIds(graph);
    return graph.withoutNodes((node) => hidden.contains(node.id));
  }

  /// The IDs of [graph]'s hidden nodes.
  Set<String> hiddenIds(RoamGraph graph) => {
    for (final node in graph.nodes.values)
      if (hides(node)) node.id,
  };

  /// Whether [fileText], the file of [node] as it is now, hides the node:
  /// the file may have changed since the index was built, for example when
  /// Syncthing brought a new `#+filetags`. Checks the file's `#+filetags`
  /// and, for a heading node, the tags of its heading and the headings
  /// above it, found by its `:ID:`.
  bool hidesInText(RoamNode node, String fileText) {
    if (hiddenTags.isEmpty) return false;
    final lines = _lines(fileText);
    for (final line in lines) {
      if (_fileTags.firstMatch(line) case final match?) {
        if (_tagsIn(match[1]!).any(hiddenTags.contains)) return true;
      }
      if (_heading.hasMatch(line)) break;
    }
    if (node.isFile) return false;
    final idLine = RegExp(
      '^[ \t]*:ID:[ \t]+${RegExp.escape(node.id)}[ \t]*\$',
      caseSensitive: false,
    );
    final at = lines.indexWhere(idLine.hasMatch);
    if (at < 0) return false;
    int? level;
    for (var i = at; i >= 0; i--) {
      final heading = _heading.firstMatch(lines[i]);
      if (heading == null) continue;
      final stars = heading[1]!.length;
      if (level != null && stars >= level) continue;
      level = stars;
      if (_headingTagsOf(lines[i]).any(hiddenTags.contains)) return true;
      if (stars == 1) break;
    }
    return false;
  }

  /// [text], Org text of a visible note, as an AI may see it:
  /// - Line ends become `\n`, as the index reads them.
  /// - Each heading with a hidden tag of its own is replaced by
  ///   `* (hidden)` at its level, without its subtree, also when it is no
  ///   node. A line that starts with stars and a space is a heading, also
  ///   inside a block, as Org and the node view read it.
  /// - A link to a node in [hiddenIds] keeps its ID, but its description
  ///   becomes `(hidden)` and its search option (`::*Title`) is dropped,
  ///   so the note's title does not show.
  ///
  /// `#+filetags` are not checked here; see [hidesInText].
  String filterText(String text, Set<String> hiddenIds) {
    if (hiddenTags.isEmpty) return text;
    return splitHidden(text, hiddenIds).text;
  }

  /// [filterText], with what it left out, so a text the AI rewrote can get
  /// it back ([HiddenParts.restore], #103).
  HiddenParts splitHidden(String text, Set<String> hiddenIds) {
    final out = <String>[];
    final parts = <List<String>>[];
    int? skipLevel;
    for (final line in _lines(text)) {
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        final level = heading[1]!.length;
        if (skipLevel != null && level <= skipLevel) skipLevel = null;
        if (skipLevel == null &&
            hiddenTags.isNotEmpty &&
            _headingTagsOf(line).any(hiddenTags.contains)) {
          skipLevel = level;
          out.add('${heading[1]} (hidden)');
          parts.add([line]);
          continue;
        }
      }
      if (skipLevel == null) {
        out.add(line);
      } else {
        parts.last.add(line);
      }
    }
    final links = <String, String>{};
    final filtered = out.join('\n').replaceAllMapped(_bracketLink, (match) {
      final target = _unescape(match[1]!);
      if (!target.startsWith('id:')) return match[0]!;
      final id = target.substring(3).split('::').first.trim();
      if (!hiddenIds.contains(id)) return match[0]!;
      final shown = '[[id:$id][(hidden)]]';
      links.putIfAbsent(shown, () => match[0]!);
      return shown;
    });
    return HiddenParts._(
        filtered, [for (final p in parts) p.join('\n')], links);
  }
}

/// The IDs of the `id:` links in [text], as Org reads them: escapes undone,
/// a search option after `::` cut off.
Set<String> idLinkTargets(String text) => {
  for (final match in _bracketLink.allMatches(text))
    if (_unescape(match[1]!) case final target when target.startsWith('id:'))
      target.substring(3).split('::').first.trim(),
};

List<String> _lines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

/// An Org heading: stars at the start of the line, then a space, as Org's
/// `org-outline-regexp` and the index's parser read it.
final _heading = RegExp(r'^(\*+) ');

/// The tags at the end of a heading line, as Org's `org-tag-group-re`
/// reads them: `:a:b:` after a space or a tab.
final _headingTags = RegExp(
  r'[ \t](:[\p{L}\p{N}_@#%:]+:)[ \t]*$',
  unicode: true,
);

List<String> _headingTagsOf(String heading) {
  final match = _headingTags.firstMatch(heading);
  return match == null ? const [] : _tagsIn(match[1]!);
}

/// A `#+filetags:` line; group 1 is its value.
final _fileTags = RegExp(r'^[ \t]*#\+filetags:(.*)$', caseSensitive: false);

/// The tags in `:a:b:` or `a b`.
List<String> _tagsIn(String value) => [
  for (final tag in value.split(RegExp(r'[:\s]+')))
    if (tag.isNotEmpty) tag,
];

/// A bracket link as Org's `org-link-bracket-re` reads it, escaped
/// brackets in the target included; group 1 is the target as written.
final _bracketLink = RegExp(
  r'\[\[((?:[^\]\[\\]|\\(?:\\\\)*[\]\[]|\\+[^\]\[])+)\]'
  r'(?:\[([\s\S]+?)\])?\]',
);

/// A link target without Org's escapes (`org-link-unescape`): a backslash
/// before a bracket, or before backslashes that end at a bracket.
String _unescape(String target) => target.replaceAllMapped(
  RegExp(r'(\\+)([\]\[])'),
  (m) => '${'\\' * (m[1]!.length ~/ 2)}${m[2]}',
);

/// A note's text as the AI sees it, and the parts hidden from it (#103).
class HiddenParts {
  HiddenParts._(this.text, this.parts, this.links);

  /// The text with each hidden heading as `* (hidden)`.
  final String text;

  /// The hidden headings with their subtrees, in order.
  final List<String> parts;

  /// Each link as the AI sees it, `[[id:x][(hidden)]]`, and the first link
  /// it stands for.
  final Map<String, String> links;

  static final _placeholder = RegExp(r'^(\*+) \(hidden\)[ \t]*$');

  /// [rewritten], a new version of [text], with the hidden parts back in
  /// place of their `* (hidden)` lines and the hidden links as they were.
  /// Null if the AI dropped, added or moved a placeholder to another
  /// level: then where the hidden parts belong is not known.
  String? restore(String rewritten) {
    final lines = rewritten.replaceAll('\r\n', '\n').split('\n');
    final at = [
      for (final (i, line) in lines.indexed)
        if (_placeholder.hasMatch(line)) i,
    ];
    if (at.length != parts.length) return null;
    for (final (n, i) in at.indexed) {
      final stars = _placeholder.firstMatch(lines[i])![1]!;
      if (!parts[n].startsWith('$stars ')) return null;
      lines[i] = parts[n];
    }
    var result = lines.join('\n');
    for (final MapEntry(key: shown, value: original) in links.entries) {
      result = result.replaceAll(shown, original);
    }
    return result;
  }
}
