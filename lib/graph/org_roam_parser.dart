/// Reads org-roam nodes, tags, aliases, refs and `id:` links from one org
/// file the way org-roam does (#4).
///
/// The rules follow org-roam's `org-roam-db-update-file` and the Org
/// functions it calls (org-roam 2.3, Org 9.6). Each rule is checked against
/// a database built by real org-roam from the sample files in
/// `test/fixtures/roam/`; see `tool/org_roam_parity/`.
///
/// Pure Dart (no Flutter), so `tool/roam_graph_dump.dart` can run it.
library;

import 'dart:convert';

import 'roam_graph.dart';

/// Doom Emacs's default `org-todo-keywords`. They decide where a heading's
/// title starts: `* PROJ Plan` has the title `Plan`. A file's own `#+TODO:`
/// lines replace them for that file, as in Org.
const doomTodoKeywords = [
  'TODO', 'PROJ', 'LOOP', 'STRT', 'WAIT', 'HOLD', 'IDEA', 'DONE', 'KILL', //
  '[ ]', '[-]', '[?]', '[X]', 'OKAY', 'YES', 'NO',
];

/// Link types registered in an Emacs with org-roam loaded. Org recognizes a
/// plain link like `https://…` or `id:…` in text only for a registered
/// type, and org-roam accepts a plain `ROAM_REFS` entry only for one.
const defaultLinkTypes = [
  'eww', 'rmail', 'mhe', 'irc', 'info', 'gnus', 'docview', 'bibtex', //
  'bbdb', 'w3m', 'doi', 'roam', 'attachment', 'id', 'file+sys', //
  'file+emacs', 'shell', 'news', 'mailto', 'https', 'http', 'ftp', 'help', //
  'file', 'elisp',
];

/// Parses one file. [path] is relative to `roam/` and is stored as given.
///
/// A file org-roam fails on, such as one with an unterminated quote in
/// `ROAM_ALIASES`, gives no nodes and links but an [RoamFileData.error]:
/// org-roam skips such a file entirely.
RoamFileData parseRoamFile(
  String path,
  String text, {
  List<String> todoKeywords = doomTodoKeywords,
  List<String> linkTypes = defaultLinkTypes,
}) {
  try {
    return _FileParser(path, text, todoKeywords, linkTypes).parse();
  } on FormatException catch (e) {
    return RoamFileData(path: path, error: e.message);
  }
}

// Line patterns.
final _heading = RegExp(r'^(\*+) (.*)$');
final _comment = RegExp(r'^[ \t]*#(?: |$)');
final _fixedWidth = RegExp(r'^[ \t]*:(?: |$)');
final _propertiesStart = RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
final _propertyLine = RegExp(r'^[ \t]*:(\S+?)(\+)?:(?:[ \t]+(.*?))?[ \t]*$');
final _planning = RegExp(r'^[ \t]*(?:SCHEDULED|DEADLINE|CLOSED):');
// The key is greedy, as in Org: `#+filetags::x:` has the key `filetags::x`.
final _keyword = RegExp(r'^[ \t]*#\+(\S+):[ \t]*(.*?)[ \t]*$');
final _blockBegin = RegExp(r'^[ \t]*#\+begin_(\S+)', caseSensitive: false);
final _blockEnd = RegExp(r'^[ \t]*#\+end_(\S+)[ \t]*$', caseSensitive: false);
final _tableRow = RegExp(r'^[ \t]*\|');
final _nonSpace = RegExp(r'\S');
final _whitespace = RegExp(r'\s+');

/// Blocks whose content Org does not parse, so links in them do not count.
const _hiddenBlocks = {'src', 'example', 'export', 'comment'};

enum _Kind { text, heading, hidden, delimiter, property, keyword }

class _Property {
  _Property(this.key, this.plus, this.value);

  /// Upper case; property keys are case-insensitive.
  final String key;

  /// `:KEY+:`, which adds to the value.
  final bool plus;
  final String value;
}

