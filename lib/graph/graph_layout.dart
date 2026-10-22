/// Node positions for the graph view (#6): a circular layout after
/// Graphviz's `circo`, a force-directed one, a radial one around the
/// centred node (#153), one grouped by communities (#154), and a
/// hierarchical one after Graphviz's `dot` (#155).
///
/// Pure Dart (no Flutter), so it runs on another isolate and in tests.
library;

import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'graph_algorithms.dart';
import 'graph_scope.dart';

enum LayoutKind {
  /// Graphviz's `circo`: each biconnected part on a circle.
  circo('Circular (circo)'),

  /// Fruchterman and Reingold's spring model.
  force('Force-directed'),

  /// The centred node in the middle, the others on rings by their
  /// distance in links (#153).
  radial('Radial'),

  /// Each community in its own area, force-directed inside (#154).
  communities('Grouped by communities'),

  /// Graphviz's `dot`: layers from top to bottom, links pointing down
  /// (#155).
  layered('Hierarchical (dot)');

  const LayoutKind(this.label);

  final String label;
}

/// Distance between neighbours on a circle, and the ideal edge length of
/// the force-directed layout, in logical pixels at scale 1.
const nodeSpacing = 90.0;

/// Free space around the drawing, for the labels at the edges.
const layoutMargin = 120.0;

/// What a layout needs besides the graph: the centre of
/// [LayoutKind.radial] and the communities of [LayoutKind.communities].
/// The other layouts use neither.
class LayoutOptions {
  const LayoutOptions({this.centre, this.communities});

  final String? centre;

  /// Community number by node ID, as the "Communities" view has them.
  final Map<String, int>? communities;
}

/// Where each node is. Coordinates start at [layoutMargin], so the drawing
/// fits into [width] by [height].
class GraphLayout {
  const GraphLayout(
    this.positions,
    this.width,
    this.height, {
    this.fellBack = false,
  });

  final Map<String, Point<double>> positions;
  final double width;
  final double height;

  /// True when [LayoutKind.layered] took longer than its time limit and
  /// these are the positions of [LayoutKind.force] instead (#155).
  final bool fellBack;
}

/// How long [LayoutKind.layered] may take before the force-directed
/// layout is drawn instead (#155).
const layeredTimeLimit = Duration(seconds: 5);

/// Lays out [graph] with [kind]. Takes about a second for 500 nodes and
/// 2500 edges with [LayoutKind.force], so run it off the UI isolate.
///
/// [centre] is the node in the middle of [LayoutKind.radial]; the other
/// layouts do not use it. Without it, or when it is not in [graph], the
/// node with the most links is the centre.
///
/// [communities] are the communities of [LayoutKind.communities], by node
/// ID; without them, Louvain is run on [graph] here.
///
/// [timeLimit] is the time [LayoutKind.layered] may take; when it is
/// reached, the force-directed layout is returned with
/// [GraphLayout.fellBack] set.
GraphLayout layoutGraph(
  DrawnGraph graph,
  LayoutKind kind, {
  String? centre,
  Map<String, int>? communities,
  Duration timeLimit = layeredTimeLimit,
}) {
  final positions = switch (kind) {
    LayoutKind.circo => _circo(graph),
    LayoutKind.force => _force(graph),
    LayoutKind.radial => _radial(graph, centre),
    LayoutKind.communities =>
      _grouped(graph, communities ?? drawnCommunities(graph)),
    LayoutKind.layered => _layered(graph, timeLimit),
  };
  // Only the layered layout gives up, when it takes too long.
  if (positions == null) return _normalized(_force(graph), fellBack: true);
  return _normalized(positions);
}

/// The connected parts of [graph], each in node order, largest first.
List<List<String>> connectedParts(DrawnGraph graph) {
  final seen = <String>{};
  final parts = <List<String>>[];
  for (final node in graph.nodes) {
    if (seen.contains(node.id)) continue;
    final part = <String>[];
    final queue = Queue.of([node.id]);
    seen.add(node.id);
    while (queue.isNotEmpty) {
      final id = queue.removeFirst();
      part.add(id);
      for (final next in graph.neighbours[id]!) {
        if (seen.add(next)) queue.add(next);
      }
    }
    parts.add(part);
  }
  // A stable sort, so equal sizes keep the node order.
  return _sortedBySize(parts);
}

