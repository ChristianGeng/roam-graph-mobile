/// The quick edits of the node view (#150): ticking a checkbox and
/// switching a heading's TODO state, as Org's `org-toggle-checkbox` and
/// `org-todo` do.
///
/// The text is changed through `org_parser`, as Orgro changes it: the note
/// is parsed, the one node is replaced in the parsed document, and the
/// document is written back with its markup. So the rest of the file stays
/// byte for byte as it was. A note that the parser cannot write back
/// exactly is not changed here.
library;

import 'package:org_flutter/org_flutter.dart';

import 'unlink.dart' show NoteChangeError;

/// [text] parsed as the node view parses it: with the file's own TODO
/// keywords (`#+TODO:`, `#+SEQ_TODO:`, `#+TYP_TODO:`).
OrgDocument parseNote(String text) =>
    OrgDocument.parse(text, interpretEmbeddedSettings: true);

/// [text] parsed, when writing it back gives [text] again; otherwise a
/// change here could alter other parts of the file.
OrgDocument _parseExactly(String text) {
  final document = parseNote(text);
  if (document.toMarkup() != text) {
    throw const NoteChangeError('The app cannot read this note exactly '
        'enough to change it here; "Edit text" can.');
  }
  return document;
}

/// Every list item of [tree], in the order of the text.
List<OrgListItem> listItemsOf(OrgTree tree) {
  final items = <OrgListItem>[];
  tree.visit<OrgListItem>((item) {
    items.add(item);
    return true;
  });
  return items;
}

/// Every section of [tree] (with [tree] itself if it is one), in the order
/// of the text.
List<OrgSection> sectionsOf(OrgTree tree) {
  final sections = <OrgSection>[];
  tree.visitSections((section) {
    sections.add(section);
    return true;
  });
  return sections;
}

int? _indexOf<T>(List<T> list, T node) {
  for (final (i, n) in list.indexed) {
    if (identical(n, node)) return i;
  }
  return null;
}

/// The place of [item] among the list items of [document], or null if it
/// is not one of them. The node view finds a tapped item in the text again
/// by this number, so it does not depend on the objects of one parse.
int? listItemIndex(OrgTree document, OrgListItem item) =>
    _indexOf(listItemsOf(document), item);

/// The place of [section] among the sections of [document], or null.
int? sectionIndex(OrgTree document, OrgSection section) =>
    _indexOf(sectionsOf(document), section);

bool _checked(String? checkbox) => checkbox == '[X]' || checkbox == '[x]';

// ---------------------------------------------------------------------------
// Checkboxes

/// [text] with the checkbox of its list item number [index] switched, as
/// `org-toggle-checkbox` does: `[ ]` and `[-]` become `[X]`, `[X]` becomes
/// `[ ]`. An item whose sub-items have checkboxes sets them all to its new
/// state, since Org derives such an item's box from its sub-items. Then the
/// boxes of the items above it and the progress cookies (`[1/3]`, `[33%]`)
/// of the items and of the heading the list is under are brought up to
/// date, as Org does with `org-checkbox-hierarchical-statistics` (each
/// counts its direct sub-items).
///
/// [describe] gets what changed, for the message.
String toggleCheckbox(String text, int index,
    {void Function(String description)? describe}) {
  final document = _parseExactly(text);
  final items = listItemsOf(document);
  if (index < 0 || index >= items.length || items[index].checkbox == null) {
    throw const NoteChangeError('That checkbox is no longer in the note.');
  }
  final target = items[index];
  final newState = _checked(target.checkbox) ? '[ ]' : '[X]';
  // The boxes set by the tap: the item, and its sub-items with boxes.
  final forced = Map<OrgListItem, String>.identity()..[target] = newState;
  if (target.body case final body?) {
    body.visit<OrgListItem>((sub) {
      if (sub.checkbox != null) forced[sub] = newState;
      return true;
    });
  }
  final replacements = Map<OrgNode, OrgNode>.identity();
  final tree = _treeAround(document, target);
  _restat(tree, forced, replacements);
  describe?.call(newState == '[X]'
      ? 'Ticked "${_itemText(target)}".'
      : 'Unticked "${_itemText(target)}".');
  return _replaceAll(document, replacements).toMarkup();
}

