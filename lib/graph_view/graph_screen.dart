import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_settings.dart';
import '../capture/capture_screen.dart';
import '../capture/share_inbox.dart';
import '../graph/ai_share.dart';
import '../graph/graph_algorithms.dart';
import '../graph/graph_layout.dart';
import '../graph/graph_scope.dart';
import '../graph/roam_graph.dart';
import '../node_view/node_screen.dart';
import '../search/search_screen.dart';
import 'node_memory.dart';
import '../node_view/note_images.dart';

/// Computes a layout; by default on another isolate.
typedef LayoutFunction = Future<GraphLayout> Function(
    DrawnGraph graph, LayoutKind kind);

Future<GraphLayout> layoutOnIsolate(DrawnGraph graph, LayoutKind kind) =>
    Isolate.run(() => layoutGraph(graph, kind));

/// Computes the graph views' results (#7); by default on another isolate,
/// so Louvain on a large graph does not stop the screen.
typedef AlgorithmsFunction = Future<AlgorithmResults> Function(
    AlgorithmGraph graph);

Future<AlgorithmResults> algorithmsOnIsolate(AlgorithmGraph graph) =>
    Isolate.run(() => computeAlgorithmResults(graph));

/// Whether a screen of [size] shows the graph and the node view side by
/// side (#16): a tablet (shortest side at least 600, Material's medium
/// width) held in landscape. Phones, and tablets in portrait, show one at
/// a time.
bool isTwoPane(Size size) => size.shortestSide >= 600 && size.width > size.height;

/// Radius of a node's dot, in logical pixels at scale 1.
const _nodeRadius = 7.0;

/// Below this scale the labels are too small to read and are not drawn.
const _labelScale = 0.45;

/// How far from a plain node's centre a tap opens it, in graph
/// coordinates at [scale]: the dot, plus 16 logical pixels on the screen
/// for the finger. An enlarged dot (#7) reaches as far beyond its edge.
double tapReach(double scale) => _nodeRadius + 16 / scale;

/// The node graph in the style of `org-roam-graph` (#6): nodes labelled
/// with their titles, an edge for each pair of nodes with an `id:` link.
///
/// Starts with the whole graph, centred on the node opened last, or on the
/// node with the most links. A tap on a node centres the graph on it and
/// opens it in the node view (#8), whose "Show in graph" comes back here.
///
/// [graph] changes when the index is updated, for example when the app
/// comes back to the foreground after Syncthing brought new notes. The
/// screen then draws the new graph, and keeps the view if nothing it shows
/// has changed.
class GraphScreen extends StatefulWidget {
  const GraphScreen({
    super.key,
    required this.graph,
    required this.readNote,
    this.files,
    this.openInOrgro,
    this.writer,
    this.nodeMemory = const FileNodeMemory(),
    this.computeLayout = layoutOnIsolate,
    this.computeAlgorithms = algorithmsOnIsolate,
    this.shareText = shareTextOut,
  });

  final ValueListenable<RoamGraph> graph;

  /// Reads a note for the node view.
  final NoteReader readNote;

  /// The folder's other files, for images in notes (#46); without
  /// them, image links are shown as text.
  final NoteFiles? files;

  /// Opens a note in Orgro, for the node view.
  final NoteOpener? openInOrgro;

  /// Writes new notes (#11); without it, there is no "New node" button.
  final NoteWriter? writer;
  final NodeMemory nodeMemory;
  final LayoutFunction computeLayout;
  final AlgorithmsFunction computeAlgorithms;

  /// Sends text to another app; tests replace it.
  final TextSharer shareText;

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

/// The choices of the "Show" menu, all around the centre node but
/// [whole].
enum _ScopeChoice {
  whole('Whole graph'),
  connected('Connected part'),
  steps1('Neighbourhood: 1 step'),
  steps2('Neighbourhood: 2 steps'),
  steps3('Neighbourhood: 3 steps');

  const _ScopeChoice(this.label);

  final String label;