class _Heading {
  _Heading(this.line, this.level, this.title, this.localTags, this.id,
      this.properties);

  final int line;
  final int level;

  /// Null if the heading has no title; org-roam then skips the node.
  final String? title;
  final List<String> localTags;

  /// The node ID, or null if the heading is not a node.
  final String? id;
  final List<_Property>? properties;
  _Heading? parent;
}

class _FileParser {
  _FileParser(this.path, String text, this.defaultTodo, this.linkTypes)
      : lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'),
        syntax = _LinkSyntax.of(linkTypes);

  final String path;
  final List<String> lines;
  final List<String> defaultTodo;
  final List<String> linkTypes;
  final _LinkSyntax syntax;

  late final List<_Kind> kind = List.filled(lines.length, _Kind.text);
  final headings = <_Heading>[];
  List<_Property>? fileProperties;

  /// For each line, the heading it belongs to (null above the first).
  late final List<_Heading?> _headingOfLine = _computeHeadingOfLine();

  /// The link source of each heading, computed once.
  final _sourceOfHeading = <_Heading, String?>{};

  RoamFileData parse() {
    final headingLines = <int>[
      for (var i = 0; i < lines.length; i++)
        if (_heading.hasMatch(lines[i])) i,
    ];
    for (final i in headingLines) {
      kind[i] = _Kind.heading;
    }
    _markBlocks();
    final startsWithHeading = headingLines.isNotEmpty && headingLines.first == 0;
    if (!startsWithHeading) _readFileDrawer();
    final headingDrawers = <int, List<_Property>>{
      for (final i in headingLines)
        if (_readHeadingDrawer(i) case final drawer?) i: drawer,
    };
    final keywords = _readKeywords();

    // A file's own TODO keywords replace the defaults, as in Org.
    final fileTodo = [
      for (final key in const ['TODO', 'SEQ_TODO', 'TYP_TODO'])
        for (final value in keywords[key] ?? const <String>[])
          for (final word in _splitWhitespace(value))
            if (word != '|') word.replaceFirst(RegExp(r'\(.*\)$'), ''),
    ];
    final headingPattern =
        _headingPattern(fileTodo.isNotEmpty ? fileTodo : defaultTodo);

    // `org-file-tags`: every #+filetags value, split at spaces and colons.
    final fileTags = [
      for (final value in keywords['FILETAGS'] ?? const <String>[])
        for (final word in _splitWhitespace(value))
          for (final tag in word.split(':'))
            if (tag.isNotEmpty) tag,
    ];

    final stack = <_Heading>[];
    for (final i in headingLines) {
      final match = headingPattern.firstMatch(lines[i])!;
      final properties = headingDrawers[i];
      final heading = _Heading(
        i,
        match.group(1)!.length,
        match.group(4),
        [
          for (final tag in (match.group(5) ?? '').split(':'))
            if (tag.isNotEmpty) tag,
        ],
        _nodeId(properties),
        properties,
      );
      while (stack.isNotEmpty && stack.last.level >= heading.level) {
        stack.removeLast();
      }
      heading.parent = stack.isEmpty ? null : stack.last;
      stack.add(heading);
      headings.add(heading);
    }

    final nodes = <RoamNode>[];
    // `org-roam-db-insert-file-node`: only if the file does not start with a
    // heading.
    final fileId = startsWithHeading ? null : _nodeId(fileProperties);
    if (fileId != null) {
      // `org-roam-db--file-title` joins the #+title values. Without one it
      // yields "" (`string-join` of nil), not the file name.
      final title = (keywords['TITLE'] ?? const []).join(' ');
      nodes.add(_node(fileId, 0, _displayFormat(title), 1, fileTags,
          fileProperties!));
    }
    // `org-roam-db-insert-node-data` and `org-roam-db-insert-tags`.
    for (final heading in headings) {
      final id = heading.id;
      final title = heading.title;
      if (id == null || title == null) continue;
      final chain = <_Heading>[];
      for (var p = heading.parent; p != null; p = p.parent) {
        chain.add(p);
      }
      final inherited = [
        ...fileTags,
        for (final p in chain.reversed) ...p.localTags,
      ];
      nodes.add(_node(id, heading.level, _displayFormat(title), heading.line + 1,
          _dedupKeepLast([...inherited, ...heading.localTags]),
          heading.properties!));
    }

    return RoamFileData(path: path, nodes: nodes, links: _links());
  }

