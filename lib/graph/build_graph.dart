import 'dart:isolate';

import 'org_roam_parser.dart';
import 'roam_graph.dart';

/// An org file to parse: its path relative to `roam/`, and its text.
typedef SourceFile = ({String path, String text});

/// Builds the graph from [sources] in the background.
typedef GraphBuilder = Future<RoamGraph> Function(List<SourceFile> sources);

/// Parses [sources] and builds the graph.
RoamGraph buildGraph(List<SourceFile> sources) => RoamGraph.fromFiles([
      for (final source in sources) parseRoamFile(source.path, source.text),
    ]);

/// [buildGraph] on another isolate, so parsing hundreds of files does not
/// make the screen stutter.
Future<RoamGraph> buildGraphInBackground(List<SourceFile> sources) =>
    Isolate.run(() => buildGraph(sources));
