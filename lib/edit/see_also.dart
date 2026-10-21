/// The "See also:" line of a note (#135): where a new link to another note
/// goes, for the agent's `add_link` and for "+" in the note view, so both
/// write it the same way.
///
/// Pure Dart (no Flutter).
library;

import '../ai/ai_visibility.dart' show idLinkTargets;
import 'node_text.dart';

/// The end of the node's own lines in [lines]: its first subheading that
/// is a node of its own, whose links org-roam counts for that node
/// instead; else the node's end.
int ownEnd(NodeLines lines) {
  final all = lines.lines;
  final drawer = RegExp(r'^[ \t]*:PROPERTIES:[ \t]*$', caseSensitive: false);
  final planning =
      RegExp(r'^[ \t]*(SCHEDULED|DEADLINE|CLOSED):', caseSensitive: false);
  final id = RegExp(r'^[ \t]*:ID:[ \t]+\S', caseSensitive: false);
  final end = RegExp(r'^[ \t]*:END:[ \t]*$', caseSensitive: false);
  for (var i = lines.bodyStart; i < lines.end; i++) {
    if (!headingLine.hasMatch(all[i])) continue;
    var j = i + 1;
    if (j < all.length && planning.hasMatch(all[j])) j++;
    if (j >= all.length || !drawer.hasMatch(all[j])) continue;
    for (var k = j + 1; k < all.length && !end.hasMatch(all[k]); k++) {
      if (id.hasMatch(all[k])) return i;
    }
  }
  return lines.end;
}

/// Whether the node's own lines in [lines] link to [id] already.
bool linksTo(NodeLines lines, String id) => idLinkTargets(
        lines.lines.sublist(lines.start, ownEnd(lines)).join('\n'))
    .contains(id);

/// The file of [lines] with [link] added to the node's "See also:" line:
/// the last line of its own text, if that line starts with "See also:";
/// else a new line "See also: [link]" after the last line that is not
/// blank, before any subheading that is a node. Null if the node links
/// to [id] already.
String? withSeeAlso(NodeLines lines, String id, String link) {
  if (linksTo(lines, id)) return null;
  final own = ownEnd(lines);
  var at = -1;
  for (var i = own - 1; i >= lines.bodyStart; i--) {
    if (lines.lines[i].startsWith('See also:')) {
      at = i;
      break;
    }
    if (lines.lines[i].trim().isNotEmpty) break;
  }
  if (at >= 0) {
    final changed = [...lines.lines];
    final line = changed[at].trimRight();
    changed[at] = line == 'See also:' ? '$line $link' : '$line, $link';
    return changed.join(lines.newline);
  }
  var end = own;
  while (end > lines.bodyStart && lines.lines[end - 1].trim().isEmpty) {
    end--;
  }
  final changed = [...lines.lines]..insert(end, 'See also: $link');
  // A file that did not end with a newline gets one.
  if (end == lines.lines.length) changed.add('');
  return changed.join(lines.newline);
}