  GraphScope scope(String centre) => switch (this) {
        whole => const WholeGraph(),
        connected => ConnectedPart(centre),
        steps1 => Neighbourhood(centre, 1),
        steps2 => Neighbourhood(centre, 2),
        steps3 => Neighbourhood(centre, 3),
      };
}

/// The actions of the graph's "More" menu.
enum _MoreAction {
  centre,
  circo,
  force,
  share,
  aiSettings;

  static _MoreAction layoutOf(LayoutKind kind) =>
      kind == LayoutKind.circo ? circo : force;
}

/// The graph views of #7: what the drawing shows about each node.
enum _GraphView {
  plain('Plain'),
  communities('Communities'),
  pageRank('Importance: PageRank'),
  links('Importance: number of links'),
  path('Shortest path');

  const _GraphView(this.label);

  final String label;
}

/// Colours for the largest communities; smaller ones stay plain.
const _communityColours = [
  Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF43A047), //
  Color(0xFFFB8C00), Color(0xFF8E24AA), Color(0xFF00897B),
  Color(0xFFD81B60), Color(0xFF6D4C41), Color(0xFF3949AB),
  Color(0xFFC0CA33),
];

/// The graph algorithms for one graph, on the whole graph, as the MCP
/// server computes them. [results] arrive from another isolate when a
/// view first needs them.
class _Algorithms {
  _Algorithms(this.source) : graph = AlgorithmGraph.fromRoam(source);

  final RoamGraph source;
  final AlgorithmGraph graph;
  AlgorithmResults? results;
  bool computing = false;
}

class _GraphScreenState extends State<GraphScreen> {
  final _transform = TransformationController();
  _ScopeChoice _choice = _ScopeChoice.whole;
  LayoutKind _kind = LayoutKind.circo;

  /// The node the view centres on: the one tapped last.
  String? _centre;

  /// The node the shown part of the graph is around.
  String? _scopeCentre;
  DrawnGraph? _drawn;
  GraphLayout? _layout;
  _Drawing? _drawing;
  Size _viewport = Size.zero;

  /// The nodes selected so far, the current one ([_centre]) last, for the
  /// side pane's Back. Empty until a second node is selected. The side
  /// pane always shows [_centre].
  final _history = <String>[];

  _GraphView _view = _GraphView.plain;
  _Algorithms? _algorithmsCache;

  /// The node the shortest path leads to, from [_centre].
  String? _pathTarget;

  _Algorithms get _algorithms {
    final cached = _algorithmsCache;
    if (cached != null && identical(cached.source, _graph)) return cached;
    return _algorithmsCache = _Algorithms(_graph);
  }

  /// The results the current view needs, or null while they are computed
  /// (which starts here).
  AlgorithmResults? _results() {
    final algorithms = _algorithms;
    final results = algorithms.results;
    if (results != null || algorithms.computing) return results;
    algorithms.computing = true;
    widget.computeAlgorithms(algorithms.graph).then((results) {
      algorithms.results = results;
      if (mounted && identical(_algorithmsCache, algorithms)) setState(() {});
    });
    return null;
  }

  /// The overlay of the last build, and what it was made from, so the
  /// drawing keeps its edges while the view moves.
  _ViewOverlay? _overlayCache;
  Object? _overlayKey;

  /// Layouts computed so far, so switching back is immediate.
  final _layouts = <(GraphScope, LayoutKind), GraphLayout>{};

  /// Counts layout requests; only the latest may be shown.
  int _generation = 0;

  RoamGraph get _graph => widget.graph.value;

  @override
  void initState() {
    super.initState();
    widget.graph.addListener(_graphChanged);
    _start();
  }

  @override
  void didUpdateWidget(GraphScreen old) {
    super.didUpdateWidget(old);
    if (old.graph != widget.graph) {
      old.graph.removeListener(_graphChanged);
      widget.graph.addListener(_graphChanged);
      _graphChanged();
    }
  }

  @override
  void dispose() {
    widget.graph.removeListener(_graphChanged);
    _transform.dispose();
    _drawing?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final remembered = await widget.nodeMemory.lastNode();
    if (!mounted) return;
    _centre = _graph.nodes.containsKey(remembered)
        ? remembered
        : _mostLinked(_graph);
    await _update();
  }

