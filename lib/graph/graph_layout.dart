/// Node positions for the graph view (#6): a circular layout after
/// Graphviz's `circo`, and a force-directed one.
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
  force('Force-directed');

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
GraphLayout layoutGraph(DrawnGraph graph, LayoutKind kind) {
  final positions = switch (kind) {
    LayoutKind.circo => _circo(graph),
    LayoutKind.force => _force(graph),
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