  RoamNode _node(String id, int level, String title, int line,
          List<String> tags, List<_Property> properties) =>
      RoamNode(
        id: id,
        file: path,
        level: level,
        title: title,
        line: line,
        tags: tags,
        aliases: [
          if (_propertyValue(properties, 'ROAM_ALIASES') case final value?)
            ...splitStringAndUnquote(value),
        ],
        refs: [
          if (_propertyValue(properties, 'ROAM_REFS') case final value?)
            for (final ref in splitStringAndUnquote(value))
              ...parseRoamRef(ref, linkTypes: linkTypes),
        ],
      );

  /// Marks blocks closed before the next heading. Org does not parse a
  /// block without its end line, and a heading ends any block, even one
  /// inside a block (org-roam then sees a heading there).
  ///
  /// Linear: each line is looked at a fixed number of times.
  void _markBlocks() {
    // Where each block name ends, in line order, and where the next
    // heading after each line is.
    final ends = <String, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      final end = _blockEnd.firstMatch(lines[i]);
      if (end != null) ends.putIfAbsent(end.group(1)!.toLowerCase(), () => []).add(i);
    }
    final nextHeading = List.filled(lines.length + 1, lines.length);
    for (var i = lines.length - 1; i >= 0; i--) {
      nextHeading[i] = kind[i] == _Kind.heading ? i : nextHeading[i + 1];
    }
    final used = <String, int>{};
    var i = 0;
    while (i < lines.length) {
      final match = kind[i] == _Kind.text ? _blockBegin.firstMatch(lines[i]) : null;
      if (match != null) {
        final name = match.group(1)!.toLowerCase();
        // The first end line of this name after line i. Lines are visited
        // in order, so the search resumes where it stopped last time.
        final candidates = ends[name] ?? const <int>[];
        var k = used[name] ?? 0;
        while (k < candidates.length && candidates[k] <= i) {
          k++;
        }
        used[name] = k;
        final j = k < candidates.length ? candidates[k] : lines.length;
        if (j < nextHeading[i + 1]) {
          kind[i] = _Kind.delimiter;
          kind[j] = _Kind.delimiter;
          if (_hiddenBlocks.contains(name)) {
            for (var line = i + 1; line < j; line++) {
              kind[line] = _Kind.hidden;
            }
          }
          i = j + 1;
          continue;
        }
      }
      i++;
    }
  }

  /// The file-level drawer must come first; only comment lines may come
  /// before it, not even a blank line.
  void _readFileDrawer() {
    var first = 0;
    while (first < lines.length &&
        kind[first] == _Kind.text &&
        _comment.hasMatch(lines[first])) {
      first++;
    }
    fileProperties = _drawerAt(first);
  }

  /// A heading's drawer follows the heading line, or its planning line.
  List<_Property>? _readHeadingDrawer(int heading) {
    var j = heading + 1;
    if (j < lines.length && kind[j] == _Kind.text && _planning.hasMatch(lines[j])) {
      j++;
    }
    return _drawerAt(j);
  }

  /// The properties of a drawer starting at [start], or null if there is
  /// none. Marks its lines as property lines.
  List<_Property>? _drawerAt(int start) {
    if (start >= lines.length ||
        kind[start] != _Kind.text ||
        !_propertiesStart.hasMatch(lines[start])) {
      return null;
    }
    final properties = <_Property>[];
    for (var j = start + 1; j < lines.length; j++) {
      if (kind[j] == _Kind.heading) return null;
      if (_drawerEnd.hasMatch(lines[j])) {
        for (var k = start; k <= j; k++) {
          kind[k] = _Kind.property;
        }
        return properties;
      }
      // Org's `org-property-drawer-re`: a drawer holds only property lines.
      // Any other line, even a blank one, and it is no property drawer.
      final match = _propertyLine.firstMatch(lines[j]);
      if (match == null) return null;
      properties.add(_Property(
        match.group(1)!.toUpperCase(),
        match.group(2) != null,
        match.group(3) ?? '',
      ));
    }
    return null;
  }

  /// Keyword values by upper-case key, outside hidden blocks.
  Map<String, List<String>> _readKeywords() {
    final keywords = <String, List<String>>{};
    for (var i = 0; i < lines.length; i++) {
      if (kind[i] != _Kind.text) continue;
      final match = _keyword.firstMatch(lines[i]);
      if (match == null) continue;
      keywords.putIfAbsent(match.group(1)!.toUpperCase(), () => []).add(match.group(2)!);
      kind[i] = _Kind.keyword;
    }
    return keywords;
  }

  /// `org-complex-heading-regexp`: stars, TODO keyword, priority, title,
  /// tags.
  RegExp _headingPattern(List<String> todo) {
    final keywords = [...todo]..sort((a, b) => b.length.compareTo(a.length));
    return RegExp(
      '^(\\*+)'
      '(?: +(${keywords.map(_escape).join('|')}))?'
      r'(?: +(\[#.\]))?'
      r'(?: +(.*?))??'
      r'(?:[ \t]+(:[\p{L}\p{N}_@#%:]+:))?'
      r'[ \t]*$',
      unicode: true,
    );
  }

  List<_Heading?> _computeHeadingOfLine() {
    final result = List<_Heading?>.filled(lines.length, null);
    var next = 0;
    _Heading? current;
    for (var i = 0; i < lines.length; i++) {
      if (next < headings.length && headings[next].line == i) {
        current = headings[next++];
      }
      result[i] = current;
    }
    return result;
  }

  /// `org-roam-id-at-point`: the nearest heading at or above [line] that is
  /// a node; above the first heading, the file node.
  String? _sourceAt(int line) {
    final heading = _headingOfLine[line];
    if (heading == null) return _topSource();
    if (_sourceOfHeading.containsKey(heading)) return _sourceOfHeading[heading];
    final String? source;
    if (heading.id != null) {
      source = heading.id;
    } else if (heading.line == 0) {
      // A heading on the first line is the top: org-roam stops there.
      source = null;
    } else {
      final parent = heading.parent;
      source = parent == null ? _topSource() : _sourceAt(parent.line);
    }
    _sourceOfHeading[heading] = source;
    return source;
  }

  /// At the top of the file, org-roam checks the first line, which may be a
  /// heading itself; otherwise the file node.
  String? _topSource() {
    if (headings.isNotEmpty && headings.first.line == 0) return headings.first.id;
    return _nodeId(fileProperties);
  }

  List<RoamLink> _links() {
    // A heading with an ID but no title is a link source for org-roam, but
    // it stores no node for it, and then no links from it either.
    final untitled = {
      for (final h in headings)
        if (h.id != null && h.title == null) h.id,
    };
    final links = <RoamLink>[];
    for (final piece in _linkablePieces()) {
      for (final found in syntax.findIdLinks(piece.text)) {
        final line = piece.line + _countNewlines(piece.text, found.offset);
        final source = _sourceAt(line);
        if (source == null || untitled.contains(source)) continue;
        links.add(RoamLink(
          source: source,
          dest: found.dest,
          file: path,
          line: line + 1,
        ));
      }
    }
    return links;
  }

  /// The text where org-roam finds links: paragraphs, headings, table rows,
  /// keyword values and property values. Not comments, fixed-width lines,
  /// hidden blocks, `ROAM_REFS` or `#+transclude:`
  /// (`org-roam-db-extra-links-exclude-keys`).
  Iterable<({int line, String text})> _linkablePieces() sync* {
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      switch (kind[i]) {
        case _Kind.hidden || _Kind.delimiter:
          i++;
        case _Kind.property:
          {
            final key = _propertyLine.firstMatch(line)?.group(1)!.toUpperCase();
            if (key != null &&
                key != 'ROAM_REFS' &&
                key != 'PROPERTIES' &&
                key != 'END') {
              yield (line: i, text: line);
            }
            i++;
          }
        case _Kind.keyword:
          {
            final key = _keyword.firstMatch(line)!.group(1)!.toLowerCase();
            if (key != 'transclude') yield (line: i, text: line);
            i++;
          }
        case _Kind.heading:
          yield (line: i, text: line);
          i++;
        case _Kind.text:
          if (_comment.hasMatch(line) ||
              _fixedWidth.hasMatch(line) ||
              line.trim().isEmpty) {
            i++;
          } else if (_tableRow.hasMatch(line)) {
            yield (line: i, text: line);
            i++;
          } else {
            // A paragraph: a link description may wrap onto the next line.
            var j = i;
            while (j + 1 < lines.length && _continuesParagraph(j + 1)) {
              j++;
            }
            yield (line: i, text: lines.sublist(i, j + 1).join('\n'));
            i = j + 1;
          }
      }
    }
  }

  bool _continuesParagraph(int i) {
    final line = lines[i];
    return kind[i] == _Kind.text &&
        line.trim().isNotEmpty &&
        !_comment.hasMatch(line) &&
        !_fixedWidth.hasMatch(line) &&
        !_tableRow.hasMatch(line) &&
        !_blockBegin.hasMatch(line);
  }
}