  /// Draws the new graph, if it changes what is shown. A centre node that
  /// is gone is replaced by the node with the most links.
  void _graphChanged() {
    if (!mounted) return;
    final graph = _graph;
    // Nodes that are gone leave the history; the centre falls back to the
    // node selected before it, or to the node with the most links.
    _history.retainWhere(graph.nodes.containsKey);
    for (var i = _history.length - 1; i > 0; i--) {
      if (_history[i] == _history[i - 1]) _history.removeAt(i);
    }
    if (!graph.nodes.containsKey(_centre)) {
      _centre = _history.lastOrNull ?? _mostLinked(graph);
    }
    final drawn = _drawn;
    final centre = _centre;
    if (centre != null &&
        drawn != null &&
        centre == _scopeCentre &&
        _sameDrawing(drawn, DrawnGraph.of(graph, _choice.scope(centre)))) {
      // The same nodes, labels and edges: keep the layout and the view.
      setState(() {});
      return;
    }
    _layouts.clear();
    if (centre == null) {
      ++_generation;
      setState(() {
        _drawn = null;
        _layout = null;
        _drawing?.dispose();
        _drawing = null;
      });
      return;
    }
    _update();
  }

  /// Draws the current scope with the current layout.
  Future<void> _update() async {
    final centre = _centre;
    if (centre == null) return;
    final generation = ++_generation;
    final scope = _choice.scope(centre);
    final drawn = DrawnGraph.of(_graph, scope);
    setState(() {
      _scopeCentre = centre;
      _drawn = drawn;
      _drawing?.dispose();
      _layout = null;
      _drawing = null;
    });
    final key = (scope, _kind);
    final layout =
        _layouts[key] ?? await widget.computeLayout(drawn, _kind);
    if (!mounted || generation != _generation) return;
    _layouts[key] = layout;
    setState(() {
      _layout = layout;
      _drawing?.dispose();
      _drawing = _Drawing(drawn, layout);
    });
    _centreView();
  }

  /// Moves the view so that the centre node is in the middle. The whole
  /// graph is shown at scale 1, so the labels are readable; a part of it
  /// at the scale that shows all of it.
  void _centreView() {
    final layout = _layout;
    final at = layout?.positions[_centre];
    if (layout == null || at == null || _viewport.isEmpty) return;
    var scale = 1.0;
    if (_choice != _ScopeChoice.whole) {
      var reach = 0.0;
      for (final p in layout.positions.values) {
        reach = max(reach, p.distanceTo(at));
      }
      scale = (_viewport.shortestSide / 2 / (reach + layoutMargin))
          .clamp(0.1, 1.5);
    }
    final dx = _viewport.width / 2 - scale * at.x;
    final dy = _viewport.height / 2 - scale * at.y;
    // Column-major: scale, then move.
    _transform.value = Matrix4(
      scale, 0, 0, 0, //
      0, scale, 0, 0, //
      0, 0, 1, 0, //
      dx, dy, 0, 1,
    );
  }

  void _tap(TapUpDetails details) {
    final drawing = _drawing;
    if (drawing == null) return;
    final scale = _transform.value.getMaxScaleOnAxis();
    final id = drawing.nodeAt(
        details.localPosition, tapReach(scale) - _nodeRadius, _overlay().sizes);
    if (id == null) return;
    if (_view == _GraphView.path) {
      // The tap chooses where the path leads.
      setState(() => _pathTarget = id);
      return;
    }
    final node = _graph.nodes[id];
    if (node == null) return;
    widget.nodeMemory.remember(id);
    _openNode(context, id);
  }

  /// What the current view adds to the drawing, the same object while
  /// nothing it depends on changes.
  _ViewOverlay _overlay() {
    // _algorithms is new for each graph from the index, so a new graph
    // gives a new overlay, also in the path view, which needs no results.
    final key = (_view, _algorithms, _algorithms.results, _centre, _pathTarget);
    final cached = _overlayCache;
    if (cached != null && _overlayKey == key) return cached;
    _overlayKey = key;
    return _overlayCache = _computeOverlay();
  }