/// The item's first line, shortened, to name it in a message.
String _itemText(OrgListItem item) {
  final line = (item.body?.toMarkup() ?? '').trim().split('\n').first.trim();
  return line.length > 40 ? '${line.substring(0, 39)}…' : line;
}

/// The innermost section (or the document) that holds [node].
OrgTree _treeAround(OrgDocument document, OrgNode node) {
  final found = document.find<OrgNode>((n) => identical(n, node));
  return found?.path.reversed.whereType<OrgTree>().firstOrNull ?? document;
}

/// The lists directly inside [node]: not those inside another list, and
/// not those of sub-sections.
List<OrgList> _directLists(OrgNode node) {
  final lists = <OrgList>[];
  void walk(OrgNode n) {
    for (final child in n.children ?? const <OrgNode>[]) {
      if (child is OrgList) {
        lists.add(child);
      } else if (child is! OrgSection) {
        walk(child);
      }
    }
  }

  walk(node);
  return lists;
}

/// The progress cookies directly inside [node]: not those inside a list,
/// nor those of sub-sections.
List<OrgStatisticsCookie> _directCookies(OrgNode node) {
  final cookies = <OrgStatisticsCookie>[];
  void walk(OrgNode n) {
    for (final child in n.children ?? const <OrgNode>[]) {
      if (child is OrgStatisticsCookie) {
        cookies.add(child);
      } else if (child is! OrgList && child is! OrgSection) {
        walk(child);
      }
    }
  }

  walk(node);
  return cookies;
}

typedef _Count = ({int done, int total});

/// Recomputes the boxes and cookies of [tree]'s lists, with the [forced]
/// boxes, and records what changes in [replacements]. Returns the count of
/// the checkboxes directly in [tree]'s content.
_Count _restat(OrgTree tree, Map<OrgListItem, String> forced,
    Map<OrgNode, OrgNode> replacements) {
  var done = 0, total = 0;
  final content = tree.content;
  if (content != null) {
    for (final list in _directLists(content)) {
      final count = _restatList(list, forced, replacements);
      done += count.done;
      total += count.total;
    }
  }
  if (tree is OrgSection && total > 0 && !_countsTodos(tree)) {
    _setCookies(_directCookies(tree.headline), (done: done, total: total),
        replacements);
  }
  return (done: done, total: total);
}

/// The boxes of [list]'s items after the change, counted.
_Count _restatList(OrgList list, Map<OrgListItem, String> forced,
    Map<OrgNode, OrgNode> replacements) {
  var done = 0, total = 0;
  for (final item in list.items) {
    final state = _restatItem(item, forced, replacements);
    if (state != null) {
      total++;
      if (_checked(state)) done++;
    }
  }
  return (done: done, total: total);
}

/// The box of [item] after the change: forced by the tap, or derived from
/// its sub-items, or as it was. Records a changed box and its cookies.
String? _restatItem(OrgListItem item, Map<OrgListItem, String> forced,
    Map<OrgNode, OrgNode> replacements) {
  var done = 0, total = 0;
  final body = item.body;
  if (body != null) {
    for (final list in _directLists(body)) {
      final count = _restatList(list, forced, replacements);
      done += count.done;
      total += count.total;
    }
  }
  var state = forced[item] ?? item.checkbox;
  if (total > 0) {
    if (state != null) {
      state = done == 0
          ? '[ ]'
          : done == total
              ? '[X]'
              : '[-]';
    }
    if (body != null) {
      _setCookies(
          _directCookies(body), (done: done, total: total), replacements);
    }
  }
  if (state != item.checkbox) {
    replacements[item] = item.parentCopyWith(checkbox: state);
  }
  return state;
}

