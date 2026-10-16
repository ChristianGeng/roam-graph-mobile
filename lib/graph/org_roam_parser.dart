/// Reads one org file the way org-roam does: nodes, titles, tags, aliases,
/// refs and links (#4), and everything else org-roam's database stores
/// about them: positions, TODO keywords, priorities, planning, Org's
/// property lists, outline paths, links of every type and citations (#5).
///
/// The rules follow org-roam's `org-roam-db-update-file` and the Org
/// functions it calls (org-roam 2.3, Org 9.6). Each rule is checked against
/// a database built by real org-roam from the sample files in
/// `test/fixtures/roam/`; see `tool/org_roam_parity/`.
///
/// Pure Dart (no Flutter), so the tools in `tool/` can run it.
library;

import 'dart:convert';

import 'elisp.dart';
import 'roam_graph.dart';

/// Doom Emacs's default `org-todo-keywords`. They decide where a heading's
/// title starts: `* PROJ Plan` has the title `Plan`. A file's own `#+TODO:`
/// lines replace them for that file, as in Org.
const doomTodoKeywords = [
  'TODO', 'PROJ', 'LOOP', 'STRT', 'WAIT', 'HOLD', 'IDEA', 'DONE', 'KILL', //
  '[ ]', '[-]', '[?]', '[X]', 'OKAY', 'YES', 'NO',
];

/// Link types registered in a plain Emacs with org-roam loaded, as the
/// sample files' org-roam database was built (`tool/org_roam_parity/`).
/// Org recognizes a plain link like `https://…` or `id:…` in text only for
/// a registered type, and org-roam accepts a plain `ROAM_REFS` entry only
/// for one.
const plainOrgRoamLinkTypes = [
  'eww', 'rmail', 'mhe', 'irc', 'info', 'gnus', 'docview', 'bibtex', //
  'bbdb', 'w3m', 'doi', 'roam', 'attachment', 'id', 'file+sys', //
  'file+emacs', 'shell', 'news', 'mailto', 'https', 'http', 'ftp', 'help', //
  'file', 'elisp',
];

/// Link types registered in my Doom Emacs (`org-link-parameters`, read on
/// 2026-10-16), which the app uses: Doom adds `org`, `doom`, `kbd` and
/// others, and leaves out `eww`, `info`, `doi` and others. So
/// `#+filetags: :org:setup:` holds a plain `org:` link in org-roam on the
/// laptop. If my Emacs changes, `tool/org_roam_parity.py check-db` shows
/// the difference (decision 21).
const myEmacsLinkTypes = [
  'treemacs', 'orgit-rev', 'orgit-log', 'orgit', 'bibtex', 'download', //
  'pdf', 'elfeed', 'orgit-topic', 'roam', 'id', 'img', 'doom-changelog', //
  'doom-user', 'doom-ref', 'doom-executable', 'doom-module', //
  'doom-package', 'cmd', 'face', 'fn', 'var', 'kbd', 'doom-modules', //
  'doom-docs', 'doom', 'org', 'attachment', 'file+sys', 'file+emacs', //
  'shell', 'news', 'mailto', 'https', 'http', 'ftp', 'help', 'file', //
  'elisp',
];

/// The link types the parser uses unless told otherwise: my Emacs's.
const defaultLinkTypes = myEmacsLinkTypes;

/// Parses one file. [path] is relative to `roam/` and is stored as given.
/// [root] is the folder org-roam's absolute paths start with; it appears in
/// Org's `FILE` property.
///
/// A file org-roam fails on, such as one with an unterminated quote in
/// `ROAM_ALIASES`, gives no nodes and links but an [RoamFileData.error]:
/// org-roam skips such a file entirely.
RoamFileData parseRoamFile(
  String path,
  String text, {
  String root = '',
  List<String> todoKeywords = doomTodoKeywords,
  List<String> linkTypes = defaultLinkTypes,
}) {
  try {
    return _FileParser(path, text, root, todoKeywords, linkTypes).parse();
  } on FormatException catch (e) {
    return RoamFileData(path: path, error: e.message);
  }
}