  _ViewOverlay _computeOverlay() {
    final results = _view == _GraphView.plain || _view == _GraphView.path
        ? null
        : _results();
    switch (_view) {
      case _GraphView.plain:
        return const _ViewOverlay();
      case _GraphView.communities:
        if (results == null) return const _ViewOverlay();
        final communities = results.communities;
        final sizes = <int, int>{};
        for (final c in communities.values) {
          sizes[c] = (sizes[c] ?? 0) + 1;
        }
        final largest = sizes.keys.where((c) => sizes[c]! > 1).toList()
          ..sort((a, b) => sizes[b]!.compareTo(sizes[a]!));
        final colourOf = {
          for (var i = 0; i < largest.length && i < _communityColours.length; i++)
            largest[i]: _communityColours[i],
        };
        return _ViewOverlay(colours: {
          for (final MapEntry(:key, :value) in communities.entries)
            key: ?colourOf[value],
        });
      case _GraphView.pageRank:
        if (results == null) return const _ViewOverlay();
        return _ViewOverlay(sizes: _relativeSizes(results.ranks));
      case _GraphView.links:
        if (results == null) return const _ViewOverlay();
        return _ViewOverlay(sizes: _relativeSizes(results.links));
      case _GraphView.path:
        final centre = _centre, target = _pathTarget;
        if (centre == null || target == null) return const _ViewOverlay();
        return _ViewOverlay(
            path: shortestPath(_algorithms.graph, centre, target));
    }
  }

