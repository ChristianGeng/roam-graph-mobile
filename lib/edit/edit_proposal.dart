/// An edit of one note that an AI proposes (#39), and how it applies to
/// the note's file. Nothing here writes: the user reviews the diff (#38),
/// and only then is it saved (#35). A change set of several notes (#76) is
/// a list of these.
library;

import '../graph/roam_graph.dart';
import 'node_text.dart';

/// What a proposal does to its node.
enum EditMode {
  /// Adds the text at the end of the node (#36).
  append,

  /// Replaces the node's text below its head (#37).
  replace,
}

class EditProposal {
  const EditProposal({
    required this.nodeId,
    required this.mode,
    required this.text,
    this.reason = '',
  });

  final String nodeId;
  final EditMode mode;

  /// The text to add, or the node's new text below its head.
  final String text;

  /// Why the AI proposes it, shown with the diff.
  final String reason;
}

/// [text] without [node]'s head, if it starts with it: an AI or another
/// app often returns the whole note, with its property drawer and title,
/// which stay as they are (decision 10, rule 5). Text without the node's
/// `:ID:` is taken as it is.
String bodyFor(String text, RoamNode node) {
  final lines = NodeLines.find(text, node);
  if (lines == null || lines.head.isEmpty) return text;
  final hasId = RegExp('^[ \\t]*:ID:[ \\t]+${RegExp.escape(node.id)}[ \\t]*\$',
          multiLine: true, caseSensitive: false)
      .hasMatch(lines.head);
  return hasId ? lines.body : text;
}

/// The file [fileText] of [node] after [proposal]; null if the node's
/// heading is no longer in the file.
String? applyProposal(String fileText, RoamNode node, EditProposal proposal) {
  final lines = NodeLines.find(fileText, node);
  if (lines == null) return null;
  return switch (proposal.mode) {
    EditMode.append => lines.withAddition(proposal.text),
    EditMode.replace => lines.withBody(_withFinalNewline(
        bodyFor(proposal.text, node), lines)),
  };
}

/// A replaced body keeps the file's line structure: inside the file it
/// ends without a newline, so the next heading stays on its own line; at
/// the end of the file it ends with one.
String _withFinalNewline(String body, NodeLines lines) {
  final trimmed = body.replaceFirst(RegExp(r'(\r?\n)+$'), '');
  return lines.end == lines.lines.length ? '$trimmed\n' : trimmed;
}

final _idLink = RegExp(r'\[\[id:([^\]\[]+?)(?:::[^\]]*)?\](?:\[|\])');

/// The `id:` link targets in [text] that are no node of [graph]: such a
/// link would point nowhere.
List<String> unknownLinkIds(String text, RoamGraph graph) => {
      for (final match in _idLink.allMatches(text))
        if (!graph.nodes.containsKey(match.group(1)!.trim()))
          match.group(1)!.trim(),
    }.toList();
