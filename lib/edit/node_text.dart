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

/// The `:ID:` property line of [id].
RegExp _idLine(String id) =>
    RegExp('^[ \\t]*:ID:[ \\t]+${RegExp.escape(id)}[ \\t]*\$',
        caseSensitive: false);

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

  /// Finds [node] in [text]; null if its heading is no longer there.
  static NodeLines? find(String text, RoamNode node) {
    final newline = text.contains('\r\n') ? '\r\n' : '\n';
    final lines = text.split(newline);
    if (node.isFile) {
      return NodeLines._(
          lines, newline, 0, _headEnd(lines, 0, file: true), lines.length,
          isFile: true);
    }
    final idLine = _idLine(node.id);
    int? heading;
    int? level;
    var found = false;
    for (var i = 0; i < lines.length && !found; i++) {
      if (headingLine.firstMatch(lines[i]) case final match?) {
        heading = i;
        level = match.group(1)!.length;
      } else if (heading != null && idLine.hasMatch(lines[i])) {
        found = true;
      }
    }
    if (!found || heading == null || level == null) return null;
    var end = lines.length;
    for (var i = heading + 1; i < lines.length; i++) {
      final match = headingLine.firstMatch(lines[i]);
      if (match != null && match.group(1)!.length <= level) {
        end = i;
        break;
      }
    }
    return NodeLines._(lines, newline, heading,
        _headEnd(lines, heading + 1, file: false), end,
        isFile: false);
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
    final added = addition.trimRight().split(RegExp(r'\r?\n'));
    final result = [...lines]..insertAll(at, added);
    // A file that did not end with a newline gets one after the addition.
    if (at + added.length == result.length) result.add('');
    return result.join(newline);
  }
}