// Line patterns.
final _heading = RegExp(r'^(\*+) (.*)$');
final _comment = RegExp(r'^[ \t]*#(?: |$)');
final _fixedWidth = RegExp(r'^[ \t]*:(?: |$)');
final _clock = RegExp(r'^[ \t]*CLOCK:');
final _propertiesStart = RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
final _propertyLine = RegExp(r'^[ \t]*:(\S+?)(\+)?:(?:[ \t]+(.*?))?[ \t]*$');
final _planning = RegExp(r'^[ \t]*(?:SCHEDULED|DEADLINE|CLOSED):');
final _planningItem =
    RegExp(r'(CLOSED|DEADLINE|SCHEDULED):[ \t]*([<\[][^>\]\n]*[>\]])');
// The key is greedy, as in Org: `#+filetags::x:` has the key `filetags::x`.
final _keyword = RegExp(r'^[ \t]*#\+(\S+):[ \t]*(.*?)[ \t]*$');
final _blockBegin = RegExp(r'^[ \t]*#\+begin_(\S+)', caseSensitive: false);
final _blockEnd = RegExp(r'^[ \t]*#\+end_(\S+)[ \t]*$', caseSensitive: false);
final _tableRow = RegExp(r'^[ \t]*\|');
final _priorityCookie = RegExp(r'\[#([A-Z0-9]+)\]');
final _statisticsCookie = RegExp(r'\[[0-9]*%\]|\[[0-9]*/[0-9]*\]');
final _nonSpace = RegExp(r'\S');
final _whitespace = RegExp(r'\s+');

/// Blocks whose content Org does not parse, so links in them do not count.
const _hiddenBlocks = {'src', 'example', 'export', 'comment'};

/// Org's special properties; a drawer cannot set them.
const _specialProperties = {
  'ALLTAGS', 'BLOCKED', 'CLOCKSUM', 'CLOCKSUM_T', 'CLOSED', 'DEADLINE', //
  'FILE', 'ITEM', 'PRIORITY', 'SCHEDULED', 'TAGS', 'TIMESTAMP', //
  'TIMESTAMP_IA', 'TODO',
};

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
  _Heading(this.line, this.level, this.todo, this.priorityCookie, this.title,
      this.localTags, this.id, this.properties);

  final int line;
  final int level;
  final String? todo;

  /// `[#A]`, if the heading has one where Org reads a priority.
  final String? priorityCookie;

  /// Null if the heading has no title; org-roam then skips the node.
  final String? title;
  final List<String> localTags;

  /// The node ID, or null if the heading is not a node.
  final String? id;
  final List<_Property>? properties;
  _Heading? parent;

  /// The headings above, outermost first.
  List<_Heading> get ancestors {
    final chain = <_Heading>[];
    for (var p = parent; p != null; p = p.parent) {
      chain.add(p);
    }
    return chain.reversed.toList();
  }
}

/// A piece of text where Org parses objects, and whether it is ordinary
/// text (paragraph, heading, table) rather than a keyword or property value.
typedef _Piece = ({int line, String text, bool parsed});

class _FileParser {
  _FileParser(
      this.path, String text, this.root, this.defaultTodo, this.linkTypes)
      : lines = _normalize(text).split('\n'),
        syntax = _LinkSyntax.of(linkTypes);

  final String path;
  final String root;
  final List<String> lines;
  final List<String> defaultTodo;
  final List<String> linkTypes;
  final _LinkSyntax syntax;

  late final List<_Kind> kind = List.filled(lines.length, _Kind.text);
  final headings = <_Heading>[];
  List<_Property>? fileProperties;
  final planningLine = <_Heading, int>{};
  Map<String, List<String>> keywords = const {};
  List<String> fileTags = const [];

  /// For each line, its character position in the file, from 1, counting
  /// characters as Emacs does (not UTF-16 units).
  late final List<int> _lineStart = _computeLineStarts();

  /// For each line, the heading it belongs to (null above the first).
  late final List<_Heading?> _headingOfLine = _computeHeadingOfLine();