List<List<String>> _sortedBySize(List<List<String>> parts) {
  final indexed = [for (var i = 0; i < parts.length; i++) (i, parts[i])];
  indexed.sort((a, b) {
    final bySize = b.$2.length.compareTo(a.$2.length);
    return bySize != 0 ? bySize : a.$1.compareTo(b.$1);
  });
  return [for (final (_, part) in indexed) part];
}

/// The biconnected parts ("blocks") of the connected part [part]. Each
/// block lists its nodes in the order a depth-first search finds them, its
/// first node being where it hangs from the block found before it. A link
/// that is the only connection between two parts is a block of two nodes.
List<List<String>> biconnectedBlocks(
  List<String> part,
  Map<String, Set<String>> neighbours,
) {
  if (part.length == 1) return [part];
  final discovered = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final blocks = <List<String>>[];
  final root = part.first;
  // An explicit stack instead of recursion: a long chain of notes must not
  // overflow the call stack.
  final frames = <(String, Iterator<String>)>[];
  void visit(String id) {
    discovered[id] = low[id] = discovered.length;
    stack.add(id);
    frames.add((id, neighbours[id]!.iterator));
  }

  visit(root);
  while (frames.isNotEmpty) {
    final (id, next) = frames.last;
    if (next.moveNext()) {
      final other = next.current;
      if (!discovered.containsKey(other)) {
        visit(other);
      } else {
        low[id] = min(low[id]!, discovered[other]!);
      }
      continue;
    }
    frames.removeLast();
    if (frames.isEmpty) break;
    final parent = frames.last.$1;
    low[parent] = min(low[parent]!, low[id]!);
    if (low[id]! >= discovered[parent]!) {
      // parent separates the nodes above id on the stack from the rest.
      final block = <String>[];
      String popped;
      do {
        popped = stack.removeLast();
        block.add(popped);
      } while (popped != id);
      blocks.add([parent, ...block.reversed]);
    }
  }
  return blocks;
}

/// Radius of a circle with [count] nodes, each [nodeSpacing] from the
/// next.
double _radius(int count) =>
    count <= 2 ? nodeSpacing / 2 : nodeSpacing / (2 * sin(pi / count));

Map<String, Point<double>> _circo(DrawnGraph graph) {
  final placed = <List<Point<double>>>[];
  final partIds = <List<String>>[];
  for (final part in connectedParts(graph)) {
    final positions = _circoPart(part, graph.neighbours);
    partIds.add(part);
    placed.add([for (final id in part) positions[id]!]);
  }
  final shifted = _pack(placed);
  return {
    for (var i = 0; i < partIds.length; i++)
      for (var j = 0; j < partIds[i].length; j++)
        partIds[i][j]: shifted[i][j],
  };
}

/// circo for one connected part: the largest block on a circle around the
/// origin, and every other block on its own circle, outside the circle of
/// the block it hangs from, touching it at the node they share.
Map<String, Point<double>> _circoPart(
  List<String> part,
  Map<String, Set<String>> neighbours,
) {
  if (part.length == 1) return {part.single: const Point(0, 0)};
  final blocks = biconnectedBlocks(part, neighbours);
  final blocksOf = <String, List<int>>{};
  for (var b = 0; b < blocks.length; b++) {
    for (final id in blocks[b]) {
      blocksOf.putIfAbsent(id, () => []).add(b);
    }
  }
  var root = 0;
  for (var b = 1; b < blocks.length; b++) {
    if (blocks[b].length > blocks[root].length) root = b;
  }
  final positions = <String, Point<double>>{};
  final done = <int>{};

  void placeOnCircle(List<String> block, Point<double> centre, double start) {
    final r = _radius(block.length);
    for (var i = 0; i < block.length; i++) {
      final angle = start + 2 * pi * i / block.length;
      positions.putIfAbsent(
        block[i],
        () => Point(centre.x + r * cos(angle), centre.y + r * sin(angle)),
      );
    }
  }

  final queue = Queue<(int, Point<double>)>();

  /// Places the blocks [children] that hang from the node [id], with their
  /// first one at [first] and the next ones [step] further, and pushes them
  /// out until they do not overlap.
  void hang(String id, List<int> children, double first, double step) {
    done.addAll(children);
    final at = positions[id]!;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final members = _startingAt(blocks[child], id);
      final r = _radius(members.length);
      final angle = first + step * i;
      final distance = children.length == 1
          ? r
          : max(r, (r + nodeSpacing * 0.3) / sin(min(step, pi) / 2));
      final centre =
          Point(at.x + distance * cos(angle), at.y + distance * sin(angle));
      placeOnCircle(members, centre, angle + pi);
      queue.add((child, centre));
    }
  }

  if (blocks[root].length == 2 && blocks.length > 1) {
    // A tree: the node in most blocks in the middle, its blocks all around.
    var hub = part.first;
    for (final id in part) {
      if (blocksOf[id]!.length > blocksOf[hub]!.length) hub = id;
    }
    positions[hub] = const Point(0, 0);
    final children = blocksOf[hub]!;
    hang(hub, children, 0, 2 * pi / children.length);
  } else {
    done.add(root);
    placeOnCircle(blocks[root], const Point(0, 0), 0);
    queue.add((root, const Point<double>(0, 0)));
  }
  while (queue.isNotEmpty) {
    final (block, centre) = queue.removeFirst();
    for (final id in blocks[block]) {
      final children = [
        for (final b in blocksOf[id]!)
          if (!done.contains(b)) b,
      ];
      if (children.isEmpty) continue;
      final out = positions[id]! - centre;
      final outAngle = out.magnitude == 0 ? 0.0 : atan2(out.y, out.x);
      // A fan around the outward direction.
      final count = children.length;
      final fan = count == 1 ? 0.0 : min(1.5 * pi, 0.6 * (count - 1));
      hang(id, children, outAngle - fan / 2, count == 1 ? 0 : fan / (count - 1));
    }
  }
  return positions;
}

