/// A node's title, tags and aliases, read from and written to its head
/// (#97). Only these change; the `:ID:` and every other property stay
/// (decision 10, rule 5, as widened by decision 63).
library;

import '../graph/org_roam_parser.dart';
import '../graph/roam_graph.dart';
import 'node_text.dart';

/// What can be edited of a node's head.
class NodeMeta {
  const NodeMeta({
    required this.title,
    this.tags = const [],
    this.aliases = const [],
  });

  final String title;

  /// The node's own tags: a file's `#+filetags:`, a heading's tags.
  final List<String> tags;

  /// `:ROAM_ALIASES:`.
  final List<String> aliases;
}

final _titleLine = RegExp(r'^[ \t]*#\+title:[ \t]*(.*?)[ \t]*$',
    caseSensitive: false);
final _filetagsLine = RegExp(r'^[ \t]*#\+filetags:[ \t]*(.*?)[ \t]*$',
    caseSensitive: false);
final _aliasesLine = RegExp(r'^[ \t]*:ROAM_ALIASES:(?:[ \t]+(.*?))?[ \t]*$',
    caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
final _drawerStart =
    RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);

/// A tag as Org allows it: letters, digits and `_@#%`.
final validTag = RegExp(r'^[\p{L}\p{N}_@#%]+$', unicode: true);

/// The heading line as Org's `org-complex-heading-regexp` reads it:
/// stars, TODO keyword, priority, title, tags.
RegExp _heading(List<String> todo) {
  final keywords = [...todo]..sort((a, b) => b.length.compareTo(a.length));
  String escape(String s) => RegExp.escape(s);
  return RegExp(
    '^(\\*+)'
    '(?: +(${keywords.map(escape).join('|')}))?'
    r'(?: +(\[#.\]))?'
    r'(?: +(.*?))??'
    r'(?:[ \t]+(:[\p{L}\p{N}_@#%:]+:))?'
    r'[ \t]*$',
    unicode: true,
  );
}

List<String> _tagsOf(String? value) => [
      for (final t in (value ?? '').split(':'))
        if (t.trim().isNotEmpty) t.trim(),
    ];

/// The file's own `#+TODO:` keywords, or Doom's, as the index reads them.
List<String> _todoOf(List<String> lines) {
  final own = <String>[];
  final todo = RegExp(r'^[ \t]*#\+(?:TODO|SEQ_TODO|TYP_TODO):[ \t]*(.*)$',
      caseSensitive: false);
  for (final line in lines) {
    final m = todo.firstMatch(line);
    if (m == null) continue;
    for (final word in m.group(1)!.split(RegExp(r'\s+'))) {
      final w = word.replaceFirst(RegExp(r'\(.*\)$'), '');
      if (w.isNotEmpty && w != '|') own.add(w);
    }
  }
  return own.isEmpty ? doomTodoKeywords : own;
}