  /// The link source of each heading, computed once.
  final _sourceOfHeading = <_Heading, String?>{};

  /// The timestamps of each line, found once.
  final _timestampsOfLine = <int, List<_Timestamp>>{};

  String get _filePath => root.isEmpty ? path : '$root/$path';

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
    final planning = <int, int>{};
    final headingDrawers = <int, List<_Property>>{};
    for (final i in headingLines) {
      var j = i + 1;
      if (j < lines.length && kind[j] == _Kind.text && _planning.hasMatch(lines[j])) {
        planning[i] = j;
        j++;
      }
      if (_drawerAt(j) case final drawer?) headingDrawers[i] = drawer;
    }
    keywords = _readKeywords();

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
    fileTags = [
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
        match.group(2),
        match.group(3),
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
      if (planning[i] case final p?) planningLine[heading] = p;
    }

    // `org-roam-db--file-title` joins the #+title values. Without one it
    // yields "" (`string-join` of nil), not the file name.
    final fileTitle = _displayFormat((keywords['TITLE'] ?? const []).join(' '));

    final nodes = <RoamNode>[];
    // `org-roam-db-insert-file-node`: only if the file does not start with a
    // heading.
    final fileId = startsWithHeading ? null : _nodeId(fileProperties);
    if (fileId != null) {
      nodes.add(_node(
        id: fileId,
        level: 0,
        title: fileTitle,
        line: 1,
        pos: 1,
        tags: fileTags,
        properties: fileProperties!,
        orgProperties: _entryProperties(null),
      ));
    }
    // `org-roam-db-insert-node-data` and `org-roam-db-insert-tags`.
    for (final (index, heading) in headings.indexed) {
      final id = heading.id;
      final title = heading.title;
      if (id == null || title == null) continue;
      final inherited = [
        ...fileTags,
        for (final p in heading.ancestors) ...p.localTags,
      ];
      String? scheduled;
      String? deadline;
      if (planningLine[heading] case final p?) {
        for (final m in _planningItem.allMatches(lines[p])) {
          if (m.group(1) == 'SCHEDULED') scheduled = _isoTime(m.group(2)!);
          if (m.group(1) == 'DEADLINE') deadline = _isoTime(m.group(2)!);
        }
      }
      nodes.add(_node(
        id: id,
        level: heading.level,
        title: _displayFormat(title),
        line: heading.line + 1,
        // org-map-region finds the first heading with a regexp search,
        // which leaves point after the stars and the space.
        pos: _lineStart[heading.line] + (index == 0 ? heading.level + 1 : 0),
        tags: _dedupKeepLast([...inherited, ...heading.localTags]),
        properties: heading.properties!,
        orgProperties: _entryProperties(heading),
        todo: heading.todo,
        priority: heading.priorityCookie?.runes.elementAt(2),
        scheduled: scheduled,
        deadline: deadline,
        olp: [for (final a in heading.ancestors) _outlineTitle(a)],
      ));
    }