void _setCookies(List<OrgStatisticsCookie> cookies, _Count count,
    Map<OrgNode, OrgNode> replacements) {
  for (final cookie in cookies) {
    final updated = cookie.update(done: count.done, total: count.total);
    if (updated.toMarkup() != cookie.toMarkup()) {
      replacements[cookie] = updated;
    }
  }
}

/// Whether [section]'s cookies count TODO sub-headings: its `:COOKIE_DATA:`
/// says `todo`, or, without one, it has no checkboxes of its own.
bool _countsTodos(OrgSection section) {
  final data = section.getProperties(':COOKIE_DATA:').firstOrNull ?? '';
  if (data.contains('todo')) return true;
  if (data.contains('checkbox')) return false;
  final content = section.content;
  return content == null ||
      !_directLists(content)
          .any((list) => list.items.any((i) => i.checkbox != null));
}

/// [document] with every node in [replacements] replaced, in one pass. A
/// replaced item keeps its children, so cookies inside it are replaced
/// too.
OrgDocument _replaceAll(
    OrgDocument document, Map<OrgNode, OrgNode> replacements) {
  if (replacements.isEmpty) return document;
  return document.edit().visit((location) {
    final replacement = replacements[location.node];
    return (true, replacement == null ? null : location.replace(replacement));
  }).commit<OrgDocument>();
}

// ---------------------------------------------------------------------------
// TODO states

/// The TODO keywords of [document]: its `#+TODO:`, `#+SEQ_TODO:` and
/// `#+TYP_TODO:` lines, or Org's default `TODO | DONE`.
List<OrgTodoStates> todoStatesOf(OrgDocument document) {
  final states = extractTodoSettings(document);
  return states.isEmpty ? [defaultTodoStates] : states;
}

/// Every keyword of [states], in order.
List<String> allKeywords(List<OrgTodoStates> states) =>
    [for (final s in states) ...s.todo, ...s.done];

bool _isDone(List<OrgTodoStates> states, String keyword) =>
    states.any((s) => s.done.contains(keyword) ||
        s.done.isEmpty && s.todo.lastOrNull == keyword);

/// The state after [current], as `org-todo` cycles: the next keyword of the
/// sequence [current] is in, then no state; from no state, the first
/// keyword.
String? nextKeyword(List<OrgTodoStates> states, String? current) {
  if (current == null) return allKeywords(states).firstOrNull;
  for (final s in states) {
    final keywords = [...s.todo, ...s.done];
    final i = keywords.indexOf(current);
    if (i < 0) continue;
    return i + 1 < keywords.length ? keywords[i + 1] : null;
  }
  return allKeywords(states).firstOrNull;
}

/// Whether the file asks for a `CLOSED:` time when a heading is done:
/// `#+STARTUP: logdone` (or `org-log-done` in its local variables). Org's
/// default is no logging.
bool logsDone(OrgDocument document) =>
    OrgSettings.fromDocument(document, (_) {}).logDone ?? false;

