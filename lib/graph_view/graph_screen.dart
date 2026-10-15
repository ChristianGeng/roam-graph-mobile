import 'dart:isolate';
import 'dart:math';

import 'package:flutter/material.dart';

import '../graph/graph_layout.dart';
import '../graph/graph_scope.dart';
import '../graph/roam_graph.dart';
import 'node_memory.dart';

/// Computes a layout; by default on another isolate.
typedef LayoutFunction = Future<GraphLayout> Function(
    DrawnGraph graph, LayoutKind kind);

Future<GraphLayout> layoutOnIsolate(DrawnGraph graph, LayoutKind kind) =>
    Isolate.run(() => layoutGraph(graph, kind));

/// Radius of a node's dot, in logical pixels at scale 1.
const _nodeRadius = 7.0;

/// Below this scale the labels are too small to read and are not drawn.
const _labelScale = 0.45;

/// The node graph in the style of `org-roam-graph` (#6): nodes labelled
/// with their titles, an edge for each pair of nodes with an `id:` link.
///
/// Starts with the whole graph, centred on the node opened last, or on the
/// node with the most links. A tap on a node centres the graph on it and
/// opens it.
class GraphScreen extends StatefulWidget {
  const GraphScreen({
    super.key,
    required this.graph,
    this.nodeMemory = const FileNodeMemory(),
    this.computeLayout = layoutOnIsolate,
  });

  final RoamGraph graph;
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

  /// Layouts computed so far, so switching back is immediate.
  final _layouts = <(GraphScope, LayoutKind), GraphLayout>{};

  /// Counts layout requests; only the latest may be shown.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _transform.dispose();
    _drawing?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final remembered = await widget.nodeMemory.lastNode();
    if (!mounted) return;
    _centre = widget.graph.nodes.containsKey(remembered)
        ? remembered
        : _mostLinked(widget.graph);
    await _update();
  }

  /// Draws the current scope with the current layout.
  Future<void> _update() async {
    final centre = _centre;
    if (centre == null) return;
    final generation = ++_generation;
    final scope = _choice.scope(centre);
    final drawn = DrawnGraph.of(widget.graph, scope);
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
    final id = drawing.nodeAt(details.localPosition, max(20, 28 / scale));
    if (id == null) return;
    final node = widget.graph.nodes[id];
    if (node == null) return;
    setState(() => _centre = id);
    widget.nodeMemory.remember(id);
    _open(node);
  }

  /// Opens [node]. Until the node view (#8) exists, a short summary.
  void _open(RoamNode node) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => _NodeSummary(
        node: node,
        drawn: _drawn,
        onNeighbourhood: () {
          Navigator.pop(context);
          _show(_ScopeChoice.steps1);
        },
      ),
    );
  }

  void _show(_ScopeChoice choice) {
    _choice = choice;
    _update();
  }

  @override
  Widget build(BuildContext context) {
    final centreTitle = widget.graph.nodes[_scopeCentre]?.displayTitle ?? '';
    return Scaffold(
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final first = _viewport.isEmpty;
          _viewport = constraints.biggest;
          if (first) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _centreView());
          }
          return _body(context);
        },
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (widget.graph.nodes.isEmpty) {
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

/// A short summary of a node, shown when it is tapped, until the node view
/// (#8) exists.
class _NodeSummary extends StatelessWidget {
  const _NodeSummary({
    required this.node,
    required this.drawn,
    required this.onNeighbourhood,
  });

  final RoamNode node;
  final DrawnGraph? drawn;
  final VoidCallback onNeighbourhood;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final edges = drawn?.edges ?? const <DrawnEdge>[];
    final out = edges.where((e) => e.source == node.id).length;
    final back = edges.where((e) => e.dest == node.id).length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(node.displayTitle, style: text.titleLarge),
            Text(node.file, style: text.bodySmall),
            if (node.tags.isNotEmpty) Text('Tags: ${node.tags.join(', ')}'),
            Text('Links to $out nodes, linked from $back nodes in this view.'),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onNeighbourhood,
                child: const Text('Show its neighbourhood'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