/// `org-id-get`: an ID with at least one non-space character, on a node
/// without `ROAM_EXCLUDE` (`org-roam-db-node-p`).
String? _nodeId(List<_Property>? properties) {
  if (properties == null) return null;
  final id = _propertyValue(properties, 'ID');
  if (id == null || !_nonSpace.hasMatch(id)) return null;
  if (_propertyValue(properties, 'ROAM_EXCLUDE') != null) return null;
  return id.trim();
}

/// `org-entry-get`: the value of [key], with `KEY+` values appended. The
/// value "nil" means no value.
String? _propertyValue(List<_Property> properties, String key) {
  String? base;
  final more = <String>[];
  var found = false;
  for (final property in properties) {
    if (property.key != key) continue;
    found = true;
    if (property.plus) {
      more.add(property.value);
    } else {
      base ??= property.value;
    }
  }
  if (!found) return null;
  final value = [if (base != null) base, ...more].join(' ');
  return value == 'nil' ? null : value;
}

/// `org-get-tags` keeps the last of repeated tags.
List<String> _dedupKeepLast(List<String> tags) {
  final seen = <String>{};
  final kept = <String>[];
  for (final tag in tags.reversed) {
    if (seen.add(tag)) kept.add(tag);
  }
  return kept.reversed.toList();
}