/// [block] rotated so that it starts with [first].
List<String> _startingAt(List<String> block, String first) {
  final i = block.indexOf(first);
  return [...block.sublist(i), ...block.sublist(0, i)];
}

/// Places the parts next to each other in rows, in the order given, so
/// the drawing is about as wide as it is high, with [gap] between them.
List<List<Point<double>>> _pack(
  List<List<Point<double>>> parts, {
  double gap = nodeSpacing,
}) {
  final boxes = [for (final part in parts) _bounds(part)];
  final area = boxes.fold(
    0.0,
    (sum, box) => sum + (box.width + gap) * (box.height + gap),
  );
  final rowWidth = max(sqrt(area), boxes.isEmpty ? 0.0 : boxes.first.width);
  final result = <List<Point<double>>>[];
  var x = 0.0, y = 0.0, rowHeight = 0.0;
  for (var i = 0; i < parts.length; i++) {
    final box = boxes[i];
    if (x > 0 && x + box.width > rowWidth) {
      x = 0;
      y += rowHeight + gap;
      rowHeight = 0;
    }
    final dx = x - box.left, dy = y - box.top;
    result.add([for (final p in parts[i]) Point(p.x + dx, p.y + dy)]);
    x += box.width + gap;
    rowHeight = max(rowHeight, box.height);
  }
  return result;
}

Rectangle<double> _bounds(Iterable<Point<double>> points) {
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final p in points) {
    left = min(left, p.x);
    top = min(top, p.y);
    right = max(right, p.x);
    bottom = max(bottom, p.y);
  }
  if (left > right) return const Rectangle(0, 0, 0, 0);
  return Rectangle(left, top, right - left, bottom - top);
}

/// The centre of [LayoutKind.radial]: [centre] if it is in [graph], else
/// the node with the most links (the first of them in node order); null
/// for an empty graph.
String? radialCentre(DrawnGraph graph, String? centre) {
  if (centre != null && graph.neighbours.containsKey(centre)) return centre;
  String? best;
  var most = -1;
  for (final node in graph.nodes) {
    final links = graph.neighbours[node.id]!.length;
    if (links > most) {
      most = links;
      best = node.id;
    }
  }
  return best;
}

/// The radial layout (#153): the centre's connected part on rings around
/// it, the other parts packed beside it.
Map<String, Point<double>> _radial(DrawnGraph graph, String? centre) {
  final root = radialCentre(graph, centre);
  if (root == null) return {};
  final parts = connectedParts(graph);
  final rootPart = parts.firstWhere((part) => part.contains(root));
  final ordered = [
    rootPart,
    for (final part in parts)
      if (!identical(part, rootPart)) part,
  ];
  final placed = <List<Point<double>>>[];
  for (final part in ordered) {
    // A part beside the centre's part has its own most linked node in the
    // middle.
    final middle =
        identical(part, rootPart) ? root : _mostLinkedOf(part, graph);
    final positions = radialPart(middle, graph.neighbours);
    placed.add([for (final id in part) positions[id]!]);
  }
  final shifted = _pack(placed);
  return {
    for (var i = 0; i < ordered.length; i++)
      for (var j = 0; j < ordered[i].length; j++)
        ordered[i][j]: shifted[i][j],
  };
}