/// `combine-and-quote-strings`, as `org-roam-alias-add` writes aliases:
/// an alias with a space, a quote or a backslash is quoted, and quotes and
/// backslashes in it get a backslash.
String quoteAliases(List<String> aliases) => [
      for (final a in aliases)
        RegExp(r'[\\" ]').hasMatch(a)
            ? '"${a.replaceAllMapped(RegExp(r'[\\"]'), (m) => '\\${m[0]}')}"'
            : a,
    ].join(' ');

/// The line of the node's drawer, and the lines of its head.
({NodeLines lines, int? drawerStart, int? drawerEnd}) _head(
    String text, RoamNode node) {
  final lines = NodeLines.find(text, node)!;
  int? start, end;
  for (var i = lines.start; i < lines.bodyStart; i++) {
    if (start == null && _drawerStart.hasMatch(lines.lines[i])) start = i;
    if (start != null && end == null && i > start &&
        _drawerEnd.hasMatch(lines.lines[i])) {
      end = i;
    }
  }
  return (lines: lines, drawerStart: start, drawerEnd: end);
}

/// The title, own tags and aliases of [node] in [text]; null if the node
/// is no longer there.
NodeMeta? readMeta(String text, RoamNode node) {
  if (NodeLines.find(text, node) == null) return null;
  final (:lines, :drawerStart, :drawerEnd) = _head(text, node);
  final head = lines.lines.sublist(lines.start, lines.bodyStart);
  var aliases = <String>[];
  if (drawerStart != null && drawerEnd != null) {
    for (var i = drawerStart + 1; i < drawerEnd; i++) {
      final m = _aliasesLine.firstMatch(lines.lines[i]);
      if (m != null) {
        try {
          aliases = splitStringAndUnquote(m.group(1) ?? '');
        } on FormatException {
          aliases = [];
        }
      }
    }
  }
  if (node.isFile) {
    String? title;
    final tags = <String>[];
    for (final line in head) {
      title ??= _titleLine.firstMatch(line)?.group(1);
      if (_filetagsLine.firstMatch(line) case final m?) {
        tags.addAll(_tagsOf(m.group(1)));
      }
    }
    return NodeMeta(title: title ?? '', tags: tags, aliases: aliases);
  }
  final m = _heading(_todoOf(lines.lines)).firstMatch(lines.lines[lines.start]);
  return NodeMeta(
    title: m?.group(4)?.trim() ?? '',
    tags: _tagsOf(m?.group(5)),
    aliases: aliases,
  );
}

/// Why a title, tags or aliases cannot be written.
class MetaError implements Exception {
  const MetaError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [text] with [node]'s head changed to [meta]; only the title line, the
/// tags and the `:ROAM_ALIASES:` line change. Throws [MetaError] for a
/// title with a line break or tags that Org would not read as tags.
String withMeta(String text, RoamNode node, NodeMeta meta) {
  final title = meta.title.trim();
  // A file without #+title keeps having none, as org-roam allows; a
  // heading needs its text.
  if (title.isEmpty && !node.isFile) {
    throw const MetaError('The title is empty.');
  }
  if (title.contains('\n')) {
    throw const MetaError('The title must be one line.');
  }
  for (final tag in meta.tags) {
    if (!validTag.hasMatch(tag)) {
      throw MetaError('"$tag" is no tag Org reads: only letters, digits '
          'and _@#% are allowed.');
    }
  }
  for (final alias in meta.aliases) {
    if (alias.trim().isEmpty || alias.contains('\n')) {
      throw const MetaError('An alias is empty or has a line break.');
    }
  }
  if (NodeLines.find(text, node) == null) {
    throw const MetaError('The note is no longer in its file with its :ID:.');
  }
  final (:lines, :drawerStart, :drawerEnd) = _head(text, node);
  final out = [...lines.lines];
  final inserts = <int, String>{};
  final removes = <int>{};

  // Aliases: the one drawer line that may change.
  if (drawerStart != null && drawerEnd != null) {
    int? at;
    for (var i = drawerStart + 1; i < drawerEnd; i++) {
      if (_aliasesLine.hasMatch(out[i])) at = i;
    }
    final value = quoteAliases(meta.aliases);
    if (at != null) {
      if (meta.aliases.isEmpty) {
        removes.add(at);
      } else {
        out[at] = ':ROAM_ALIASES: $value';
      }
    } else if (meta.aliases.isNotEmpty) {
      inserts[drawerEnd] = ':ROAM_ALIASES: $value';
    }
  } else if (meta.aliases.isNotEmpty) {
    throw const MetaError('The note has no property drawer for aliases.');
  }

  if (node.isFile) {
    int? titleAt, tagsAt;
    for (var i = lines.start; i < lines.bodyStart; i++) {
      if (titleAt == null && _titleLine.hasMatch(out[i])) titleAt = i;
      if (tagsAt == null && _filetagsLine.hasMatch(out[i])) tagsAt = i;
    }
    final afterDrawer = drawerEnd == null ? 0 : drawerEnd + 1;
    if (titleAt != null) {
      out[titleAt] = '#+title: $title';
    } else if (title.isNotEmpty) {
      inserts[afterDrawer] = '#+title: $title';
    }
    final tagLine = '#+filetags: :${meta.tags.join(':')}:';
    if (tagsAt != null) {
      if (meta.tags.isEmpty) {
        removes.add(tagsAt);
      } else {
        out[tagsAt] = tagLine;
      }
    } else if (meta.tags.isNotEmpty) {
      final at = (titleAt ?? afterDrawer - 1) + 1;
      // After the title line; with a new title line, after that one.
      inserts[at] = inserts.containsKey(at)
          ? '${inserts[at]}\n$tagLine'
          : tagLine;
    }
  } else {
    final heading = out[lines.start];
    final m = _heading(_todoOf(lines.lines)).firstMatch(heading);
    if (m == null) throw const MetaError('The heading line is not readable.');
    out[lines.start] = [
      m.group(1)!,
      if (m.group(2) case final todo?) todo,
      if (m.group(3) case final priority?) priority,
      title,
      if (meta.tags.isNotEmpty) ':${meta.tags.join(':')}:',
    ].join(' ');
  }

  final result = <String>[];
  for (var i = 0; i <= out.length; i++) {
    if (inserts[i] case final line?) result.addAll(line.split('\n'));
    if (i < out.length && !removes.contains(i)) result.add(out[i]);
  }
  return result.join(lines.newline);
}