/// Emacs's `split-string-and-unquote`: splits at whitespace, but
/// `"two words"` is one item. A backslash outside quotes is kept, as in
/// Emacs: `A\ B` gives `A\` and `B`.
///
/// Throws a [FormatException] for an unterminated quote, where Emacs
/// signals an error and org-roam skips the whole file.
List<String> splitStringAndUnquote(String value) {
  final quote = value.indexOf('"');
  if (quote < 0) return _splitWhitespace(value);
  final string = RegExp(r'"((?:[^"\\]|\\[\s\S])*)"').matchAsPrefix(value, quote);
  if (string == null) {
    throw FormatException('Unterminated quote in a property value: $value');
  }
  return [
    ..._splitWhitespace(value.substring(0, quote)),
    string.group(1)!.replaceAllMapped(RegExp(r'\\([\s\S])'), (m) => m.group(1)!),
    ...splitStringAndUnquote(value.substring(string.end)),
  ];
}

/// One `ROAM_REFS` item as org-roam's `org-roam-db-insert-refs` reads it.
/// Empty if org-roam skips it as invalid.
List<RoamRef> parseRoamRef(
  String ref, {
  List<String> linkTypes = defaultLinkTypes,
}) {
  // @key
  if (ref.startsWith('@')) return [RoamRef(ref.substring(1), 'cite')];
  // [cite:@key1;@key2]
  if (ref.startsWith('[cite')) {
    final match = _citation.firstMatch(ref);
    if (match == null) return const [];
    return [
      for (final part in match.group(1)!.split(';'))
        if (_citationKey.firstMatch(part) case final key?)
          RoamRef(key.group(1)!, 'cite'),
    ];
  }
  // A link: the type is the link type, the ref what follows the colon.
  final url = _LinkSyntax.of(linkTypes).firstLinkTarget(ref.replaceAll(' ', '%20'));
  if (url == null) return const [];
  final scheme = _scheme.firstMatch(url);
  if (scheme == null) return [RoamRef(_percentDecode(url), '')];
  return [RoamRef(_percentDecode(scheme.group(2)!), scheme.group(1)!)];
}