String _mostLinkedOf(List<String> part, DrawnGraph graph) {
  var best = part.first;
  for (final id in part) {
    if (graph.neighbours[id]!.length > graph.neighbours[best]!.length) {
      best = id;
    }
  }
  return best;
}

/// A radial tree layout of the connected part of [root]: [root] at the
/// origin, the nodes [d] links away on ring [d]. The rings come from a
/// breadth-first search over [neighbours]; each node's parent is the node
/// it was reached from. Every subtree gets a wedge in proportion to its
/// number of leaves, and each node sits in the middle of its wedge, so a
/// node is near its parent and siblings stay together.
///
/// Each ring's radius is a multiple of [nodeSpacing], at least
/// [nodeSpacing] more than the ring inside it, and large enough that the
/// nodes on it are [nodeSpacing] apart.
Map<String, Point<double>> radialPart(
  String root,
  Map<String, Set<String>> neighbours,
) {
  final depth = <String, int>{root: 0};
  final children = <String, List<String>>{};
  final order = <String>[root];
  final queue = Queue.of([root]);
  while (queue.isNotEmpty) {
    final id = queue.removeFirst();
    final mine = children[id] = [];
    for (final next in neighbours[id]!) {
      if (depth.containsKey(next)) continue;
      depth[next] = depth[id]! + 1;
      mine.add(next);
      order.add(next);
      queue.add(next);
    }
  }
  // Leaves per subtree, from the outermost ring in.
  final leaves = <String, int>{};
  for (final id in order.reversed) {
    final mine = children[id]!;
    leaves[id] = mine.isEmpty ? 1 : mine.fold(0, (sum, c) => sum + leaves[c]!);
  }
  // Each node's angle: the middle of its wedge.
  final perLeaf = 2 * pi / leaves[root]!;
  final angle = <String, double>{root: 0};
  final wedgeStart = <String, double>{root: 0};
  for (final id in order) {
    final mine = children[id]!;
    if (mine.isEmpty) continue;
    var start = wedgeStart[id]!;
    for (final child in mine) {
      final width = perLeaf * leaves[child]!;
      wedgeStart[child] = start;
      angle[child] = start + width / 2;
      start += width;
    }
  }
  // The rings.
  final rings = <List<String>>[];
  for (final id in order.skip(1)) {
    final d = depth[id]!;
    while (rings.length < d) {
      rings.add([]);
    }
    rings[d - 1].add(id);
  }
  final radius = <double>[0];
  for (final ring in rings) {
    var needed = radius.last + nodeSpacing;
    if (ring.length > 1) {
      final angles = [for (final id in ring) angle[id]!]..sort();
      var gap = 2 * pi - (angles.last - angles.first);
      for (var i = 1; i < angles.length; i++) {
        gap = min(gap, angles[i] - angles[i - 1]);
      }
      // Two nodes [gap] apart on a circle of radius r are
      // 2 r sin(gap / 2) apart.
      if (gap < pi) needed = max(needed, nodeSpacing / (2 * sin(gap / 2)));
    }
    // A little below a multiple stays that multiple; rounding errors must
    // not add a ring's width.
    radius.add((needed / nodeSpacing - 1e-9).ceil() * nodeSpacing);
  }
  return {
    for (final id in order)
      id: id == root
          ? const Point(0.0, 0.0)
          : Point(
              radius[depth[id]!] * cos(angle[id]!),
              radius[depth[id]!] * sin(angle[id]!),
            ),
  };
}

/// Fruchterman and Reingold's layout: linked nodes pull each other
/// together, all nodes push each other apart, and a weak pull to the centre
/// keeps unlinked nodes and small parts near the rest. Starts from fixed
/// random positions, so the same graph gives the same drawing.
Map<String, Point<double>> _force(DrawnGraph graph) => _forceOf(
      [for (final node in graph.nodes) node.id],
      graph.edges,
    );

