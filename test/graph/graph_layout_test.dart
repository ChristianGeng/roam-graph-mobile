import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/graph_layout.dart';
import 'package:roam_graph_mobile/graph/graph_scope.dart';

import 'graph_scope_test.dart' show fixtureGraph, graphOf, randomGraph;

DrawnGraph whole(List<String> ids, List<String> links) =>
    DrawnGraph.of(graphOf(ids, links), const WholeGraph());

/// The smallest distance between two nodes.
double closest(GraphLayout layout) {
  final points = layout.positions.values.toList();
  var best = double.infinity;
  for (var i = 0; i < points.length; i++) {
    for (var j = i + 1; j < points.length; j++) {
      best = min(best, points[i].distanceTo(points[j]));
    }
  }
  return best;
}

void expectInside(DrawnGraph drawn, GraphLayout layout) {
  expect(layout.positions.keys.toSet(), {for (final n in drawn.nodes) n.id});
  for (final p in layout.positions.values) {
    expect(p.x.isFinite && p.y.isFinite, isTrue);
    expect(p.x, inInclusiveRange(layoutMargin - 0.001, layout.width));
    expect(p.y, inInclusiveRange(layoutMargin - 0.001, layout.height));
  }
}

void main() {
  test('biconnected blocks: two triangles sharing a node, and a tail', () {
    final drawn = whole(
      ['a', 'b', 'c', 'd', 'e', 'f'],
      ['a>b', 'b>c', 'c>a', 'c>d', 'd>e', 'e>c', 'e>f'],
    );
    final blocks = biconnectedBlocks(
      ['a', 'b', 'c', 'd', 'e', 'f'],
      drawn.neighbours,
    );
    expect(
      {for (final block in blocks) block.toSet()},
      {
        {'a', 'b', 'c'},
        {'c', 'd', 'e'},
        {'e', 'f'},
      },
    );
  });

  test('connected parts, largest first', () {
    final drawn = whole(['a', 'b', 'c', 'd', 'e'], ['d>e', 'a>b', 'b>c']);
    expect(connectedParts(drawn), [
      ['a', 'b', 'c'],
      ['d', 'e'],
    ]);
  });

  group('circo', () {
    test('a cycle lies on a circle, neighbours equally far apart', () {
      final ids = [for (var i = 0; i < 8; i++) 'n$i'];
      final drawn = whole(ids, [
        for (var i = 0; i < 8; i++) 'n$i>n${(i + 1) % 8}',
      ]);
      final layout = layoutGraph(drawn, LayoutKind.circo);
      final points = [for (final id in ids) layout.positions[id]!];
      final centre = Point(
        points.map((p) => p.x).reduce((a, b) => a + b) / 8,
        points.map((p) => p.y).reduce((a, b) => a + b) / 8,
      );
      final radius = points.first.distanceTo(centre);
      for (var i = 0; i < 8; i++) {
        expect(points[i].distanceTo(centre), closeTo(radius, 0.001));
        expect(points[i].distanceTo(points[(i + 1) % 8]),
            closeTo(nodeSpacing, 0.001));
      }
    });

    test('a star: the hub in the middle, the others around it', () {
      final ids = ['hub', for (var i = 0; i < 12; i++) 'leaf$i'];
      final drawn = whole(ids, [for (var i = 0; i < 12; i++) 'hub>leaf$i']);
      final layout = layoutGraph(drawn, LayoutKind.circo);
      final hub = layout.positions['hub']!;
      final distances = {
        for (var i = 0; i < 12; i++)
          layout.positions['leaf$i']!.distanceTo(hub).toStringAsFixed(3),
      };
      expect(distances, hasLength(1));
      expect(closest(layout), greaterThan(nodeSpacing * 0.5));
    });

    test('a block hangs outside the block it shares a node with', () {
      final drawn = whole(
        ['a', 'b', 'c', 'd', 'x', 'y'],
        ['a>b', 'b>c', 'c>d', 'd>a', 'c>x', 'x>y', 'y>c'],
      );
      final layout = layoutGraph(drawn, LayoutKind.circo);
      final p = layout.positions;
      final square = Point(
        (p['a']!.x + p['b']!.x + p['c']!.x + p['d']!.x) / 4,
        (p['a']!.y + p['b']!.y + p['c']!.y + p['d']!.y) / 4,
      );
      final squareRadius = p['a']!.distanceTo(square);
      for (final id in ['x', 'y']) {
        expect(p[id]!.distanceTo(square), greaterThan(squareRadius));
      }
    });
  });

  for (final kind in LayoutKind.values) {
    group(kind.name, () {
      test('every node of the sample files has its own place', () {
        final drawn = DrawnGraph.of(fixtureGraph(), const WholeGraph());
        final layout = layoutGraph(drawn, kind);
        expectInside(drawn, layout);
        expect(closest(layout), greaterThan(10));
      });

      test('500 nodes and 2500 links', () {
        final drawn =
            DrawnGraph.of(randomGraph(500, 2500, 1), const WholeGraph());
        final layout = layoutGraph(drawn, kind);
        expectInside(drawn, layout);
        // The same graph gives the same drawing.
        final again = layoutGraph(drawn, kind);
        expect(again.positions, layout.positions);
      });

      test('an empty graph and a single node', () {
        final empty = whole([], []);
        expect(layoutGraph(empty, kind).positions, isEmpty);
        final single = whole(['a'], []);
        expectInside(single, layoutGraph(single, kind));
      });
    });
  }
}