    final (links, citations) = _linksAndCitations();
    return RoamFileData(
      path: path,
      title: fileTitle,
      nodes: nodes,
      links: links,
      citations: citations,
    );
  }

  RoamNode _node({
    required String id,
    required int level,
    required String title,
    required int line,
    required int pos,
    required List<String> tags,
    required List<_Property> properties,
    required String orgProperties,
    String? todo,
    int? priority,
    String? scheduled,
    String? deadline,
    List<String> olp = const [],
  }) =>
      RoamNode(
        id: id,
        file: path,
        level: level,
        title: title,
        line: line,
        pos: pos,
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
        todo: todo,
        priority: priority,
        scheduled: scheduled,
        deadline: deadline,
        olp: olp,
        properties: orgProperties,
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

  List<int> _computeLineStarts() {
    final starts = <int>[];
    var pos = 1;
    for (final line in lines) {
      starts.add(pos);
      pos += line.runes.length + 1;
    }
    return starts;
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

  /// A heading's title in an outline path (`org-get-outline-path`): without
  /// statistics cookies, links shown by their description, trimmed.
  String _outlineTitle(_Heading heading) {
    final title = heading.title;
    if (title == null) return '';
    return _displayFormat(title.replaceAll(_statisticsCookie, '')).trim();
  }

  /// The outline path at [line], including the heading the line is under.
  List<String> _outlineAt(int line) {
    final heading = _headingOfLine[line];
    if (heading == null) return const [];
    return [
      for (final a in heading.ancestors) _outlineTitle(a),
      _outlineTitle(heading),
    ];
  }

  (List<RoamLink>, List<RoamCitation>) _linksAndCitations() {
    // A heading with an ID but no title is a link source for org-roam, but
    // it stores no node for it, and then no links from it either.
    final untitled = {
      for (final h in headings)
        if (h.id != null && h.title == null) h.id,
    };
    final links = <RoamLink>[];
    final citations = <RoamCitation>[];
    for (final piece in _linkablePieces()) {
      for (final object in syntax.findObjects(piece.text)) {
        if (object is _Timestamp) continue;
        final offset = object.offset;
        final lineStartInPiece =
            offset == 0 ? 0 : piece.text.lastIndexOf('\n', offset - 1) + 1;
        final line = piece.line + _countNewlines(piece.text, offset);
        final pos = _lineStart[line] +
            piece.text.substring(lineStartInPiece, offset).runes.length;
        final source = _sourceAt(line);
        if (source == null || untitled.contains(source)) continue;
        switch (object) {
          case _Link():
            links.add(RoamLink(
              source: source,
              dest: object.path,
              file: path,
              line: line + 1,
              type: object.type,
              pos: pos,
              outline: _outlineAt(line),
              searchOption: object.option,
            ));
          case _Citation():
            // org-roam takes citations from Org's syntax tree, which does
            // not parse keyword and property values.
            if (piece.parsed) {
              citations.add(RoamCitation(
                nodeId: source,
                key: object.key,
                pos: pos,
                outline: _outlineAt(line),
              ));
            }
          case _Timestamp():
            break;
        }
      }
    }
    return (links, citations);
  }

  /// The text where org-roam finds links: paragraphs, headings, table rows,
  /// keyword values and property values. Not comments, fixed-width lines,
  /// hidden blocks, `ROAM_REFS` or `#+transclude:`
  /// (`org-roam-db-extra-links-exclude-keys`).
  Iterable<_Piece> _linkablePieces() sync* {
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
              yield (line: i, text: line, parsed: false);
            }
            i++;
          }
        case _Kind.keyword:
          {
            final key = _keyword.firstMatch(line)!.group(1)!.toLowerCase();
            if (key != 'transclude') yield (line: i, text: line, parsed: false);
            i++;
          }
        case _Kind.heading:
          yield (line: i, text: line, parsed: true);
          i++;
        case _Kind.text:
          if (_comment.hasMatch(line) ||
              _fixedWidth.hasMatch(line) ||
              line.trim().isEmpty) {
            i++;
          } else if (_tableRow.hasMatch(line)) {
            yield (line: i, text: line, parsed: true);
            i++;
          } else {
            // A paragraph: a link description may wrap onto the next line.
            var j = i;
            while (j + 1 < lines.length && _continuesParagraph(j + 1)) {
              j++;
            }
            yield (
              line: i,
              text: lines.sublist(i, j + 1).join('\n'),
              parsed: true,
            );
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

  // ---------------------------------------------------------------------
  // Org's property list of a node (`org-entry-properties`), as org-roam
  // stores it in `nodes.properties`.

  /// The node's properties as an Emacs Lisp alist. [heading] is null for
  /// the file node.
  ///
  /// Org pushes the entries onto a list, so the result is in reverse order
  /// of how Org finds them: ITEM, TODO, PRIORITY, FILE, TAGS, ALLTAGS,
  /// BLOCKED, the planning line, the first timestamps, the drawer, and
  /// CATEGORY.
  String _entryProperties(_Heading? heading) {
    final entries = <(String, String)>[]; // newest first
    void push(String key, String value) => entries.insert(0, (key, value));

    if (heading != null) {
      push('ITEM', elispString(_untabify(heading.title ?? '')));
      if (heading.todo case final todo?) push('TODO', elispString(todo));
      // `org-priority-regexp`: the first [#X] anywhere in the heading line.
      final priority = _priorityCookie.firstMatch(lines[heading.line]);
      push('PRIORITY', elispString(priority?.group(1) ?? 'B'));
    } else {
      push('PRIORITY', elispString('B'));
    }
    push('FILE', elispString(_filePath));

    if (heading != null) {
      final inherited = [
        ...fileTags,
        for (final p in heading.ancestors) ...p.localTags,
      ];
      if (heading.localTags.isNotEmpty) {
        push('TAGS', elispString(':${heading.localTags.join(':')}:'));
      }
      final all = _dedupKeepLastFlagged([
        for (final t in inherited) (t, true),
        for (final t in heading.localTags) (t, false),
      ]);
      if (all.isNotEmpty) push('ALLTAGS', _tagString(all));
    } else {
      final all = _dedupKeepLastFlagged([for (final t in fileTags) (t, true)]);
      if (all.isNotEmpty) push('ALLTAGS', _tagString(all));
    }
    push('BLOCKED', elispString(''));

    if (heading != null) {
      if (planningLine[heading] case final p?) {
        for (final m in _planningItem.allMatches(lines[p])) {
          push(m.group(1)!, elispString(m.group(2)!));
        }
      }
    }

    for (final (key, raw) in _firstTimestamps(heading).reversed) {
      push(key, elispString(raw));
    }

    final drawer = heading == null ? fileProperties : heading.properties;
    for (final (key, value) in _drawerEntries(drawer).reversed) {
      push(key, elispString(value));
    }
    if (!entries.any((e) => e.$1 == 'CATEGORY')) {
      push('CATEGORY', elispString(_category(heading)));
    }
    return '(${[
      for (final (key, value) in entries) '(${elispString(key)} . $value)',
    ].join(' ')})';
  }

  /// The drawer's part of the property list, newest first: special
  /// properties are skipped, `KEY+` adds to `KEY`, a repeated `KEY` is
  /// ignored.
  List<(String, String)> _drawerEntries(List<_Property>? drawer) {
    final entries = <List<String>>[]; // [key, value], newest first
    final seen = <String>{};
    for (final p in drawer ?? const <_Property>[]) {
      if (_specialProperties.contains(p.key)) continue;
      final old = entries.where((e) => e[0] == p.key).firstOrNull;
      if (p.plus) {
        if (old == null) {
          entries.insert(0, [p.key, p.value]);
        } else {
          old[1] = '${old[1]} ${p.value}';
        }
      } else if (seen.add(p.key)) {
        if (old != null) {
          old[1] = '${p.value} ${old[1]}';
        } else {
          entries.insert(0, [p.key, p.value]);
        }
      }
    }
    return [for (final e in entries) (e[0], e[1])];
  }

  /// `org-get-category`: the nearest CATEGORY property, then the last
  /// `#+category:`, then the file name without `.org`.
  String _category(_Heading? heading) {
    if (heading != null) {
      for (final h in [heading, ...heading.ancestors.reversed]) {
        final value = _propertyValueOrNull(h.properties, 'CATEGORY');
        if (value != null) return value;
      }
    }
    final value = _propertyValueOrNull(fileProperties, 'CATEGORY');
    if (value != null) return value;
    final keyword = keywords['CATEGORY'];
    if (keyword != null && keyword.isNotEmpty) return keyword.last;
    final name = path.split('/').last;
    return name.endsWith('.org') ? name.substring(0, name.length - 4) : name;
  }

  /// The first active and inactive timestamps of the entry: in the heading
  /// line, then in its text up to the next heading, skipping the planning
  /// line. Newest first, as Org pushes them.
  List<(String, String)> _firstTimestamps(_Heading? heading) {
    final found = <(String, String)>[];
    final begin = heading?.line ?? 0;
    final end = heading == null
        ? (headings.isEmpty ? lines.length : headings.first.line)
        : _nextHeadingLine(heading.line);
    bool search(int from, int to) {
      for (var i = from; i < to; i++) {
        for (final ts in _timestampsIn(i)) {
          final key = ts.active ? 'TIMESTAMP' : 'TIMESTAMP_IA';
          if (!found.any((e) => e.$1 == key)) found.insert(0, (key, ts.raw));
          if (found.length == 2) return true;
        }
      }
      return false;
    }

    if (!search(begin, begin + 1)) {
      var first = begin + 1;
      if (first < lines.length &&
          kind[first] == _Kind.text &&
          _planning.hasMatch(lines[first])) {
        first++;
      }
      search(first, end);
    }
    return found;
  }

  int _nextHeadingLine(int line) {
    for (final h in headings) {
      if (h.line > line) return h.line;
    }
    return lines.length;
  }

  /// Timestamps in line [i], where Org parses them: text and headings, not
  /// comments, fixed-width or clock lines, drawers' property lines or
  /// keywords.
  List<_Timestamp> _timestampsIn(int i) => _timestampsOfLine.putIfAbsent(i, () {
        final line = lines[i];
        final ok = kind[i] == _Kind.heading ||
            (kind[i] == _Kind.text &&
                !_comment.hasMatch(line) &&
                !_fixedWidth.hasMatch(line) &&
                !_clock.hasMatch(line));
        if (!ok) return const [];
        return [
          for (final o in syntax.findObjects(line))
            if (o is _Timestamp) o,
        ];
      });

  /// ALLTAGS: `:a:b:`, with `(inherited t)` over inherited tags.
  String _tagString(List<(String, bool)> tags) {
    final text = ':${tags.map((t) => t.$1).join(':')}:';
    final spans = <(int, int)>[];
    var pos = 1;
    for (final (tag, inherited) in tags) {
      final length = tag.runes.length;
      if (inherited) spans.add((pos, pos + length));
      pos += length + 1;
    }
    return elispPropertized(text, spans);
  }
}

