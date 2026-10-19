/// Notes as text for an AI app on the device (#41): the Claude Android
/// app reads text shared to it, but cannot read device folders.
///
/// Pure Dart (no Flutter), like `roam_graph.dart`.
library;

import 'package:org_parser/org_parser.dart';

import '../ai/ai_visibility.dart';
import '../capture/new_node.dart';
import 'backlinks.dart';
import 'roam_graph.dart';

/// The longest text the app shares at once: Android hands shared text to
/// the other app in one transaction of about 1 MB, which also holds the
/// rest of the intent.
const maxShareLength = 400000;

/// The Org text of [node] in [fileText], found as the node view finds it
/// (#8): the whole file for a file node; for a heading node the section
/// with the node's `:ID:`, parsed with org_parser, heading and subtree.
/// Null if the file no longer has that heading: the index is older than
/// the file, and the line it holds may now be another note's.
String? nodeText(RoamNode node, String fileText) {
  if (node.isFile) return fileText;
  final section = OrgDocument.parse(fileText).sectionWithId(node.id);
  return section is OrgSection ? section.toMarkup().trimRight() : null;
}

/// Nodes of [graph] with their texts, for an AI app (#41): each node's
/// ID, title, tags and file, the nodes it links to and the nodes linking
/// to it (as Org links), and its Org text ([nodeText]). [files] has the
/// text of each node's file; null when it could not be read.
///
/// [files] must hold no node [visibility] hides; nodes it hides are left
/// out of the link lists, and their headings and titles out of the texts
/// (#57). A node whose file now hides it (the index is older,
/// [AiVisibility.hidesInText]) is left out, as a hidden node; callers say
/// so. "Links to" lists only links that are in the text shared, so not
/// those under a hidden heading.
String nodesForAi(
  RoamGraph full,
  List<(RoamNode, String?)> files, {
  AiVisibility visibility = AiVisibility.none,
}) {
  assert(!files.any((f) => visibility.hides(f.$1)), 'a hidden node is shared');
  final graph = visibility.visibleGraph(full);
  final hiddenIds = visibility.hiddenIds(full);
  String ref(String id) {
    final title = graph.nodes[id]?.displayTitle;
    return title == null
        ? '[[${orgLinkEscape('id:$id')}]]'
        : orgLink(id, _oneLine(title));
  }

  final texts = [
    for (final (node, file) in files)
      if (file == null || !visibility.hidesInText(node, file))
        (
          node,
          file,
          switch (file == null ? null : nodeText(node, file)) {
            final text? => visibility.filterText(text, hiddenIds),
            null => null,
          },
        ),
  ];

  final text = StringBuffer()
    ..writeln(texts.length == 1
        ? '# A note from my org-roam graph'
        : '# ${texts.length} notes from my org-roam graph')
    ..writeln()
    ..writeln('Shared from the app Roam Graph. The text is Org mode. To '
        'link to a note when you write one for me, use its ID: '
        '[[id:<ID>][<title>]].');
  for (final (node, file, body) in texts) {
    // Not a link only under a hidden heading.
    final inText =
        body == null || visibility.hiddenTags.isEmpty ? null : idLinkTargets(body);
    final linksTo = <String>{
      for (final link in graph.links)
        if (link.source == node.id && link.dest != node.id)
          if (inText == null || inText.contains(link.dest)) link.dest,
    };
    final linkedFrom = <String>{
      for (final b in backlinksOf(graph, node.id))
        if (b.source.id != node.id) b.source.id,
    };
    text
      ..writeln()
      ..writeln('## ${_oneLine(node.displayTitle)}')
      ..writeln()
      ..writeln('- ID: ${node.id}')
      ..writeln('- File: ${node.file}');
    if (node.tags.isNotEmpty) text.writeln('- Tags: ${node.tags.join(' ')}');
    text
      ..writeln('- Links to: ${linksTo.isEmpty ? 'none' : linksTo.map(ref).join(', ')}')
      ..writeln('- Linked from: '
          '${linkedFrom.isEmpty ? 'none' : linkedFrom.map(ref).join(', ')}')
      ..writeln();
    if (file == null) {
      text.writeln('(The file could not be read.)');
    } else if (body == null) {
      text.writeln('(The heading is no longer in ${node.file}; the file '
          'changed since the app read it.)');
    } else {
      // A fence longer than any run of backticks in the text.
      final longest = RegExp('`+')
          .allMatches(body)
          .fold(0, (m, match) => match.group(0)!.length > m ? match.group(0)!.length : m);
      final fence = '`' * (longest < 3 ? 3 : longest + 1);
      text
        ..writeln('${fence}org')
        ..writeln(body.trimRight())
        ..writeln(fence);
    }
  }
  return text.toString();
}

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