/// [_force] on the nodes [ids] and the [links] between them.
Map<String, Point<double>> _forceOf(
  List<String> ids,
  Iterable<DrawnEdge> links, {
  int iterations = 300,
}) {
  final n = ids.length;
  if (n == 0) return {};
  final index = {for (var i = 0; i < n; i++) ids[i]: i};
  final edges = <(int, int)>[
    for (final (:source, :dest) in links)
      if (source != dest) (index[source]!, index[dest]!),
  ];
  const k = nodeSpacing;
  final side = k * sqrt(n) * 1.5;
  final random = Random(1);
  final x = Float64List(n), y = Float64List(n);
  for (var i = 0; i < n; i++) {
    x[i] = (random.nextDouble() - 0.5) * side;
    y[i] = (random.nextDouble() - 0.5) * side;
  }
  final dx = Float64List(n), dy = Float64List(n);
  const gravity = 0.1;
  for (var iteration = 0; iteration < iterations; iteration++) {
    final temperature = side / 10 * (1 - iteration / iterations) + 1;
    dx.fillRange(0, n, 0);
    dy.fillRange(0, n, 0);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var ex = x[i] - x[j], ey = y[i] - y[j];
        var d2 = ex * ex + ey * ey;
        if (d2 < 0.01) {
          // Two nodes on the same spot: push them apart in a fixed
          // direction.
          ex = 0.1 * (i - j);
          ey = 0.1;
          d2 = ex * ex + ey * ey;
        }
        final f = k * k / d2;
        dx[i] += ex * f;
        dy[i] += ey * f;
        dx[j] -= ex * f;
        dy[j] -= ey * f;
      }
    }
    for (final (a, b) in edges) {
      final ex = x[a] - x[b], ey = y[a] - y[b];
      final d = sqrt(ex * ex + ey * ey);
      final f = d / k;
      dx[a] -= ex * f;
      dy[a] -= ey * f;
      dx[b] += ex * f;
      dy[b] += ey * f;
    }
    for (var i = 0; i < n; i++) {
      final gx = dx[i] - gravity * x[i] * k / 10;
      final gy = dy[i] - gravity * y[i] * k / 10;
      final d = sqrt(gx * gx + gy * gy);
      if (d == 0) continue;
      final move = min(d, temperature);
      x[i] += gx / d * move;
      y[i] += gy / d * move;
    }
  }
  return {for (var i = 0; i < n; i++) ids[i]: Point(x[i], y[i])};
}

/// Louvain communities of [graph] alone, for [LayoutKind.communities]
/// when the caller has none: the graph view passes the communities of the
/// whole graph instead, so that the areas match the "Communities" view.
Map<String, int> drawnCommunities(DrawnGraph graph) => louvainCommunities(
      AlgorithmGraph.of(
        [
          for (final node in graph.nodes)
            (node.id, node.node?.title ?? node.label),
        ],
        [for (final (:source, :dest) in graph.edges) (source, dest)],
      ),
    );

/// Communities with at most this many nodes share one area, at the end.
const smallCommunity = 2;

/// Free space between the areas of [LayoutKind.communities].
const areaGap = 2 * nodeSpacing;

/// The nodes of [graph] in their areas (#154): one group per community of
/// more than [smallCommunity] nodes, largest first, then one group with
/// all the small communities and the nodes without one. A node keeps the
/// order of [graph] inside its group.
List<List<String>> communityGroups(
  DrawnGraph graph,
  Map<String, int> communities,
) {
  final byCommunity = <int, List<String>>{};
  final rest = <String>[];
  for (final node in graph.nodes) {
    final community = communities[node.id];
    if (community == null) {
      rest.add(node.id);
    } else {
      byCommunity.putIfAbsent(community, () => []).add(node.id);
    }
  }
  final large = <List<String>>[];
  final small = <String>{};
  for (final members in byCommunity.values) {
    if (members.length > smallCommunity) {
      large.add(members);
    } else {
      small.addAll(members);
    }
  }
  small.addAll(rest);
  final groups = _sortedBySize(large);
  if (small.isNotEmpty) {
    groups.add([
      for (final node in graph.nodes)
        if (small.contains(node.id)) node.id,
    ]);
  }
  return groups;
}

/// The layout grouped by communities (#154): each group of
/// [communityGroups] laid out force-directed with the links inside it,
/// the areas packed side by side with [areaGap] between them.
Map<String, Point<double>> _grouped(
  DrawnGraph graph,
  Map<String, int> communities,
) {
  final groups = communityGroups(graph, communities);
  final groupOf = <String, int>{
    for (var g = 0; g < groups.length; g++)
      for (final id in groups[g]) id: g,
  };
  final inside = List.generate(groups.length, (_) => <DrawnEdge>[]);
  for (final edge in graph.edges) {
    final g = groupOf[edge.source]!;
    if (g == groupOf[edge.dest]) inside[g].add(edge);
  }
  final placed = <List<Point<double>>>[];
  for (var g = 0; g < groups.length; g++) {
    final positions = _forceOf(groups[g], inside[g]);
    placed.add([for (final id in groups[g]) positions[id]!]);
  }
  final shifted = _pack(placed, gap: areaGap);
  return {
    for (var g = 0; g < groups.length; g++)
      for (var i = 0; i < groups[g].length; i++)
        groups[g][i]: shifted[g][i],
  };
}