String _normalize(String text) {
  var result = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // Emacs drops a UTF-8 byte order mark.
  if (result.startsWith('\uFEFF')) result = result.substring(1);
  return result;
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

String? _propertyValueOrNull(List<_Property>? properties, String key) =>
    properties == null ? null : _propertyValue(properties, key);

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
  final value = [?base, ...more].join(' ');
  return value == 'nil' ? null : value;
}

/// `org-get-tags` keeps the last of repeated tags.
List<String> _dedupKeepLast(List<String> tags) =>
    [for (final (tag, _) in _dedupKeepLastFlagged([for (final t in tags) (t, false)])) tag];

List<(String, bool)> _dedupKeepLastFlagged(List<(String, bool)> tags) {
  final seen = <String>{};
  final kept = <(String, bool)>[];
  for (final tag in tags.reversed) {
    if (seen.add(tag.$1)) kept.add(tag);
  }
  return kept.reversed.toList();
}

/// `org-remove-tabs`: tabs become spaces up to the next multiple of 8.
String _untabify(String text) {
  final out = StringBuffer();
  var column = 0;
  for (final c in text.runes) {
    if (c == 0x09) {
      final spaces = 8 - column % 8;
      out.write(' ' * spaces);
      column += spaces;
    } else {
      out.writeCharCode(c);
      column++;
    }
  }
  return out.toString();
}