final _citation = RegExp(r'^\[cite(?:/[^:\]]*)?:([\s\S]*)\]$');
final _citationKey =
    RegExp(r"@([-.:?!`'/*@+|(){}<>&_^$#%~\p{L}\p{N}]+)", unicode: true);
final _scheme = RegExp(r'^([a-zA-Z][-a-zA-Z0-9+.]*):([\s\S]*)$');

/// `org-link-display-format`: a link becomes its description, or its
/// target if it has none.
String _displayFormat(String text) => text.replaceAllMapped(
      _bracketLink,
      (m) => m.group(2) ?? m.group(1)!,
    );

/// `org-link-decode`: runs of %XX become the UTF-8 text they encode.
String _percentDecode(String text) => text.replaceAllMapped(
      RegExp(r'(?:%[0-9A-Fa-f]{2})+'),
      (m) => utf8.decode(
        [
          for (var i = 0; i < m[0]!.length; i += 3)
            int.parse(m[0]!.substring(i + 1, i + 3), radix: 16),
        ],
        allowMalformed: true,
      ),
    );

List<String> _splitWhitespace(String text) {
  final trimmed = text.trim();
  return trimmed.isEmpty ? const [] : trimmed.split(_whitespace);
}

int _countNewlines(String text, int end) {
  var count = 0;
  for (var i = 0; i < end; i++) {
    if (text.codeUnitAt(i) == 0x0A) count++;
  }
  return count;
}

/// Escapes regular expression syntax characters.
String _escape(String text) =>
    text.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\/]'), (m) => '\\${m[0]}');

final _bracketLink = RegExp(r'\[\[((?:[^\[\]\\]|\\[\s\S])+)\](?:\[([\s\S]+?)\])?\]');
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
// Verbatim =…= and code ~…~ hide links. The marker must be followed by a
// non-space, end with a non-space, and be followed by one of Org's
// post-emphasis characters.
final _verbatim = RegExp(r'''([=~])(\S|\S.*?\S)\1(?=[-\s.,:!?;'")}\\\[]|$)''',
    multiLine: true);
final _inlineSource = RegExp(r'src_[^\s{\[]+(?:\[[^\]\n]*\])?\{[^}\n]*\}');
const _verbatimPre = "-('\"{";
const _punctuation = r'''!"#$%&'()*+,-.:;<=>?@[\]^_`{|}~''';

/// Finds links in text the way Org's object parser does, for the
/// registered link types.
class _LinkSyntax {
  _LinkSyntax._(List<String> types)
      : _angle = RegExp('<(${_alternatives(types)}):([^>\\n]*)>'),
        _plain = RegExp('(${_alternatives(types)}):([^\\[\\]\\s()<>]+)');