/// Distance between two layers of [LayoutKind.layered], more than between
/// two nodes of a layer, as in `dot`, so the links' direction shows.
const layerSpacing = 1.5 * nodeSpacing;

/// A directed link of [LayoutKind.layered]: from [source], drawn above,
/// to [dest].
typedef LayeredLink = (String source, String dest);

/// The links of [graph] for [LayoutKind.layered] (#155), without cycles:
/// one per pair of nodes (a pair linking both ways counts once, in the
/// direction found first), no links of a node to itself, and the cycles
/// broken as `dot` does by default: a depth-first search from the nodes in
/// [graph]'s order reverses each link that leads back to a node still on
/// its path.
List<LayeredLink> acyclicLinks(DrawnGraph graph) {
  final seen = <(String, String)>{};
  final out = {for (final node in graph.nodes) node.id: <String>[]};
  for (final (:source, :dest) in graph.edges) {
    if (source == dest) continue;
    if (seen.contains((dest, source)) || !seen.add((source, dest))) continue;
    out[source]!.add(dest);
  }
  final links = <LayeredLink>[];
  // 0: not reached, 1: on the path, 2: done.
  final state = <String, int>{};
  for (final node in graph.nodes) {
    if (state.containsKey(node.id)) continue;
    // An explicit stack: a long chain must not overflow the call stack.
    final frames = <(String, Iterator<String>)>[];
    state[node.id] = 1;
    frames.add((node.id, out[node.id]!.iterator));
    while (frames.isNotEmpty) {
      final (id, next) = frames.last;
      if (!next.moveNext()) {
        state[id] = 2;
        frames.removeLast();
        continue;
      }
      final other = next.current;
      switch (state[other]) {
        case null:
          links.add((id, other));
          state[other] = 1;
          frames.add((other, out[other]!.iterator));
        case 1:
          links.add((other, id));
        default:
          links.add((id, other));
      }
    }
  }
  return links;
}

/// The layer of each node in [ids] by the longest path from a node
/// without links coming in: those are layer 0, and every other node is one
/// layer below the lowest node linking to it. [links] must have no cycles.
Map<String, int> longestPathLayers(
  List<String> ids,
  List<LayeredLink> links,
) {
  final incoming = {for (final id in ids) id: 0};
  final out = {for (final id in ids) id: <String>[]};
  for (final (source, dest) in links) {
    out[source]!.add(dest);
    incoming[dest] = incoming[dest]! + 1;
  }
  final layer = <String, int>{};
  final queue = Queue<String>();
  for (final id in ids) {
    if (incoming[id] == 0) {
      layer[id] = 0;
      queue.add(id);
    }
  }
  while (queue.isNotEmpty) {
    final id = queue.removeFirst();
    for (final next in out[id]!) {
      layer[next] = max(layer[next] ?? 0, layer[id]! + 1);
      incoming[next] = incoming[next]! - 1;
      if (incoming[next] == 0) queue.add(next);
    }
  }
  return layer;
}

/// The number of crossings between the links of neighbouring layers of
/// [layers], each layer in its order from left to right. Links that span
/// more than one layer are not counted.
int layerCrossings(List<List<String>> layers, List<LayeredLink> links) {
  final layerOf = <String, int>{};
  final position = <String, int>{};
  for (var l = 0; l < layers.length; l++) {
    for (var i = 0; i < layers[l].length; i++) {
      layerOf[layers[l][i]] = l;
      position[layers[l][i]] = i;
    }
  }
  final between = List.generate(
    max(0, layers.length - 1),
    (_) => <(int, int)>[],
  );
  for (final (source, dest) in links) {
    final l = layerOf[source];
    if (l == null || layerOf[dest] != l + 1) continue;
    between[l].add((position[source]!, position[dest]!));
  }
  var total = 0;
  for (var l = 0; l < between.length; l++) {
    final pairs = between[l]
      ..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    // Two links cross when the one starting further left ends further
    // right: count those pairs with a Fenwick tree over the lower layer.
    final size = layers[l + 1].length;
    final tree = List.filled(size + 1, 0);
    var added = 0;
    for (final (_, dest) in pairs) {
      // Links added so far that end right of dest.
      var notRight = 0;
      for (var i = dest + 1; i > 0; i -= i & -i) {
        notRight += tree[i];
      }
      total += added - notRight;
      for (var i = dest + 1; i <= size; i += i & -i) {
        tree[i]++;
      }
      added++;
    }
  }
  return total;
}

