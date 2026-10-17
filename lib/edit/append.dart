/// Adding text at the end of a node (#36), without touching what is there.
library;

import '../graph/roam_graph.dart';
import 'node_text.dart';

/// [text], the whole file of [node], with [addition] added at the end of
/// the node: for a file node at the end of the file, for a heading node at
/// the end of its subtree, before the next heading of the same or a higher
/// level. It goes after the node's last line that is not blank, so blank
/// lines before the next heading stay where they are. Null if the heading
/// of [node] is no longer in [text].
String? appendToNode(String text, RoamNode node, String addition) =>
    NodeLines.find(text, node)?.withAddition(addition);
