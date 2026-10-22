/// The buttons of "Edit text" (#151): headings and list items changed as
/// Org's commands change them, on the line of the cursor or the lines of a
/// selection.
///
/// Everything works on the lines of the text in the editor, which is the
/// node's text after its head (decision 10, rule 5): the head is not in it,
/// so no button can change it. A button that would change a property
/// drawer, the heading line above one, or a `#+title:` or `#+filetags:`
/// line does nothing and says why; the save would refuse such a change
/// (decision 51).
library;

import 'package:org_flutter/org_flutter.dart' show OrgTodoStates;

import 'node_text.dart' show headingLine, sameLockedKeywords;
import 'note_editor.dart' show propertyDrawers;
import 'org_toggles.dart' show allKeywords, nextKeyword;

/// What a button does.
enum StructureAction {
  /// `org-insert-heading` after the subtree (C-RET).
  newHeading,

  /// `org-promote-subtree` (M-S-left), or a list item with its children.
  promote,

  /// `org-demote-subtree` (M-S-right), or a list item with its children.
  demote,

  /// `org-move-subtree-up` (M-up), or a list item past its sibling.
  moveUp,

  /// `org-move-subtree-down` (M-down), or a list item past its sibling.
  moveDown,

  /// A new list item after the current one, with the same bullet (M-RET).
  newItem,

  /// The current item becomes a checkbox item, or a plain one again.
  checkbox,

  /// The heading's next TODO state, as `org-todo` cycles.
  todo,
}

/// The result of a button.
sealed class StructureResult {
  const StructureResult();
}