/// [layers] with each layer reordered by the barycentre heuristic, to
/// reduce the crossings: sweeps down (each node by the mean place of the
/// nodes linking to it in the layers above) and up (by the nodes it links
/// to below), [sweeps] times each, keeping the order with the fewest
/// [layerCrossings]. A place is taken relative to the width of its layer,
/// so links over several layers count too. A node without links on that
/// side keeps its place. Returns null when [timeUp] says the time is up.
List<List<String>>? orderLayers(
  List<List<String>> layers,
  List<LayeredLink> links, {
  int sweeps = 6,
  bool Function() timeUp = _never,
}) {
  final above = <String, List<String>>{};
  final below = <String, List<String>>{};
  for (final (source, dest) in links) {
    below.putIfAbsent(source, () => []).add(dest);
    above.putIfAbsent(dest, () => []).add(source);
  }
  final current = [for (final layer in layers) [...layer]];
  final place = <String, double>{};
  void measure(int l) {
    final layer = current[l];
    for (var i = 0; i < layer.length; i++) {
      place[layer[i]] = (i + 0.5) / layer.length;
    }
  }

  for (var l = 0; l < current.length; l++) {
    measure(l);
  }
  var best = [for (final layer in current) [...layer]];
  var fewest = layerCrossings(current, links);

  void reorder(int l, Map<String, List<String>> by) {
    final layer = current[l];
    final key = <String, double>{};
    for (final id in layer) {
      final others = by[id];
      key[id] = others == null || others.isEmpty
          ? place[id]!
          : others.fold(0.0, (sum, o) => sum + place[o]!) / others.length;
    }
    final indexed = [for (var i = 0; i < layer.length; i++) (i, layer[i])];
    // A stable sort, so equal barycentres keep their order.
    indexed.sort((a, b) {
      final byKey = key[a.$2]!.compareTo(key[b.$2]!);
      return byKey != 0 ? byKey : a.$1.compareTo(b.$1);
    });
    current[l] = [for (final (_, id) in indexed) id];
    measure(l);
  }

  void keepIfBetter() {
    final crossings = layerCrossings(current, links);
    if (crossings < fewest) {
      fewest = crossings;
      best = [for (final layer in current) [...layer]];
    }
  }

  for (var sweep = 0; sweep < sweeps && fewest > 0; sweep++) {
    for (var l = 1; l < current.length; l++) {
      reorder(l, above);
    }
    keepIfBetter();
    if (timeUp()) return null;
    for (var l = current.length - 2; l >= 0; l--) {
      reorder(l, below);
    }
    keepIfBetter();
    if (timeUp()) return null;
  }
  return best;
}

bool _never() => false;

/// The x position of each node of [layers], each layer in its order, at
/// least [nodeSpacing] apart: a few sweeps down and up move each node to
/// the mean x of the nodes it links to in the layers above (going down)
/// or below (going up), as near as the spacing allows.
Map<String, double> layerXs(
  List<List<String>> layers,
  List<LayeredLink> links, {
  int sweeps = 4,
}) {
  final above = <String, List<String>>{};
  final below = <String, List<String>>{};
  for (final (source, dest) in links) {
    below.putIfAbsent(source, () => []).add(dest);
    above.putIfAbsent(dest, () => []).add(source);
  }
  final x = <String, double>{};
  for (final layer in layers) {
    for (var i = 0; i < layer.length; i++) {
      x[layer[i]] = (i - (layer.length - 1) / 2) * nodeSpacing;
    }
  }
  void place(List<String> layer, Map<String, List<String>> by) {
    final wanted = [
      for (final id in layer)
        switch (by[id]) {
          final others? when others.isNotEmpty =>
            others.fold(0.0, (sum, o) => sum + x[o]!) / others.length,
          _ => x[id]!,
        },
    ];
    final fitted = spacedFit(wanted, nodeSpacing);
    for (var i = 0; i < layer.length; i++) {
      x[layer[i]] = fitted[i];
    }
  }

  for (var sweep = 0; sweep < sweeps; sweep++) {
    for (var l = 1; l < layers.length; l++) {
      place(layers[l], above);
    }
    for (var l = layers.length - 2; l >= 0; l--) {
      place(layers[l], below);
    }
  }
  return x;
}

