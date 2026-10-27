import 'package:material_ui/material_ui.dart';

import '../graph/org_roam_parser.dart';
import '../graph/roam_graph.dart';
import '../graph_view/node_memory.dart';
import '../node_view/node_screen.dart';

/// The help pages (#62): Org files bundled with the app, linked with `id:`
/// links, shown by the node view as notes are. They form their own small
/// graph and are never part of my graph, search or AI shares.
const helpFiles = [
  'start.org',
  'graph-view.org',
  'search.org',
  'layouts.org',
  'views.org',
  'algorithms.org',
  'node-view.org',
  'capture.org',
  'ai.org',
  'images.org',
  'ai-privacy.org',
  'models.org',
  'conflicts.org',
  'settings.org',
  'install.org',
  'desktop.org',
];

/// IDs of pages that controls open directly.
const helpStart = 'roam-graph-help-start';
const helpLayouts = 'roam-graph-help-layouts';
const helpViews = 'roam-graph-help-views';

/// A help page's text, by its file name.
Future<String?> readHelpPage(AssetBundle bundle, String path) async {
  try {
    // Not cached: the pages are small, and read only when help opens.
    return await bundle.loadString('assets/help/$path', cache: false);
  } on FlutterError {
    return null;
  }
}

/// The help pages as a graph, parsed as the index parses notes.
Future<RoamGraph> loadHelpGraph(AssetBundle bundle) async =>
    RoamGraph.fromFiles([
      for (final file in helpFiles)
        parseRoamFile(file, await readHelpPage(bundle, file) ?? ''),
    ]);

/// Help pages are not remembered as the node viewed last.
class _NoMemory implements NodeMemory {
  const _NoMemory();

  @override
  Future<String?> lastNode() async => null;

  @override
  Future<void> remember(String id) async {}
}

/// Opens the help page [id], the start page by default.
Future<void> openHelp(BuildContext context, {String id = helpStart}) async {
  final bundle = DefaultAssetBundle.of(context);
  final graph = await loadHelpGraph(bundle);
  if (!context.mounted) return;
  await NodeScreen.open(
    context,
    graph: ValueNotifier(graph),
    id: graph.nodes.containsKey(id) ? id : helpStart,
    readNote: (path) => readHelpPage(bundle, path),
    nodeMemory: const _NoMemory(),
    help: true,
  );
}
