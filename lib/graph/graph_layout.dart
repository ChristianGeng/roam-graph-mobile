/// Node positions for the graph view (#6): a circular layout after
/// Graphviz's `circo`, a force-directed one, and a radial one around the
/// centred node (#153).
///
/// Pure Dart (no Flutter), so it runs on another isolate and in tests.
library;

import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'graph_scope.dart';

enum LayoutKind {
  /// Graphviz's `circo`: each biconnected part on a circle.
  circo('Circular (circo)'),

  /// Fruchterman and Reingold's spring model.
  force('Force-directed'),

  /// The centred node in the middle, the others on rings by their
  /// distance in links (#153).
  radial('Radial');

  const LayoutKind(this.label);

  final String label;
}

/// Distance between neighbours on a circle, and the ideal edge length of
/// the force-directed layout, in logical pixels at scale 1.
const nodeSpacing = 90.0;

/// Free space around the drawing, for the labels at the edges.
const layoutMargin = 120.0;

/// Where each node is. Coordinates start at [layoutMargin], so the drawing
/// fits into [width] by [height].
class GraphLayout {
  const GraphLayout(this.positions, this.width, this.height);

  final Map<String, Point<double>> positions;
  final double width;
  final double height;
}

/// Lays out [graph] with [kind]. Takes about a second for 500 nodes and
/// 2500 edges with [LayoutKind.force], so run it off the UI isolate.
///
/// [centre] is the node in the middle of [LayoutKind.radial]; the other
/// layouts do not use it. Without it, or when it is not in [graph], the
/// node with the most links is the centre.
GraphLayout layoutGraph(DrawnGraph graph, LayoutKind kind, {String? centre}) {
  final positions = switch (kind) {
    LayoutKind.circo => _circo(graph),
    LayoutKind.force => _force(graph),
    LayoutKind.radial => _radial(graph, centre),
  };
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

/// Places the parts next to each other in rows, largest first, so the
/// drawing is about as wide as it is high.
List<List<Point<double>>> _pack(List<List<Point<double>>> parts) {
  final boxes = [for (final part in parts) _bounds(part)];
  final area = boxes.fold(
    0.0,
    (sum, box) => sum + (box.width + nodeSpacing) * (box.height + nodeSpacing),
  );
  final rowWidth = max(sqrt(area), boxes.isEmpty ? 0.0 : boxes.first.width);
  final result = <List<Point<double>>>[];
  var x = 0.0, y = 0.0, rowHeight = 0.0;
  for (var i = 0; i < parts.length; i++) {
    final box = boxes[i];
    if (x > 0 && x + box.width > rowWidth) {
      x = 0;
      y += rowHeight + nodeSpacing;
      rowHeight = 0;
    }
    final dx = x - box.left, dy = y - box.top;
    result.add([for (final p in parts[i]) Point(p.x + dx, p.y + dy)]);
    x += box.width + nodeSpacing;
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
Map<String, Point<double>> _force(DrawnGraph graph, {int iterations = 300}) {
  final ids = [for (final node in graph.nodes) node.id];
  final n = ids.length;
  if (n == 0) return {};
  final index = {for (var i = 0; i < n; i++) ids[i]: i};
  final edges = <(int, int)>[
    for (final (:source, :dest) in graph.edges)
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

/// [positions] moved so that the smallest coordinates are [layoutMargin].
GraphLayout _normalized(Map<String, Point<double>> positions) {
  final box = _bounds(positions.values);
  final dx = layoutMargin - box.left, dy = layoutMargin - box.top;
  return GraphLayout(
    {
      for (final MapEntry(:key, :value) in positions.entries)
        key: Point(value.x + dx, value.y + dy),
    },
    box.width + 2 * layoutMargin,
    box.height + 2 * layoutMargin,
  );
}