/// `format-time-string "%FT%T"` of a planning timestamp:
/// `<2026-03-01 Sun 10:30 +1w>` gives `2026-03-01T10:30:00`.
String? _isoTime(String timestamp) {
  final m = _timestampDate.firstMatch(timestamp);
  if (m == null) return null;
  final hour = int.tryParse(m.group(2) ?? '') ?? 0;
  final minute = int.tryParse(m.group(3) ?? '') ?? 0;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${m.group(1)}T${two(hour)}:${two(minute)}:00';
}

final _timestampDate =
    RegExp(r'^[<\[](\d{4}-\d{2}-\d{2})(?: [^\d>\]]*)?(?: ?(\d{1,2}):(\d{2}))?');

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
// post-emphasis characters. As in Org 9.7, the object may span line
// breaks up to the end of its paragraph ([_paragraphEnd]); the pattern is
// matched within the paragraph, so `$` is its end. The closing marker may
// also be followed by the marker that ends an enclosing *bold*, /italic/,
// _underline_ or +strike-through+, as in `*a =x=* b`: Org parses the bold
// first and ends the verbatim with it.
final _verbatim = RegExp(
    r'''([=~])(\S|\S[\s\S]*?\S)\1'''
    r'''(?=[-\s.,:!?;'")}\\\[]|$|[*/_+](?:[-\s.,:!?;'")}\\\[]|$))''');