/// [text] with the heading number [index] set to [keyword] (null: no
/// state), as `org-todo` does. With `#+STARTUP: logdone`, a heading that
/// becomes done gets `CLOSED: [YYYY-MM-DD Day HH:MM]` on its planning line
/// at [now], and loses it when it leaves the done states. The progress
/// cookie of the heading above, when it counts TODO sub-headings, is
/// brought up to date.
String setTodo(String text, int index, String? keyword,
    {required DateTime now, void Function(String description)? describe}) {
  final document = _parseExactly(text);
  final sections = sectionsOf(document);
  if (index < 0 || index >= sections.length) {
    throw const NoteChangeError('That heading is no longer in the note.');
  }
  final section = sections[index];
  final states = todoStatesOf(document);
  if (keyword != null && !allKeywords(states).contains(keyword)) {
    throw NoteChangeError('$keyword is not a TODO keyword of this note.');
  }
  final old = section.headline.keyword?.value;
  if (old == keyword) return text;
  final wasDone = old != null && _isDone(states, old);
  final nowDone = keyword != null && _isDone(states, keyword);
  if (nowDone && !wasDone && _repeats(section)) {
    throw const NoteChangeError('This heading repeats (a timestamp with '
        '+1w or similar); Org moves its dates when it is done. Change it '
        'in Emacs or with "Edit text".');
  }
  var headline = keyword == null
      ? section.headline.withoutKeyword()
      : section.headline.copyWith(keyword: (
          value: keyword,
          done: nowDone,
          trailing: section.headline.keyword?.trailing ?? ' ',
        ));
  OrgSection changed = section.copyWith(headline: headline);
  if (logsDone(document)) {
    if (nowDone && !wasDone) {
      headline = headline.ensureTrailingNewLine();
      changed = _withClosed(section.copyWith(headline: headline), now);
    } else if (!nowDone && wasDone) {
      changed = _withoutClosed(changed);
    }
  }
  final replacements = Map<OrgNode, OrgNode>.identity()..[section] = changed;
  // The cookie of the heading above, if it counts its TODO sub-headings.
  final parent = _parentSection(document, section);
  if (parent != null && _countsTodos(parent)) {
    var done = 0, total = 0;
    for (final child in parent.sections) {
      final k = identical(child, section) ? keyword : child.headline.keyword?.value;
      if (k == null) continue;
      total++;
      if (_isDone(states, k)) done++;
    }
    _setCookies(_directCookies(parent.headline), (done: done, total: total),
        replacements);
  }
  describe?.call(keyword == null
      ? 'Removed the state of "${_headingText(section)}".'
      : '"${_headingText(section)}" is $keyword now.');
  return _replaceTopDown(document, replacements).toMarkup();
}

/// [document] with [replacements] made: the parent's cookie first, then
/// the section, since the zipper finds nodes by identity and a replaced
/// section is a new object.
OrgDocument _replaceTopDown(
    OrgDocument document, Map<OrgNode, OrgNode> replacements) {
  var result = document;
  for (final MapEntry(:key, :value) in replacements.entries.toList().reversed) {
    final location = result.editNode(key);
    if (location == null) continue;
    result = location.replace(value).commit<OrgDocument>();
  }
  return result;
}

String _headingText(OrgSection section) {
  final title = section.headline.rawTitle?.trim() ?? '';
  return title.length > 40 ? '${title.substring(0, 39)}…' : title;
}

OrgSection? _parentSection(OrgDocument document, OrgSection section) {
  final found = document.find<OrgSection>((s) => identical(s, section));
  final path = found?.path;
  if (path == null || path.length < 2) return null;
  final parent = path[path.length - 2];
  return parent is OrgSection ? parent : null;
}

/// Whether [section]'s own planning line has a repeating active timestamp.
bool _repeats(OrgSection section) {
  final line = _planningLine(section);
  if (line == null) return false;
  return line.entries.any((e) =>
      e.value is OrgTimestamp &&
      (e.value as OrgTimestamp).isActive &&
      (e.value as OrgTimestamp).repeats);
}

/// The planning line right below [section]'s heading: the first paragraph
/// of its content, when its first line has only planning entries
/// (`SCHEDULED:`, `DEADLINE:`, `CLOSED:`) and spaces.
({OrgParagraph paragraph, int end, List<OrgPlanningEntry> entries})?
    _planningLine(OrgSection section) {
  final first = section.content?.children.firstOrNull;
  if (first is! OrgParagraph) return null;
  final children = first.body.children;
  final entries = <OrgPlanningEntry>[];
  var end = 0;
  for (; end < children.length; end++) {
    final child = children[end];
    if (child is OrgPlanningEntry) {
      entries.add(child);
    } else if (child is OrgPlainText && child.content.trim().isEmpty &&
        !child.content.contains('\n')) {
      continue;
    } else if (child is OrgPlainText &&
        RegExp(r'^[ \t]*\n').hasMatch(child.content)) {
      break;
    } else {
      return null;
    }
  }
  return entries.isEmpty
      ? null
      : (paragraph: first, end: end, entries: entries);
}