/// The new text, with the selection to show in it.
class StructureChanged extends StructureResult {
  const StructureChanged(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

/// Nothing changed, for [reason].
class StructureRefused extends StructureResult {
  const StructureRefused(this.reason);
  final String reason;
}

/// [action] on [text] with the selection from [start] to [end] (equal
/// for a cursor; -1 for none).
///
/// [topLevel] is the highest level a heading may have in [text]: 1 for a
/// file node, one more than the node's own heading for a heading node, so
/// no heading leaves the node's subtree. [todoStates] are the note's TODO
/// keywords (`#+TODO:` or `TODO | DONE`).
StructureResult applyStructureAction(
  StructureAction action,
  String text, {
  required int start,
  required int end,
  int topLevel = 1,
  required List<OrgTodoStates> todoStates,
}) {
  if (start < 0 || end < 0) {
    return const StructureRefused(
        'Tap in the text first, to put the cursor on a line.');
  }
  final doc = _Text(text);
  final from = doc.position(start < end ? start : end);
  final to = doc.position(start < end ? end : start);
  var lastLine = to.line;
  // A selection that ends at the start of a line does not take that line.
  if (lastLine > from.line && to.column == 0) lastLine--;
  final StructureResult result = switch (action) {
    StructureAction.newHeading => doc.newHeading(lastLine, topLevel),
    StructureAction.promote =>
      doc.shift(from.line, lastLine, -1, topLevel, from, to),
    StructureAction.demote =>
      doc.shift(from.line, lastLine, 1, topLevel, from, to),
    StructureAction.moveUp => doc.move(from.line, up: true, from, to),
    StructureAction.moveDown => doc.move(from.line, up: false, from, to),
    StructureAction.newItem => doc.newItem(lastLine),
    StructureAction.checkbox => doc.checkbox(from.line, lastLine, from, to),
    StructureAction.todo => doc.todo(from.line, todoStates, topLevel, from, to),
  };
  if (result is! StructureChanged) return result;
  // The same checks as the save, so a button never makes a text that
  // cannot be saved.
  if (!sameLockedKeywords(text, result.text)) {
    return const StructureRefused('Lines with #+title: or #+filetags: stay '
        'as they are, so nothing changed.');
  }
  final keywords = allKeywords(todoStates).toSet();
  final before = propertyDrawers(text, todoKeywords: keywords);
  final after = propertyDrawers(result.text, todoKeywords: keywords);
  if (before.length != after.length ||
      [for (var i = 0; i < before.length; i++) before[i] != after[i]]
          .contains(true)) {
    return const StructureRefused('This would change a property drawer (it '
        'holds an :ID:), the heading line above it or their order; they '
        'stay as they are, so nothing changed.');
  }
  return result;
}

typedef _Position = ({int line, int column});

/// A list item's first line: indentation, bullet, the space after it and
/// an optional checkbox with the space after it.
final _item =
    RegExp(r'^([ \t]*)([-+*]|\d+[.)])([ \t]+|$)(\[[ xX-]\](?:[ \t]+|$))?');
final _number = RegExp(r'^(\d+)([.)])$');
final _headingParts = RegExp(r'^(\*+)([ \t]+)(.*)$');

class _ItemLine {
  _ItemLine(RegExpMatch m)
      : indent = m[1]!,
        bullet = m[2]!,
        gap = m[3]!,
        box = m[4];
  final String indent;
  final String bullet;
  final String gap;
  final String? box;

  /// Where the item's text starts, after the bullet and checkbox spaces.
  int get prefixLength =>
      indent.length + bullet.length + gap.length + (box?.length ?? 0);

  /// Where a child item starts: below the item's text.
  int get childIndent =>
      indent.length + bullet.length + (gap.isEmpty ? 1 : gap.length);
}

class _Text {
  _Text(String text)
      : crlf = text.contains('\r\n'),
        lines = [
          for (final line in text.split('\n'))
            line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
        ];

  final bool crlf;
  final List<String> lines;

  String get _newline => crlf ? '\r\n' : '\n';

  _Position position(int offset) {
    var rest = offset;
    for (var i = 0; i < lines.length; i++) {
      final length = lines[i].length + _newline.length;
      if (rest < length || i == lines.length - 1) {
        return (line: i, column: rest.clamp(0, lines[i].length));
      }
      rest -= length;
    }
    return (line: 0, column: 0);
  }

  static int _offset(List<String> lines, _Position p, int newline) {
    var offset = 0;
    for (var i = 0; i < p.line && i < lines.length; i++) {
      offset += lines[i].length + newline;
    }
    final line = p.line < lines.length ? lines[p.line] : '';
    return offset + p.column.clamp(0, line.length);
  }

  StructureChanged _result(List<String> newLines, _Position a, _Position b) {
    final n = _newline.length;
    return StructureChanged(newLines.join(_newline), _offset(newLines, a, n),
        _offset(newLines, b, n));
  }

  StructureChanged _cursorAtEnd(List<String> newLines, int line) {
    final p = (line: line, column: newLines[line].length);
    return _result(newLines, p, p);
  }

  // -------------------------------------------------------------------
  // Reading lines

  int? level(int i) => headingLine.firstMatch(lines[i])?.group(1)!.length;

  bool blank(int i) => lines[i].trim().isEmpty;

  int indentOf(int i) =>
      lines[i].length - lines[i].replaceFirst(RegExp(r'^[ \t]+'), '').length;

  _ItemLine? item(int i) {
    if (level(i) != null) return null;
    final m = _item.firstMatch(lines[i]);
    if (m == null) return null;
    // A `*` at the start of a line is a heading or bold text, not a bullet.
    if (m[2] == '*' && m[1]!.isEmpty) return null;
    return _ItemLine(m);
  }

  /// The last line of the item at [i] that is not blank: its own text and
  /// its sub-items, the lines indented more than its bullet.
  int itemEnd(int i) {
    final indent = indentOf(i);
    var last = i;
    for (var j = i + 1; j < lines.length; j++) {
      if (level(j) != null) break;
      if (blank(j)) continue;
      if (indentOf(j) <= indent) break;
      last = j;
    }
    return last;
  }

  /// The innermost item whose lines hold line [k].
  int? itemAt(int k) {
    for (var i = k; i >= 0; i--) {
      if (level(i) != null) return null;
      if (item(i) != null && itemEnd(i) >= k) return i;
    }
    return null;
  }

  int? previousItem(int i) {
    final indent = indentOf(i);
    for (var j = i - 1; j >= 0; j--) {
      if (level(j) != null) return null;
      if (blank(j)) continue;
      final d = indentOf(j);
      if (d > indent) continue;
      return d == indent && item(j) != null ? j : null;
    }
    return null;
  }

  int? nextItem(int i) {
    final indent = indentOf(i);
    for (var j = itemEnd(i) + 1; j < lines.length; j++) {
      if (blank(j)) continue;
      return indentOf(j) == indent && item(j) != null ? j : null;
    }
    return null;
  }

  int? parentItem(int i) {
    final indent = indentOf(i);
    for (var j = i - 1; j >= 0; j--) {
      if (level(j) != null) return null;
      if (blank(j)) continue;
      if (indentOf(j) < indent) {
        return item(j) != null && itemEnd(j) >= i ? j : null;
      }
    }
    return null;
  }

  /// The heading at or above line [k].
  int? headingAt(int k) {
    for (var i = k; i >= 0; i--) {
      if (level(i) != null) return i;
    }
    return null;
  }

  /// The line after the subtree of the heading at [h].
  int subtreeEnd(int h) {
    final l = level(h)!;
    for (var j = h + 1; j < lines.length; j++) {
      final m = level(j);
      if (m != null && m <= l) return j;
    }
    return lines.length;
  }

  /// The last line before [end], from [start] on, that is not blank; or
  /// [start] - 1 if there is none.
  int lastFilled(int start, int end) {
    var j = end - 1;
    while (j >= start && blank(j)) {
      j--;
    }
    return j;
  }

  int? previousHeading(int h) {
    final l = level(h)!;
    for (var j = h - 1; j >= 0; j--) {
      final m = level(j);
      if (m == null) continue;
      if (m < l) return null;
      if (m == l) return j;
    }
    return null;
  }

  int? nextHeading(int h) {
    final end = subtreeEnd(h);
    return end < lines.length && level(end) == level(h) ? end : null;
  }

  // -------------------------------------------------------------------
  // The buttons

  StructureResult newHeading(int k, int topLevel) {
    final h = headingAt(k);
    final int at;
    final int stars;
    if (h != null) {
      stars = level(h)!;
      at = lastFilled(h, subtreeEnd(h)) + 1;
    } else {
      // Before the first heading: the new one goes after this text, at the
      // highest level the text may have.
      stars = topLevel;
      var first = lines.length;
      for (var j = 0; j < lines.length; j++) {
        if (level(j) != null) {
          first = j;
          break;
        }
      }
      at = lastFilled(0, first) + 1;
    }
    final heading = '${'*' * stars} ';
    if (lines.length == 1 && blank(0)) {
      // An empty text: the heading is its only line.
      return _cursorAtEnd([heading], 0);
    }
    // Blank lines after the subtree stay after the new heading.
    final newLines = [...lines]..insert(at, heading);
    return _cursorAtEnd(newLines, at);
  }

  StructureResult shift(int first, int last, int delta, int topLevel,
      _Position a, _Position b) {
    final headings = [
      for (var i = first; i <= last; i++)
        if (level(i) != null) i,
    ];
    if (headings.isNotEmpty) {
      return _shiftHeadings(headings, delta, topLevel, a, b);
    }
    final items = [
      for (var i = first; i <= last; i++)
        if (item(i) != null) i,
    ];
    if (items.isEmpty) {
      if (itemAt(first) case final i?) items.add(i);
    }
    if (items.isEmpty) {
      return const StructureRefused(
          'Put the cursor on a heading or in a list item.');
    }
    return _shiftItems(items, delta, a, b);
  }

  StructureResult _shiftHeadings(
      List<int> headings, int delta, int topLevel, _Position a, _Position b) {
    final shifted = <int>{};
    for (final h in headings) {
      for (var j = h; j < subtreeEnd(h); j++) {
        if (level(j) != null) shifted.add(j);
      }
    }
    if (delta < 0 && shifted.any((j) => level(j)! <= topLevel)) {
      return StructureRefused(topLevel == 1
          ? 'A heading at level 1 cannot go up a level.'
          : 'This heading cannot go up a level: at the level of the note\'s '
              'own heading it would no longer be part of the note.');
    }
    final newLines = [
      for (var j = 0; j < lines.length; j++)
        !shifted.contains(j)
            ? lines[j]
            : delta > 0
                ? '*${lines[j]}'
                : lines[j].substring(1),
    ];
    _Position map(_Position p) => shifted.contains(p.line) && p.column > 0
        ? (line: p.line, column: (p.column + delta).clamp(0, 1 << 30))
        : p;
    return _result(newLines, map(a), map(b));
  }

  StructureResult _shiftItems(
      List<int> items, int delta, _Position a, _Position b) {
    final top = items.first;
    final int by;
    if (delta > 0) {
      final previous = previousItem(top);
      if (previous == null) {
        return const StructureRefused('The first item of a list cannot go '
            'down a level: it needs an item above it at its level.');
      }
      by = item(previous)!.childIndent - indentOf(top);
    } else {
      final parent = parentItem(top);
      if (parent == null) {
        return const StructureRefused(
            'This item is at the top level of its list already.');
      }
      by = indentOf(parent) - indentOf(top);
    }
    final shifted = <int>{};
    for (final i in items) {
      for (var j = i; j <= itemEnd(i); j++) {
        if (!blank(j)) shifted.add(j);
      }
    }
    final columns = <int, int>{};
    final newLines = [...lines];
    for (final j in shifted) {
      if (by > 0) {
        newLines[j] = '${' ' * by}${lines[j]}';
        columns[j] = by;
      } else {
        final remove = (-by).clamp(0, indentOf(j));
        newLines[j] = lines[j].substring(remove);
        columns[j] = -remove;
      }
    }
    _Position map(_Position p) => columns.containsKey(p.line)
        ? (line: p.line, column: (p.column + columns[p.line]!).clamp(0, 1 << 30))
        : p;
    return _result(newLines, map(a), map(b));
  }

  StructureResult move(int k, _Position a, _Position b, {required bool up}) {
    // Blocks: [start, end] without blank lines at the end; the blank lines
    // between two blocks stay where they are.
    int first, firstEnd, second, secondEnd;
    if (level(k) != null) {
      final other = up ? previousHeading(k) : nextHeading(k);
      if (other == null) {
        return StructureRefused(up
            ? 'This heading is the first at its level here.'
            : 'This heading is the last at its level here.');
      }
      first = up ? other : k;
      second = up ? k : other;
      firstEnd = lastFilled(first, second);
      secondEnd = lastFilled(second, subtreeEnd(second));
    } else if (itemAt(k) case final i?) {
      final other = up ? previousItem(i) : nextItem(i);
      if (other == null) {
        return StructureRefused(up
            ? 'This item is the first of its list.'
            : 'This item is the last of its list.');
      }
      first = up ? other : i;
      second = up ? i : other;
      firstEnd = itemEnd(first);
      secondEnd = itemEnd(second);
    } else {
      return const StructureRefused(
          'Put the cursor on a heading or in a list item.');
    }
    final firstBlock = lines.sublist(first, firstEnd + 1);
    final gap = lines.sublist(firstEnd + 1, second);
    final secondBlock = lines.sublist(second, secondEnd + 1);
    final newLines = [
      ...lines.sublist(0, first),
      ...secondBlock,
      ...gap,
      ...firstBlock,
      ...lines.sublist(secondEnd + 1),
    ];
    int mapLine(int j) {
      if (j < first || j > secondEnd) return j;
      if (j >= second) return first + (j - second);
      if (j > firstEnd) return first + secondBlock.length + (j - firstEnd - 1);
      return first + secondBlock.length + gap.length + (j - first);
    }

    return _result(newLines, (line: mapLine(a.line), column: a.column),
        (line: mapLine(b.line), column: b.column));
  }

  StructureResult newItem(int k) {
    final i = itemAt(k);
    if (i == null) {
      if (level(k) != null) {
        return const StructureRefused(
            'Put the cursor in the text below a heading to start a list.');
      }
      final newLines = [...lines];
      if (blank(k)) {
        newLines[k] = '- ';
        return _cursorAtEnd(newLines, k);
      }
      newLines.insert(k + 1, '- ');
      return _cursorAtEnd(newLines, k + 1);
    }
    final current = item(i)!;
    final number = _number.firstMatch(current.bullet);
    final bullet = number == null
        ? current.bullet
        : '${int.parse(number[1]!) + 1}${number[2]}';
    final line = '${current.indent}$bullet${current.gap.isEmpty ? ' ' : current.gap}'
        '${current.box != null ? '[ ] ' : ''}';
    final at = itemEnd(i) + 1;
    final newLines = [...lines]..insert(at, line);
    if (number != null) {
      // The items after it are numbered on, as Org does. Only the number
      // changes, so the lines stay where they are.
      final after = _Text(newLines.join('\n'));
      var n = int.parse(number[1]!) + 1;
      for (var j = after.nextItem(at); j != null; j = after.nextItem(j)) {
        final m = _item.firstMatch(newLines[j])!;
        final own = _number.firstMatch(m[2]!);
        if (own == null) break;
        n++;
        final rest = newLines[j].substring(m[1]!.length + m[2]!.length);
        newLines[j] = '${m[1]}$n${own[2]}$rest';
      }
    }
    return _cursorAtEnd(newLines, at);
  }

  StructureResult checkbox(int first, int last, _Position a, _Position b) {
    final items = [
      for (var i = first; i <= last; i++)
        if (item(i) != null) i,
    ];
    if (items.isEmpty) {
      if (itemAt(first) case final i?) items.add(i);
    }
    if (items.isEmpty) {
      return const StructureRefused('Put the cursor in a list item.');
    }
    final remove = item(items.first)!.box != null;
    final newLines = [...lines];
    final changes = <int, ({int at, int by})>{};
    for (final i in items) {
      final it = item(i)!;
      final at = it.indent.length + it.bullet.length;
      final rest = lines[i].substring(it.prefixLength);
      if (remove && it.box != null) {
        newLines[i] = '${lines[i].substring(0, at)}${it.gap}$rest';
      } else if (!remove && it.box == null) {
        newLines[i] =
            '${lines[i].substring(0, at)}${it.gap.isEmpty ? ' ' : it.gap}[ ] $rest';
      } else {
        continue;
      }
      changes[i] = (at: at, by: newLines[i].length - lines[i].length);
    }
    _Position map(_Position p) {
      final c = changes[p.line];
      if (c == null || p.column <= c.at) return p;
      return (
        line: p.line,
        column: (p.column + c.by).clamp(c.at, newLines[p.line].length)
      );
    }

    return _result(newLines, map(a), map(b));
  }

  StructureResult todo(int k, List<OrgTodoStates> states, int topLevel,
      _Position a, _Position b) {
    final h = headingAt(k);
    if (h == null) {
      return StructureRefused(topLevel == 1
          ? 'There is no heading at or above the cursor.'
          : 'There is no heading at or above the cursor. The state of the '
              "note's own heading changes in the note view.");
    }
    final m = _headingParts.firstMatch(lines[h])!;
    final rest = m[3]!;
    final word = rest.split(RegExp(r'[ \t]')).first;
    final current = allKeywords(states).contains(word) ? word : null;
    final next = nextKeyword(states, current);
    final String newRest;
    if (current != null) {
      final remainder = rest.substring(word.length);
      newRest = next == null
          ? remainder.replaceFirst(RegExp(r'^[ \t]+'), '')
          : '$next$remainder';
    } else if (next == null) {
      return const StructureRefused('This note has no TODO keywords.');
    } else {
      newRest = rest.isEmpty ? next : '$next $rest';
    }
    final head = m[1]!.length + m[2]!.length;
    final newLines = [...lines]..[h] = '${m[1]}${m[2]}$newRest';
    final by = newRest.length - rest.length;
    _Position map(_Position p) => p.line == h && p.column > head
        ? (line: h, column: (p.column + by).clamp(head, newLines[h].length))
        : p;
    return _result(newLines, map(a), map(b));
  }
}