// A footnote reference or definition, `[fn:label]`, or the start of an
// inline one, `[fn:label:` or `[fn::`. Org parses it before plain links, so
// `fn:label` is no link even where `fn` is a link type (Doom registers
// one); links in an inline definition still count.
final _footnoteStart = RegExp(r'\[fn:[-\w]*[\]:]');

// A line that ends a paragraph, as Org 9.7 parses one: a blank line, or a
// line that starts another element (heading, list item, table, keyword or
// block, fixed width, comment, drawer, horizontal rule, footnote).
final _paragraphBreak = RegExp(
  r'^(?:\s*$|\*+\s|\s*(?:[-+]|\d+[.)])(?:\s|$)|\s+\*(?:\s|$)|\s*\||\s*#\+'
  r'|\s*:(?:\s|$)|\s*#(?:\s|$)|\s*:[\w-]+:\s*$|\s*-{5,}\s*$|\[fn:)',
);

/// The end of the paragraph that holds [start]: the line break before the
/// next line that ends it ([_paragraphBreak]), or the end of [text].
int _paragraphEnd(String text, int start) {
  var lineEnd = text.indexOf('\n', start);
  while (lineEnd >= 0) {
    final next = lineEnd + 1;
    final nextEnd = text.indexOf('\n', next);
    final line = text.substring(next, nextEnd < 0 ? text.length : nextEnd);
    if (_paragraphBreak.hasMatch(line)) return lineEnd;
    lineEnd = nextEnd;
  }
  return text.length;
}
final _inlineSource = RegExp(r'src_[^\s{\[]+(?:\[[^\]\n]*\])?\{[^}\n]*\}');
final _citationObject = RegExp(r'\[cite(?:/[^:\]\n]*)?:([^\]]*)\]');
final _timestamp = RegExp(
  r'(<\d{4}-\d{2}-\d{2}(?: [^<>\n]*?)?>(?:--<\d{4}-\d{2}-\d{2}(?: [^<>\n]*?)?>)?)'
  r'|(\[\d{4}-\d{2}-\d{2}(?: [^\[\]\n]*?)?\](?:--\[\d{4}-\d{2}-\d{2}(?: [^\[\]\n]*?)?\])?)',
);
const _verbatimPre = "-('\"{";
const _punctuation = r'''!"#$%&'()*+,-.:;<=>?@[\]^_`{|}~''';

/// Link types whose `::search` option Org's parser removes from the path
/// without org-roam seeing it.
const _fileTypes = {'file', 'file+sys', 'file+emacs'};

/// An object Org's parser finds in text.
sealed class _Object {
  _Object(this.offset);

  /// Where it starts in the text, in UTF-16 units.
  final int offset;
}

class _Link extends _Object {
  _Link(super.offset, this.type, this.path, this.option);

  final String type;
  final String path;
  final String? option;
}

class _Citation extends _Object {
  _Citation(super.offset, this.key);

  final String key;
}

class _Timestamp extends _Object {
  _Timestamp(super.offset, this.raw, this.active);

  final String raw;
  final bool active;
}

/// Finds links, citations and timestamps in text the way Org's object
/// parser does, for the registered link types.
class _LinkSyntax {
  _LinkSyntax._(List<String> types)
      : _angle = RegExp('<(${_alternatives(types)}):([^>\\n]*)>'),
        _plain = RegExp('(${_alternatives(types)}):([^\\[\\]\\s()<>]+)'),
        _typePrefix = RegExp('^(${_alternatives(types)}):([\\s\\S]*)\$');