  factory _LinkSyntax.of(List<String> types) => _cache[types.join(' ')] ??= _LinkSyntax._(types);

  static final _cache = <String, _LinkSyntax>{};

  final RegExp _angle;
  final RegExp _plain;

  static String _alternatives(List<String> types) {
    final sorted = [...types]..sort((a, b) => b.length.compareTo(a.length));
    return sorted.map(_escape).join('|');
  }

  /// `id:` links in [text], left to right. Other links, verbatim and code
  /// are skipped as a whole, so an `id:` inside them is not a link.
  List<({int offset, String dest})> findIdLinks(String text) {
    final found = <({int offset, String dest})>[];
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == '[' && text.startsWith('[[', i)) {
        final m = _bracketLink.matchAsPrefix(text, i);
        if (m != null) {
          final target = m.group(1)!;
          if (target.startsWith('id:')) {
            found.add((offset: i, dest: _withoutSearchOption(target.substring(3))));
          }
          i = m.end;
          continue;
        }
      }
      if (c == '<') {
        final m = _angle.matchAsPrefix(text, i);
        if (m != null) {
          if (m.group(1) == 'id') {
            found.add((offset: i, dest: _withoutSearchOption(m.group(2)!.trim())));
          }
          i = m.end;
          continue;
        }
      }
      final atWordStart = i == 0 || !_wordChar.hasMatch(text[i - 1]);
      if ((c == '=' || c == '~') &&
          (i == 0 || text[i - 1].trim().isEmpty || _verbatimPre.contains(text[i - 1]))) {
        final m = _verbatim.matchAsPrefix(text, i);
        if (m != null) {
          i = m.end;
          continue;
        }
      }
      if (c == 's' && atWordStart) {
        final m = _inlineSource.matchAsPrefix(text, i);
        if (m != null) {
          i = m.end;
          continue;
        }
      }
      if (atWordStart && _wordChar.hasMatch(c)) {
        final plain = _plainAt(text, i);
        if (plain != null) {
          if (plain.type == 'id') {
            found.add((offset: i, dest: _withoutSearchOption(plain.target)));
          }
          i = plain.end;
          continue;
        }
      }
      i++;
    }
    return found;
  }

  /// The target of the first link in [text], as org-roam's ref parsing
  /// takes it: the path of a bracket link, or the whole plain link.
  String? firstLinkTarget(String text) {
    final bracket = _bracketLink.firstMatch(text);
    if (bracket != null) return bracket.group(1);
    // org-roam stores nothing for an angle link like <https://…>: it hands
    // the whole link, brackets included, to `url-generic-parse-url`.
    if (_angle.hasMatch(text)) return null;
    for (final m in _plain.allMatches(text)) {
      if (m.start > 0 && _wordChar.hasMatch(text[m.start - 1])) continue;
      final plain = _plainAt(text, m.start);
      if (plain != null) return '${plain.type}:${plain.target}';
    }
    return null;
  }

  /// A plain link like `https://…` or `id:…` starting at [start]. It does
  /// not end with punctuation, except `/`.
  ({String type, String target, int end})? _plainAt(String text, int start) {
    final m = _plain.matchAsPrefix(text, start);
    if (m == null) return null;
    var target = m.group(2)!;
    while (target.isNotEmpty &&
        target[target.length - 1] != '/' &&
        _punctuation.contains(target[target.length - 1])) {
      target = target.substring(0, target.length - 1);
    }
    if (target.isEmpty) return null;
    final type = m.group(1)!;
    return (type: type, target: target, end: start + type.length + 1 + target.length);
  }

  /// `id:abc::*Heading` links to `abc`.
  static String _withoutSearchOption(String target) {
    final option = target.indexOf('::');
    return option < 0 ? target : target.substring(0, option);
  }
}
