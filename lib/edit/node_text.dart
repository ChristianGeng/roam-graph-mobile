/// Where a node is in its file, line by line, for appending (#36) and
/// editing (#37).
library;

import '../graph/roam_graph.dart';

/// A heading line, as Org's `org-outline-regexp-bol` finds it: stars at
/// the start of a line, then a space. Org reads such a line as a heading
/// also inside a block, so this does too.
final headingLine = RegExp(r'^(\*+) ');

final _drawerStart =
    RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
final _drawerEnd = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
final _planning =
    RegExp(r'^[ \t]*(SCHEDULED|DEADLINE|CLOSED):', caseSensitive: false);
final _keyword = RegExp(r'^[ \t]*#\+[^:\s]*:');

/// The `:ID:` property line of [id]: the key in any case, as Org reads
/// property keys; the value exactly, as the index keys nodes by it.
RegExp _idLine(String id) =>
    RegExp('^[ \\t]*:[Ii][Dd]:[ \\t]+${RegExp.escape(id)}[ \\t]*\$');

/// A comment line, which may come before a file's property drawer.
final _comment = RegExp(r'^[ \t]*#(?: |$)');

/// A node's place in the lines of its file: lines [start] to [end]
/// (exclusive) are the node: the whole file for a file node, the heading
/// and its subtree for a heading node. Lines [start] to [bodyStart] are
/// its head, which stays as it is (decision 10, rule 5): for a heading
/// node the heading line (title and tags), its planning line and its
/// property drawer; for a file node the property drawer and the keywords
/// that follow it, such as `#+title:` and `#+filetags:`.
class NodeLines {
  NodeLines._(this.lines, this.newline, this.start, this.bodyStart, this.end,
      {required this.isFile});

  /// Finds [node] in [text]: the file node or heading whose property
  /// drawer holds the node's `:ID:`, as the index found it. Null if no
  /// drawer holds it any more, for example after the laptop changed the
  /// note.
  static NodeLines? find(String text, RoamNode node) {
    final newline = text.contains('\r\n') ? '\r\n' : '\n';
    final lines = text.split(newline);
    final idLine = _idLine(node.id);
    if (node.isFile) {
      // Only comment lines may come before the file's drawer (decision 20).
      var first = 0;
      while (first < lines.length && _comment.hasMatch(lines[first])) {
        first++;
      }
      if (!_drawerHolds(lines, first, idLine)) return null;
      return NodeLines._(
          lines, newline, 0, _headEnd(lines, first, file: true), lines.length,
          isFile: true);
    }
    for (var heading = 0; heading < lines.length; heading++) {
      final match = headingLine.firstMatch(lines[heading]);
      if (match == null) continue;
      // The drawer directly after the heading, or after its planning line.
      var drawer = heading + 1;
      if (drawer < lines.length && _planning.hasMatch(lines[drawer])) drawer++;
      if (!_drawerHolds(lines, drawer, idLine)) continue;
      final level = match.group(1)!.length;
      var end = lines.length;
      for (var i = heading + 1; i < lines.length; i++) {
        final next = headingLine.firstMatch(lines[i]);
        if (next != null && next.group(1)!.length <= level) {
          end = i;
          break;
        }
      }
      return NodeLines._(lines, newline, heading,
          _headEnd(lines, heading + 1, file: false), end,
          isFile: false);
    }
    return null;
  }

  /// Whether a property drawer starts at line [at], is closed, and holds
  /// a line that matches [idLine].
  static bool _drawerHolds(List<String> lines, int at, RegExp idLine) {
    if (at >= lines.length || !_drawerStart.hasMatch(lines[at])) return false;
    for (var i = at + 1; i < lines.length; i++) {
      if (_drawerEnd.hasMatch(lines[i])) return false;
      if (headingLine.hasMatch(lines[i])) return false;
      if (idLine.hasMatch(lines[i])) {
        // Only if the drawer is closed before the next heading.
        for (var j = i + 1; j < lines.length; j++) {
          if (_drawerEnd.hasMatch(lines[j])) return true;
          if (headingLine.hasMatch(lines[j])) return false;
        }
        return false;
      }
    }
    return false;
  }

  /// The end of the head that starts at [from]: a planning line (for a
  /// heading), a property drawer, and (for a file) the keyword lines and
  /// blank lines among them.
  static int _headEnd(List<String> lines, int from, {required bool file}) {
    var i = from;
    if (!file && i < lines.length && _planning.hasMatch(lines[i])) i++;
    if (i < lines.length && _drawerStart.hasMatch(lines[i])) {
      var j = i + 1;
      while (j < lines.length && !_drawerEnd.hasMatch(lines[j])) {
        j++;
      }
      if (j < lines.length) i = j + 1;
    }
    if (file) {
      // Keywords, and blank lines between them.
      while (true) {
        var j = i;
        while (j < lines.length && lines[j].trim().isEmpty) {
          j++;
        }
        if (j >= lines.length || !_keyword.hasMatch(lines[j])) break;
        i = j + 1;
      }
    }
    return i;
  }

  final List<String> lines;
  final String newline;
  final int start;
  final int bodyStart;
  final int end;

  /// True for a file node, whose lines are the whole file.
  final bool isFile;

  /// The head, which stays as it is.
  String get head => lines.sublist(start, bodyStart).join(newline);

  /// The node's text after its head, to edit.
  String get body => lines.sublist(bodyStart, end).join(newline);

  /// The whole file with the node's body replaced by [body].
  String withBody(String body) {
    final replaced = body.split(RegExp(r'\r?\n'));
    return [
      ...lines.sublist(0, bodyStart),
      ...replaced,
      ...lines.sublist(end),
    ].join(newline);
  }

  /// The whole file with [addition] at the end of the node, after its last
  /// line that is not blank, so blank lines before the next heading stay
  /// where they are (#36).
  String withAddition(String addition) {
    var at = end;
    // A heading node's heading line stays first.
    final floor = isFile ? 0 : start + 1;
    while (at > floor && lines[at - 1].trim().isEmpty) {
      at--;
    }
    // Blank lines at the end of the typed text are dropped; spaces at the
    // end of its last line stay.
    final added = addition.split(RegExp(r'\r?\n'));
    while (added.isNotEmpty && added.last.trim().isEmpty) {
      added.removeLast();
    }
    final result = [...lines]..insertAll(at, added);
    // A file that did not end with a newline gets one after the addition.
    if (at + added.length == result.length) result.add('');
    return result.join(newline);
  }
}