OrgPlanningEntry _closedEntry(DateTime now) => OrgPlanningEntry(
      OrgPlanningKeyword('CLOSED:'),
      ' ',
      OrgSimpleTimestamp('[', now.toOrgDate(), now.toOrgTime(), const [], ']'),
    );

/// [section] with `CLOSED:` at [now] on its planning line, which is made
/// if it has none. Org writes CLOSED first.
OrgSection _withClosed(OrgSection section, DateTime now) {
  final entry = _closedEntry(now);
  final line = _planningLine(section);
  final content = section.content;
  if (line != null && content != null) {
    final children = line.paragraph.body.children;
    final closed = line.entries
        .where((e) => e.keyword.content == 'CLOSED:')
        .firstOrNull;
    final newChildren = closed != null
        ? [for (final c in children) identical(c, closed) ? entry : c]
        : [entry, OrgPlainText(' '), ...children];
    final paragraph = line.paragraph
        .copyWith(body: line.paragraph.body.copyWith(children: newChildren));
    return section.copyWith(
        content: content.copyWith(children: [
      paragraph,
      ...content.children.skip(1),
    ]));
  }
  final paragraph = OrgParagraph('', OrgContent([entry]), '\n');
  return section.copyWith(
      content: OrgContent([paragraph, ...?content?.children]));
}

/// [section] without `CLOSED:` on its planning line; without the line when
/// nothing else was on it.
OrgSection _withoutClosed(OrgSection section) {
  final line = _planningLine(section);
  final content = section.content;
  if (line == null || content == null) return section;
  final closed =
      line.entries.where((e) => e.keyword.content == 'CLOSED:').firstOrNull;
  if (closed == null) return section;
  final children = line.paragraph.body.children;
  final rest = children.skip(line.end).toList();
  if (line.entries.length == 1) {
    // The line had only CLOSED: it goes, with its line break.
    if (rest.isEmpty) {
      // Blank lines after it stay, on the heading's line end.
      final extra = line.paragraph.trailing.replaceFirst('\n', '');
      return section.copyWith(
        headline: extra.isEmpty
            ? null
            : section.headline
                .copyWith(trailing: '${section.headline.trailing}$extra'),
        content: content.copyWith(children: content.children.skip(1).toList()),
      );
    }
    final text = rest.first as OrgPlainText;
    final after = text.content.replaceFirst(RegExp(r'^[ \t]*\n'), '');
    final paragraph = line.paragraph.copyWith(
      indent: '',
      body: line.paragraph.body.copyWith(children: [
        if (after.isNotEmpty) OrgPlainText(after),
        ...rest.skip(1),
      ]),
    );
    return section.copyWith(
        content: content.copyWith(children: [
      paragraph,
      ...content.children.skip(1),
    ]));
  }
  // Other entries stay: CLOSED goes with the spaces after it, or before it
  // when it is last.
  final head = children.take(line.end).toList();
  final i = head.indexWhere((c) => identical(c, closed));
  if (i + 1 < head.length && head[i + 1] is OrgPlainText) {
    head.removeRange(i, i + 2);
  } else if (i > 0 && head[i - 1] is OrgPlainText) {
    head.removeRange(i - 1, i + 1);
  } else {
    head.removeAt(i);
  }
  final paragraph = line.paragraph.copyWith(
      body: line.paragraph.body.copyWith(children: [...head, ...rest]));
  return section.copyWith(
      content: content.copyWith(children: [
    paragraph,
    ...content.children.skip(1),
  ]));
}
