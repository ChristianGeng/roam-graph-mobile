/// Filled paragraphs shown reflowed (#219): a single line break inside a
/// paragraph is shown as a space, as Org's export reads it, so the text
/// wraps at the screen's width. Only the parsed document shown is
/// changed; the file keeps its line breaks.
library;

import 'package:org_flutter/org_flutter.dart';

/// A line break with the spaces around it, and a `\\` before it that makes
/// it an explicit line break.
final _lineBreak = RegExp(r'(\\\\)?[ \t]*\r?\n[ \t]*');

/// [document] with the line breaks inside paragraphs, list items and
/// footnote definitions joined to a space. Kept, as in Org: empty lines
/// (they end a paragraph), a line ending with `\\`, and every line of
/// source, example and verse blocks, fixed-width lines, tables, drawers,
/// keywords and LaTeX environments, which are no paragraphs or are left
/// out here. A paragraph in a quote block is joined, as in Org.
///
/// The document keeps its sections and list items, in the same order, so
/// the quick edits, which find a node by its place, still change the
/// right one.
OrgDocument withJoinedLines(OrgDocument document) =>
    _joinIn(document) as OrgDocument;

OrgNode _joinIn(OrgNode node) => switch (node) {
      OrgDrawer() => node,
      OrgBlock(type: 'verse') => node,
      OrgParagraph() => switch (_joinedText(node.body)) {
          final body when identical(body, node.body) => node,
          final body => node.copyWith(body: body),
        },
      OrgFootnote() => switch (_joinedText(node.content)) {
          final content when identical(content, node.content) => node,
          final content => node.copyWith(content: content),
        },
      OrgListItem(:final body?) => _rebuilt(node, [
          for (final child in node.children)
            identical(child, body) ? _joinedText(body) : child,
        ]),
      OrgParentNode() => _rebuilt(node, node.children.map(_joinIn).toList()),
      _ => node,
    };

/// [node] with [children], or [node] itself when they are the same.
OrgNode _rebuilt(OrgParentNode node, List<OrgNode> children) {
  for (final (i, child) in children.indexed) {
    if (!identical(child, node.children[i])) return node.fromChildren(children);
  }
  return node;
}

/// [content], the text of one paragraph, with its line breaks joined. A
/// line break at the start or end of a piece of text is joined only when
/// the text goes on beside it (a link, emphasis, …); before or after an
/// element, such as a list inside a list item, it stays.
OrgContent _joinedText(OrgContent content) {
  final children = content.children;
  bool inline(int i) =>
      i >= 0 && i < children.length && children[i] is! OrgElement;
  final joined = <OrgNode>[
    for (final (i, child) in children.indexed)
      switch (child) {
        OrgPlainText() => _joinedPlain(child,
            joinStart: inline(i - 1), joinEnd: inline(i + 1)),
        OrgMarkup() => switch (_joinedText(child.content)) {
            final text when identical(text, child.content) => child,
            final text => child.copyWith(content: text),
          },
        OrgBracketLink(:final description?) =>
          switch (_joinedText(description)) {
            final text when identical(text, description) => child,
            final text => child.copyWith(description: text),
          },
        OrgElement() => _joinIn(child),
        _ => child,
      },
  ];
  for (final (i, child) in joined.indexed) {
    if (!identical(child, children[i])) return content.copyWith(children: joined);
  }
  return content;
}

OrgPlainText _joinedPlain(OrgPlainText text,
    {required bool joinStart, required bool joinEnd}) {
  final source = text.content;
  if (!source.contains('\n')) return text;
  final joined = source.replaceAllMapped(_lineBreak, (match) {
    final kept = match[1] != null ||
        match.start == 0 && !joinStart ||
        match.end == source.length && !joinEnd;
    return kept ? match[0]! : ' ';
  });
  return joined == source ? text : OrgPlainText(joined);
}