  factory _LinkSyntax.of(List<String> types) =>
      _cache[types.join(' ')] ??= _LinkSyntax._(types);

  static final _cache = <String, _LinkSyntax>{};

  final RegExp _angle;
  final RegExp _plain;
  final RegExp _typePrefix;

  static String _alternatives(List<String> types) {
    final sorted = [...types]..sort((a, b) => b.length.compareTo(a.length));
    return sorted.map(_escape).join('|');
  }

  /// Objects in [text], left to right. Verbatim, code and inline source
  /// are skipped as a whole, so nothing inside them counts.
  List<_Object> findObjects(String text) {
    final found = <_Object>[];
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == '[' && text.startsWith('[[', i)) {
        final m = _bracketLink.matchAsPrefix(text, i);
        if (m != null) {
          found.add(_bracket(i, m.group(1)!));
          i = m.end;
          continue;
        }
      }
      if (c == '[' && text.startsWith('[fn:', i)) {
        final m = _footnoteStart.matchAsPrefix(text, i);
        if (m != null) {
          i = m.end;
          continue;
        }
      }
      if (c == '[' && text.startsWith('[cite', i)) {
        final m = _citationObject.matchAsPrefix(text, i);
        if (m != null) {
          // Each reference starts after the colon or after a semicolon.
          var offset = text.indexOf(':', i) + 1;
          for (final part in m.group(1)!.split(';')) {
            final key = _citationKey.firstMatch(part);
            if (key != null) found.add(_Citation(offset, key.group(1)!));
            offset += part.length + 1;
          }
          i = m.end;
          continue;
        }
      }
      if (c == '<' || c == '[') {
        final m = _timestamp.matchAsPrefix(text, i);
        if (m != null) {
          found.add(_Timestamp(i, m.group(0)!, c == '<'));
          i = m.end;
          continue;
        }
      }
      if (c == '<') {
        final m = _angle.matchAsPrefix(text, i);
        if (m != null) {
          found.add(_link(i, m.group(1)!, m.group(2)!.trim()));
          i = m.end;
          continue;
        }
      }
      final atWordStart = i == 0 || !_wordChar.hasMatch(text[i - 1]);
      if ((c == '=' || c == '~') &&
          (i == 0 || text[i - 1].trim().isEmpty || _verbatimPre.contains(text[i - 1]))) {
        final paragraph = text.substring(i, _paragraphEnd(text, i));
        final m = _verbatim.matchAsPrefix(paragraph);
        if (m != null) {
          i += m.end;
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
          found.add(_link(i, plain.type, plain.target));
          i = plain.end;
          continue;
        }
      }
      i++;
    }
    return found;
  }

  /// A bracket link's type and path, as Org's link parser sees them.
  _Link _bracket(int offset, String raw) {
    final target = raw
        .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), ' ')
        .replaceAllMapped(RegExp(r'\\(\\*[\[\]])'), (m) => m.group(1)!);
    final typed = _typePrefix.firstMatch(target);
    if (typed != null) return _link(offset, typed.group(1)!, typed.group(2)!);
    if (target.startsWith('#')) {
      return _Link(offset, 'custom-id', target.substring(1), null);
    }
    if (target.startsWith('(') && target.endsWith(')')) {
      return _Link(offset, 'coderef', target.substring(1, target.length - 1), null);
    }
    if (target.startsWith('/') ||
        target.startsWith('~/') ||
        target.startsWith('./') ||
        target.startsWith('../')) {
      return _link(offset, 'file', target);
    }
    return _Link(offset, 'fuzzy', target, null);
  }

  /// org-roam strips a `::search` option from any path and keeps it; for
  /// file links Org has already removed it.
  static _Link _link(int offset, String type, String path) {
    final option = path.indexOf('::');
    if (option < 0) return _Link(offset, type, path, null);
    return _Link(
      offset,
      type,
      path.substring(0, option),
      _fileTypes.contains(type) ? null : path.substring(option + 2),
    );
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
}