/// The positions nearest to [wanted] (least squares) that keep their order
/// and are at least [spacing] apart. With z = wanted[i] - i * spacing, this
/// is the closest non-decreasing sequence to z (pool adjacent violators),
/// plus i * spacing again.
List<double> spacedFit(List<double> wanted, double spacing) {
  // Blocks of neighbouring positions that move together: sum and count.
  final sums = <double>[];
  final counts = <int>[];
  for (var i = 0; i < wanted.length; i++) {
    sums.add(wanted[i] - i * spacing);
    counts.add(1);
    while (sums.length > 1 &&
        sums[sums.length - 2] / counts[counts.length - 2] >
            sums.last / counts.last) {
      final sum = sums.removeLast(), count = counts.removeLast();
      sums[sums.length - 1] += sum;
      counts[counts.length - 1] += count;
    }
  }
  final result = <double>[];
  for (var b = 0; b < sums.length; b++) {
    final mean = sums[b] / counts[b];
    for (var k = 0; k < counts[b]; k++) {
      result.add(mean + result.length * spacing);
    }
  }
  return result;
}

/// The hierarchical layout (#155), after Sugiyama's method as Graphviz's
/// `dot` uses it, kept simple: (1) [acyclicLinks], (2)
/// [longestPathLayers], (3) [orderLayers], (4) [layerXs]. Links over
/// several layers are drawn straight, without dummy nodes. Each connected
/// part is laid out alone and the parts are packed side by side. Null when
/// it takes longer than [limit].
Map<String, Point<double>>? _layered(DrawnGraph graph, Duration limit) {
  final clock = Stopwatch()..start();
  bool timeUp() => clock.elapsed >= limit;
  final links = acyclicLinks(graph);
  final ids = [for (final node in graph.nodes) node.id];
  final layer = longestPathLayers(ids, links);
  final out = <String, List<LayeredLink>>{};
  for (final link in links) {
    out.putIfAbsent(link.$1, () => []).add(link);
  }
  final parts = connectedParts(graph);
  final placed = <List<Point<double>>>[];
  for (final part in parts) {
    if (timeUp()) return null;
    final partLinks = [
      for (final id in part) ...?out[id],
    ];
    final depth = part.fold(0, (deepest, id) => max(deepest, layer[id]!));
    // The first order: as a depth-first search from the top layer finds
    // the nodes, so the nodes linked from one node start out together.
    final layers = List.generate(depth + 1, (_) => <String>[]);
    final below = <String, List<String>>{};
    for (final (source, dest) in partLinks) {
      below.putIfAbsent(source, () => []).add(dest);
    }
    final seen = <String>{};
    for (final start in part) {
      if (layer[start] != 0 || !seen.add(start)) continue;
      final stack = [start];
      while (stack.isNotEmpty) {
        final id = stack.removeLast();
        layers[layer[id]!].add(id);
        final next = below[id] ?? const <String>[];
        for (final other in next.reversed) {
          if (seen.add(other)) stack.add(other);
        }
      }
    }
    final ordered = orderLayers(layers, partLinks, timeUp: timeUp);
    if (ordered == null) return null;
    final x = layerXs(ordered, partLinks);
    placed.add([
      for (final id in part) Point(x[id]!, layer[id]! * layerSpacing),
    ]);
  }
  final shifted = _pack(placed);
  return {
    for (var p = 0; p < parts.length; p++)
      for (var i = 0; i < parts[p].length; i++) parts[p][i]: shifted[p][i],
  };
}

/// [positions] moved so that the smallest coordinates are [layoutMargin].
GraphLayout _normalized(
  Map<String, Point<double>> positions, {
  bool fellBack = false,
}) {
  final box = _bounds(positions.values);
  final dx = layoutMargin - box.left, dy = layoutMargin - box.top;
  return GraphLayout(
    {
      for (final MapEntry(:key, :value) in positions.entries)
        key: Point(value.x + dx, value.y + dy),
    },
    box.width + 2 * layoutMargin,
    box.height + 2 * layoutMargin,
    fellBack: fellBack,
  );
}