  /// What the current view shows, in a line under the bar; null for none.
  String? _viewNote() {
    String title(String? id) =>
        _graph.nodes[id]?.displayTitle ?? (id == null ? '' : 'id:$id');
    switch (_view) {
      case _GraphView.plain:
        return null;
      case _GraphView.communities ||
              _GraphView.pageRank ||
              _GraphView.links
          when _results() == null:
        return 'Computing…';
      case _GraphView.communities:
        final count = _results()!.communities.values.toSet().length;
        return '$count communities (Louvain). Colours show the '
            '${_communityColours.length} largest.';
      case _GraphView.pageRank:
        return 'Larger nodes have a higher PageRank.';
      case _GraphView.links:
        return 'Larger nodes have more links, to and from them.';
      case _GraphView.path:
        final centre = _centre, target = _pathTarget;
        if (centre == null) return null;
        if (target == null || target == centre) {
          return 'Path from ${title(centre)}: tap the node it leads to.';
        }
        final path = shortestPath(_algorithms.graph, centre, target);
        if (path == null) {
          return 'No path from ${title(centre)} to ${title(target)} within '
              '$maxPathLinks links, following links in their direction.';
        }
        final links = path.length - 1;
        final positions = _layout?.positions ?? const {};
        final hidden = path.any((id) => !positions.containsKey(id));
        return '${title(centre)} to ${title(target)}: '
            '$links ${links == 1 ? 'link' : 'links'}.'
            '${hidden ? ' Part of it is outside this part of the graph; '
                'show the whole graph to see all of it.' : ''}';
    }
  }

  /// Makes [id] the selected node: the graph marks it, and the side pane
  /// shows it. The view does not move.
  void _select(String id) {
    final previous = _centre;
    if (previous == id) return;
    if (_history.isEmpty && previous != null) _history.add(previous);
    _history.add(id);
    // Back goes far enough; older entries are dropped.
    if (_history.length > 100) _history.removeAt(0);
    _centre = id;
  }

  /// Opens the node [id] the way the screen is now: in the side pane on a
  /// tablet in landscape, on a new page otherwise. Decided when called, so
  /// a search opened before the device turned follows the new layout.
  void _openNode(BuildContext _, String id) {
    if (!mounted || !_graph.nodes.containsKey(id)) return;
    if (isTwoPane(MediaQuery.sizeOf(context))) {
      _showInPane(id);
    } else {
      setState(() => _select(id));
      _openPage(id);
    }
  }

  /// Opens the node view of [id] on a new page.
  void _openPage(String id) => NodeScreen.open(
        context,
        graph: widget.graph,
        id: id,
        readNote: widget.readNote,
        files: widget.files,
        nodeMemory: widget.nodeMemory,
        onShowInGraph: _showInGraph,
        openInOrgro: widget.openInOrgro,
        writer: widget.writer,
        shareText: widget.shareText,
      );

  /// Shows [id] in the side pane, and marks it in the graph without moving
  /// the view. A node outside the part of the graph drawn around another
  /// node gets that part drawn around it.
  void _showInPane(String id) {
    setState(() => _select(id));
    _drawAroundCentreIfMissing();
  }

  void _paneBack() {
    setState(() {
      _history.removeLast();
      _centre = _history.last;
      if (_history.length == 1) _history.clear();
    });
    _drawAroundCentreIfMissing();
  }

  void _drawAroundCentreIfMissing() {
    final layout = _layout;
    if (_choice != _ScopeChoice.whole &&
        layout != null &&
        !layout.positions.containsKey(_centre)) {
      _update();
    }
  }

  /// Returns from the node views to the graph, centred on the node [id].
  /// A part of the graph around another node is drawn again around [id].
  void _showInGraph(BuildContext nodeContext, String id) {
    final route = ModalRoute.of(context);
    Navigator.of(nodeContext).popUntil((r) => r == route);
    if (!mounted || !_graph.nodes.containsKey(id)) return;
    setState(() => _select(id));
    if (_choice == _ScopeChoice.whole) {
      _centreView();
    } else {
      _update();
    }
  }

  /// Creates a new node (#11) and opens it. It links to the selected node,
  /// the current node of decision 10 (#12), unless switched off.
  Future<void> _capture(NoteWriter writer) async {
    final selected = _graph.nodes[_centre];
    final id = await CaptureScreen.open(
      context,
      writer,
      linkTo: selected == null
          ? null
          : (id: selected.id, title: selected.displayTitle),
    );
    if (id == null || !mounted) return;
    widget.nodeMemory.remember(id);
    _openNode(context, id);
  }

  void _more(_MoreAction action) {
    switch (action) {
      case _MoreAction.centre:
        _centreView();
      case _MoreAction.share:
        _shareGraph();
      case _MoreAction.aiSettings:
        AiSettingsScreen.open(context);
      case _MoreAction.circo || _MoreAction.force:
        _kind = action == _MoreAction.circo ? LayoutKind.circo : LayoutKind.force;
        _update();
    }
  }

  /// Shares the graph's connectivity with an AI app (#40), and says so if
  /// Android cannot.
  Future<void> _shareGraph() async {
    // The saved settings, once loaded, so no saved hidden tag is missed.
    final settings = await AiSettingsScope.current(context);
    if (!mounted) return;
    final text = graphForAi(_graph, visibility: settings.visibility);
    // Android hands shared text over in one transaction, limited to about
    // 1 MB; stay well below it.
    if (text.length > 400000) {
      _tellUser('The graph is too large to share at once '
          '(${text.length ~/ 1000} KB).');
      return;
    }
    try {
      await widget.shareText(text, subject: 'My org-roam graph');
    } on PlatformException catch (e) {
      _tellUser('Could not share the graph: ${e.message ?? e.code}');
    }
  }

  void _tellUser(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _showView(_GraphView view) => setState(() {
        _view = view;
        _pathTarget = null;
      });

  void _show(_ScopeChoice choice) {
    _choice = choice;
    _update();
  }

  @override
  Widget build(BuildContext context) {
    final centreTitle = _graph.nodes[_scopeCentre]?.displayTitle ?? '';
    final twoPane = isTwoPane(MediaQuery.sizeOf(context));
    final graph = LayoutBuilder(
      builder: (context, constraints) {
        // At the start, and when the graph's part of the screen changes
        // width (the side pane appears, the tablet turns), centre again.
        // Not for a change in height alone, so the view stays when the
        // keyboard of the search page opens and closes.
        final size = constraints.biggest;
        if (_viewport.isEmpty || _viewport.width != size.width) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _centreView());
        }
        _viewport = size;
        return _body(context);
      },
    );
    final paneId = _centre;
    final note = _viewNote();
    final writer = widget.writer;
    return Scaffold(
      floatingActionButton: writer == null
          ? null
          : FloatingActionButton(
              tooltip: 'New node',
              onPressed: () => _capture(writer),
              child: const Icon(Icons.add),
            ),
      // The graph has no text field; the keyboard of the search page above
      // must not resize it.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_choice.label),
            if (_choice != _ScopeChoice.whole)
              Text(
                centreTitle,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => SearchScreen.open(
              context,
              graph: widget.graph,
              readNote: widget.readNote,
              files: widget.files,
              nodeMemory: widget.nodeMemory,
              onShowInGraph: _showInGraph,
              openInOrgro: widget.openInOrgro,
              onOpenNode: _openNode,
              writer: widget.writer,
              shareText: widget.shareText,
            ),
          ),
          // The quick switch to the node view, on one screen at a time.
          if (!twoPane && _centre != null)
            IconButton(
              tooltip: 'Open node',
              icon: const Icon(Icons.article_outlined),
              onPressed: () {
                widget.nodeMemory.remember(_centre!);
                _openPage(_centre!);
              },
            ),
          PopupMenuButton<_ScopeChoice>(
            tooltip: 'Show',
            icon: const Icon(Icons.hub_outlined),
            initialValue: _choice,
            onSelected: _show,
            itemBuilder: (context) => [
              for (final choice in _ScopeChoice.values)
                PopupMenuItem(value: choice, child: Text(choice.label)),
            ],
          ),
          PopupMenuButton<_GraphView>(
            tooltip: 'View',
            icon: const Icon(Icons.insights_outlined),
            initialValue: _view,
            onSelected: _showView,
            itemBuilder: (context) => [
              for (final view in _GraphView.values)
                PopupMenuItem(value: view, child: Text(view.label)),
            ],
          ),
          // Less used actions, so the bar fits a phone held upright.
          PopupMenuButton<_MoreAction>(
            tooltip: 'More',
            onSelected: _more,
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: _MoreAction.centre, child: Text('Centre')),
              for (final kind in LayoutKind.values)
                CheckedPopupMenuItem(
                  value: _MoreAction.layoutOf(kind),
                  checked: kind == _kind,
                  child: Text(kind.label),
                ),
              PopupMenuItem(
                value: _MoreAction.share,
                enabled: _graph.nodes.isNotEmpty,
                child: const Text('Share graph with AI'),
              ),
              const PopupMenuItem(
                value: _MoreAction.aiSettings,
                child: Text('AI settings'),
              ),
            ],
          ),
        ],
        bottom: note == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      note,
                      key: const ValueKey('view-note'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
      ),
      body: !twoPane || paneId == null
          ? graph
          : Row(
              children: [
                Expanded(flex: 3, child: graph),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 2,
                  child: NodeScreen(
                    key: const ValueKey('node-pane'),
                    graph: widget.graph,
                    id: paneId,
                    readNote: widget.readNote,
                    files: widget.files,
                    nodeMemory: widget.nodeMemory,
                    onShowInGraph: _showInGraph,
                    openInOrgro: widget.openInOrgro,
                    onOpenNode: _openNode,
                    onBack: _history.length > 1 ? _paneBack : null,
                    writer: widget.writer,
                    shareText: widget.shareText,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _body(BuildContext context) {
    if (_graph.nodes.isEmpty) {
      return const Center(child: Text('There are no nodes in roam/.'));
    }
    final drawing = _drawing;
    final layout = _layout;
    if (drawing == null || layout == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final colors = Theme.of(context).colorScheme;
    return InteractiveViewer(
      transformationController: _transform,
      constrained: false,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      minScale: 0.02,
      maxScale: 4,
      child: GestureDetector(
        key: const ValueKey('graph-canvas'),
        onTapUp: _tap,
        child: CustomPaint(
          size: Size(layout.width, layout.height),
          painter: _GraphPainter(
            drawing: drawing,
            centre: _centre,
            transform: _transform,
            viewport: _viewport,
            colors: colors,
            textStyle: Theme.of(context).textTheme.labelMedium!,
            overlay: _overlay(),
          ),
        ),
      ),
    );
  }
}

/// Whether [a] and [b] have the same nodes, labels and edges, in order.
bool _sameDrawing(DrawnGraph a, DrawnGraph b) =>
    listEquals([for (final n in a.nodes) (n.id, n.label)],
        [for (final n in b.nodes) (n.id, n.label)]) &&
    listEquals(a.edges, b.edges);

/// The node with the most links, in both directions; the first one of
/// several. Null for a graph without nodes.
String? _mostLinked(RoamGraph graph) {
  final count = <String, int>{};
  for (final link in graph.links) {
    count[link.source] = (count[link.source] ?? 0) + 1;
    count[link.dest] = (count[link.dest] ?? 0) + 1;
  }
  String? best;
  for (final id in graph.nodes.keys) {
    if (best == null || (count[id] ?? 0) > (count[best] ?? 0)) best = id;
  }
  return best;
}

/// What the painter needs of a layout, prepared once: the edges as one
/// path, and the labels laid out once.
class _Drawing {
  _Drawing(this.drawn, this.layout);

  final DrawnGraph drawn;
  final GraphLayout layout;

  Path? _edges;
  Map<String, double>? _edgeSizes;

  /// The edges as one path, for dots of [sizes] (relative radii; plain when
  /// null): from the edge of one dot to the edge of the other, with an
  /// arrow head at the target, as Graphviz draws a digraph. Built again
  /// only for other sizes.
  Path edges(Map<String, double>? sizes) {
    final cached = _edges;
    if (cached != null && identical(_edgeSizes, sizes)) return cached;
    final edges = Path();
    double radius(String id) => _nodeRadius * (sizes?[id] ?? 1);
    for (final (:source, :dest) in drawn.edges) {
      if (source == dest) continue;
      final from = position(source), to = position(dest);
      final along = to - from;
      final length = along.distance;
      if (length <= radius(source) + radius(dest)) continue;
      final unit = along / length;
      final start = from + unit * radius(source);
      final end = to - unit * radius(dest);
      edges
        ..moveTo(start.dx, start.dy)
        ..lineTo(end.dx, end.dy);
      final side = Offset(-unit.dy, unit.dx) * 3.5;
      final back = end - unit * 9;
      edges
        ..moveTo((back + side).dx, (back + side).dy)
        ..lineTo(end.dx, end.dy)
        ..lineTo((back - side).dx, (back - side).dy);
    }
    _edgeSizes = sizes;
    return _edges = edges;
  }

  /// Labels by node ID, laid out on first use.
  final labels = <String, TextPainter>{};
  TextStyle? labelStyle;

  Offset position(String id) {
    final p = layout.positions[id]!;
    return Offset(p.x, p.y);
  }

  void dispose() {
    for (final painter in labels.values) {
      painter.dispose();
    }
  }

  /// The node whose dot is nearest to [point], if [point] is on the dot
  /// or less than [margin] beyond its edge. [sizes] are the dots' relative
  /// radii, plain when null.
  String? nodeAt(Offset point, double margin, Map<String, double>? sizes) {
    String? best;
    var bestDistance = margin;
    for (final node in drawn.nodes) {
      final radius = _nodeRadius * (sizes?[node.id] ?? 1);
      final distance = (position(node.id) - point).distance - radius;
      if (distance < bestDistance) {
        best = node.id;
        bestDistance = distance;
      }
    }
    return best;
  }

  TextPainter label(DrawnNode node, TextStyle style) {
    if (labelStyle != style) {
      dispose();
      labels.clear();
      labelStyle = style;
    }
    return labels.putIfAbsent(
      node.id,
      () => TextPainter(
        text: TextSpan(text: node.label, style: style),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: 160),
    );
  }
}

/// Paints the graph. Repaints when the view moves, to draw only the labels
/// that are on screen and large enough to read.
class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required _Drawing drawing,
    required this.centre,
    required this.transform,
    required this.viewport,
    required this.colors,
    required this.textStyle,
    this.overlay = const _ViewOverlay(),
  })  : _drawing = drawing,
        super(repaint: transform);

  final _Drawing _drawing;
  final String? centre;
  final _ViewOverlay overlay;
  final TransformationController transform;
  final Size viewport;
  final ColorScheme colors;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final drawing = _drawing;
    final matrix = transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final visible = MatrixUtils.inverseTransformRect(
      matrix,
      Offset.zero & viewport,
    ).inflate(100);

    canvas.drawPath(
      drawing.edges(overlay.sizes),
      Paint()
        ..style = PaintingStyle.stroke
        // 0 is one physical pixel at every scale.
        ..strokeWidth = 0
        ..color = colors.outline,
    );
    final centre = this.centre;
    if (centre != null && drawing.drawn.neighbours.containsKey(centre)) {
      final at = drawing.position(centre);
      final highlight = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colors.primary;
      for (final other in drawing.drawn.neighbours[centre]!) {
        canvas.drawLine(at, drawing.position(other), highlight);
      }
    }
    final path = overlay.path;
    if (path != null) {
      final pathPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = colors.tertiary;
      for (var i = 0; i + 1 < path.length; i++) {
        if (!drawing.layout.positions.containsKey(path[i]) ||
            !drawing.layout.positions.containsKey(path[i + 1])) {
          continue;
        }
        canvas.drawLine(drawing.position(path[i]),
            drawing.position(path[i + 1]), pathPaint);
      }
    }

    final fill = Paint()..color = colors.secondary;
    final missing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = colors.outline;
    final centreFill = Paint()..color = colors.primary;
    final showLabels = scale >= _labelScale;
    final style = textStyle.copyWith(color: colors.onSurface);
    final onPath = overlay.path?.toSet() ?? const <String>{};
    final pathRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = colors.tertiary;
    for (final node in drawing.drawn.nodes) {
      final at = drawing.position(node.id);
      if (!visible.contains(at)) continue;
      final radius = _nodeRadius * (overlay.sizes?[node.id] ?? 1);
      final colour = overlay.colours?[node.id];
      if (node.id == centre) {
        // The selected node keeps its community colour, with a ring.
        final selected = max(radius, _nodeRadius * 1.6);
        canvas.drawCircle(at, selected,
            colour == null ? centreFill : (Paint()..color = colour));
        if (colour != null) {
          canvas.drawCircle(
              at,
              selected + 2,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3
                ..color = colors.primary);
        }
      } else if (node.isMissing) {
        canvas.drawCircle(at, radius, missing);
      } else {
        canvas.drawCircle(
            at, radius, colour == null ? fill : (Paint()..color = colour));
      }
      if (onPath.contains(node.id)) {
        canvas.drawCircle(at, max(radius, _nodeRadius * 1.6) + 3, pathRing);
      }
      if (showLabels) {
        final label = drawing.label(node, style);
        label.paint(
          canvas,
          at + Offset(-label.width / 2, _nodeRadius * 1.6 + 2),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old._drawing != _drawing ||
      old.centre != centre ||
      old.viewport != viewport ||
      old.colors != colors ||
      old.textStyle != textStyle ||
      old.overlay != overlay;
}

/// [values] as node sizes from 0.6 to 3 times the plain size, by the
/// square root, so the area grows with the value.
Map<String, double> _relativeSizes(Map<String, num> values) {
  final largest = values.values.fold<num>(0, max);
  if (largest <= 0) return const {};
  return {
    for (final MapEntry(:key, :value) in values.entries)
      key: 0.6 + 2.4 * sqrt(value / largest),
  };
}

/// What a graph view (#7) adds to the drawing: a colour and a size for
/// each node, and a path. Missing entries keep the plain drawing.
class _ViewOverlay {
  const _ViewOverlay({this.colours, this.sizes, this.path});

  final Map<String, Color>? colours;

  /// Radius of each node, relative to the plain radius.
  final Map<String, double>? sizes;
  final List<String>? path;
}
