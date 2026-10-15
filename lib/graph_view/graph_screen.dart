import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../graph/graph_layout.dart';
import '../graph/graph_scope.dart';
import '../graph/roam_graph.dart';
import '../node_view/node_screen.dart';
import '../search/search_screen.dart';
import 'node_memory.dart';

/// Computes a layout; by default on another isolate.
typedef LayoutFunction = Future<GraphLayout> Function(
    DrawnGraph graph, LayoutKind kind);

Future<GraphLayout> layoutOnIsolate(DrawnGraph graph, LayoutKind kind) =>
    Isolate.run(() => layoutGraph(graph, kind));

/// Whether a screen of [size] shows the graph and the node view side by
/// side (#16): a tablet (shortest side at least 600, Material's medium
/// width) held in landscape. Phones, and tablets in portrait, show one at
/// a time.
bool isTwoPane(Size size) => size.shortestSide >= 600 && size.width > size.height;

/// Radius of a node's dot, in logical pixels at scale 1.
const _nodeRadius = 7.0;

/// Below this scale the labels are too small to read and are not drawn.
const _labelScale = 0.45;

/// How far from a node's centre a tap opens it, in graph coordinates at
/// [scale]: the dot, plus 16 logical pixels on the screen for the finger.
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
    this.openInOrgro,
    this.nodeMemory = const FileNodeMemory(),
    this.computeLayout = layoutOnIsolate,
  });

  final ValueListenable<RoamGraph> graph;

  /// Reads a note for the node view.
  final NoteReader readNote;

  /// Opens a note in Orgro, for the node view.
  final NoteOpener? openInOrgro;
  final NodeMemory nodeMemory;
  final LayoutFunction computeLayout;

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
    final id = drawing.nodeAt(details.localPosition, tapReach(scale));
    if (id == null) return;
    final node = _graph.nodes[id];
    if (node == null) return;
    widget.nodeMemory.remember(id);
    _openNode(context, id);
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
        nodeMemory: widget.nodeMemory,
        onShowInGraph: _showInGraph,
        openInOrgro: widget.openInOrgro,
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
    return Scaffold(
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
              nodeMemory: widget.nodeMemory,
              onShowInGraph: _showInGraph,
              openInOrgro: widget.openInOrgro,
              onOpenNode: _openNode,
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
          IconButton(
            tooltip: 'Centre',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _centreView,
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
          PopupMenuButton<LayoutKind>(
            tooltip: 'Layout',
            icon: const Icon(Icons.scatter_plot_outlined),
            initialValue: _kind,
            onSelected: (kind) {
              _kind = kind;
              _update();
            },
            itemBuilder: (context) => [
              for (final kind in LayoutKind.values)
                PopupMenuItem(value: kind, child: Text(kind.label)),
            ],
          ),
        ],
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
                    nodeMemory: widget.nodeMemory,
                    onShowInGraph: _showInGraph,
                    openInOrgro: widget.openInOrgro,
                    onOpenNode: _openNode,
                    onBack: _history.length > 1 ? _paneBack : null,
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
  _Drawing(this.drawn, this.layout) {
    for (final (:source, :dest) in drawn.edges) {
      if (source == dest) continue;
      final from = position(source), to = position(dest);
      final along = to - from;
      final length = along.distance;
      if (length <= 2 * _nodeRadius) continue;
      final unit = along / length;
      // From the edge of one dot to the edge of the other, with an arrow
      // head at the target, as Graphviz draws a digraph.
      final start = from + unit * _nodeRadius;
      final end = to - unit * _nodeRadius;
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
  }

  final DrawnGraph drawn;
  final GraphLayout layout;
  final edges = Path();

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

  /// The node nearest to [point], if it is closer than [reach].
  String? nodeAt(Offset point, double reach) {
    String? best;
    var bestDistance = reach;
    for (final node in drawn.nodes) {
      final distance = (position(node.id) - point).distance;
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
  })  : _drawing = drawing,
        super(repaint: transform);

  final _Drawing _drawing;
  final String? centre;
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
      drawing.edges,
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

    final fill = Paint()..color = colors.secondary;
    final missing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = colors.outline;
    final centreFill = Paint()..color = colors.primary;
    final showLabels = scale >= _labelScale;
    final style = textStyle.copyWith(color: colors.onSurface);
    for (final node in drawing.drawn.nodes) {
      final at = drawing.position(node.id);
      if (!visible.contains(at)) continue;
      if (node.id == centre) {
        canvas.drawCircle(at, _nodeRadius * 1.6, centreFill);
      } else {
        canvas.drawCircle(at, _nodeRadius, node.isMissing ? missing : fill);
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
      old.textStyle != textStyle;
}
