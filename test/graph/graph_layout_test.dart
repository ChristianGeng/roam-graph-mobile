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

  group('radial (#153)', () {
    /// A tree around r: a1 and a2 one link away, a1's children b1 to b3
    /// and a2's child b4 two links away, c1 below b1 three away. x and y
    /// are a part of their own; z has no links.
    final ids = ['r', 'a1', 'a2', 'b1', 'b2', 'b3', 'b4', 'c1', 'x', 'y', 'z'];
    final links = [
      'r>a1', 'a2>r', 'a1>b1', 'a1>b2', 'b3>a1', 'a2>b4', 'b1>c1', 'x>y', //
    ];
    const depth = {
      'r': 0, 'a1': 1, 'a2': 1, 'b1': 2, 'b2': 2, 'b3': 2, 'b4': 2, 'c1': 3,
    };
    final drawn = whole(ids, links);
    final p = layoutGraph(drawn, LayoutKind.radial, centre: 'r').positions;
    double angleOf(String id) {
      final d = p[id]! - p['r']!;
      return atan2(d.y, d.x);
    }

    test('the centre in the middle, every node on the ring of its distance',
        () {
      final radii = <int, double>{};
      for (final MapEntry(key: id, value: d) in depth.entries) {
        final r = p[id]!.distanceTo(p['r']!);
        if (d == 0) {
          expect(r, 0);
          continue;
        }
        expect(r, closeTo(radii.putIfAbsent(d, () => r), 0.001), reason: id);
      }
      // Rings at multiples of nodeSpacing, further out by distance.
      for (var d = 1; d <= 3; d++) {
        final r = radii[d]!;
        expect(r / nodeSpacing,
            closeTo((r / nodeSpacing).roundToDouble(), 1e-6));
        if (d > 1) expect(r, greaterThan(radii[d - 1]!));
      }
      // Without other parts, the centre is at the origin of radialPart.
      final part = radialPart('r', drawn.neighbours);
      expect(part['r'], const Point(0.0, 0.0));
    });

    test('the nodes of a ring keep nodeSpacing apart', () {
      for (var d = 1; d <= 3; d++) {
        final ring = [
          for (final MapEntry(:key, :value) in depth.entries)
            if (value == d) key,
        ];
        for (var i = 0; i < ring.length; i++) {
          for (var j = i + 1; j < ring.length; j++) {
            expect(p[ring[i]]!.distanceTo(p[ring[j]]!),
                greaterThanOrEqualTo(nodeSpacing - 0.001),
                reason: '${ring[i]} ${ring[j]}');
          }
        }
      }
    });

    test("a parent's children are in its wedge", () {
      // a1 has three leaves below it, a2 one: a1's wedge is 3/4 of the
      // circle, a2's 1/4, and each sits in the middle of its wedge, so
      // they are half a turn apart.
      double turn(String id) => (angleOf(id) - angleOf('a1')) % (2 * pi);
      final a2 = turn('a2');
      expect(a2, closeTo(pi, 0.001));
      // Seen from a1, its children are within 3/8 of a turn on either
      // side, and b4 is in the middle of a2's wedge.
      for (final child in ['b1', 'b2', 'b3', 'c1']) {
        final t = turn(child);
        final side = t > pi ? 2 * pi - t : t;
        expect(side, lessThanOrEqualTo(3 * pi / 4 + 0.001), reason: child);
      }
      expect(turn('b4'), closeTo(a2, 0.001));
      // c1, b1's only child, is at b1's angle.
      expect(turn('c1'), closeTo(turn('b1'), 0.001));
    });

    test('parts not connected are beside the rings, not on them', () {
      final ringIds = depth.keys;
      final box = Rectangle.fromPoints(
        Point(ringIds.map((id) => p[id]!.x).reduce(min),
            ringIds.map((id) => p[id]!.y).reduce(min)),
        Point(ringIds.map((id) => p[id]!.x).reduce(max),
            ringIds.map((id) => p[id]!.y).reduce(max)),
      );
      for (final id in ['x', 'y', 'z']) {
        expect(box.containsPoint(p[id]!), isFalse, reason: id);
      }
      expect(p['x']!.distanceTo(p['y']!), closeTo(nodeSpacing, 0.001));
    });

    test('without a centre, the node with the most links', () {
      expect(radialCentre(drawn, null), 'a1');
      expect(radialCentre(drawn, 'gone'), 'a1');
      expect(radialCentre(drawn, 'b4'), 'b4');
      final layout = layoutGraph(drawn, LayoutKind.radial);
      final a1 = layout.positions['a1']!;
      for (final id in ['r', 'b1', 'b2', 'b3']) {
        expect(layout.positions[id]!.distanceTo(a1),
            closeTo(layout.positions['r']!.distanceTo(a1), 0.001),
            reason: id);
      }
    });

    test('a graph of one node', () {
      final single = whole(['a'], []);
      final layout = layoutGraph(single, LayoutKind.radial, centre: 'a');
      expectInside(single, layout);
      expect(layout.positions['a'], const Point(layoutMargin, layoutMargin));
    });

    test('a long chain keeps its rings apart', () {
      final chain = [for (var i = 0; i < 2000; i++) 'n$i'];
      final layout = layoutGraph(
        whole(chain, [for (var i = 1; i < 2000; i++) 'n${i - 1}>n$i']),
        LayoutKind.radial,
        centre: 'n0',
      );
      expect(layout.positions['n1999']!.distanceTo(layout.positions['n0']!),
          closeTo(1999 * nodeSpacing, 0.01));
    });
  });

  group('grouped by communities (#154)', () {
    /// Two groups of four that all link to each other, joined by a1 to b1,
    /// and z without links.
    final ids = ['a1', 'a2', 'a3', 'a4', 'b1', 'b2', 'b3', 'b4', 'z'];
    final links = [
      for (final g in ['a', 'b'])
        for (var i = 1; i <= 4; i++)
          for (var j = i + 1; j <= 4; j++) '$g$i>$g$j',
      'a1>b1',
    ];
    final drawn = whole(ids, links);
    final communities = {
      for (final id in ids) id: id.startsWith('a') ? 0 : (id == 'z' ? 2 : 1),
    };

    Rectangle<double> boxOf(GraphLayout layout, Iterable<String> group) {
      final points = [for (final id in group) layout.positions[id]!];
      return Rectangle.fromPoints(
        Point(points.map((p) => p.x).reduce(min),
            points.map((p) => p.y).reduce(min)),
        Point(points.map((p) => p.x).reduce(max),
            points.map((p) => p.y).reduce(max)),
      );
    }

    test('groups: large communities first, the small ones together last', () {
      expect(communityGroups(drawn, communities), [
        ['a1', 'a2', 'a3', 'a4'],
        ['b1', 'b2', 'b3', 'b4'],
        ['z'],
      ]);
      // Two communities of two and one of one share an area; a node
      // without a community goes there too.
      final small = {
        'a1': 0, 'a2': 0, 'a3': 0, 'a4': 0, //
        'b1': 1, 'b2': 1, 'b3': 2, 'b4': 2,
      };
      expect(communityGroups(drawn, small), [
        ['a1', 'a2', 'a3', 'a4'],
        ['b1', 'b2', 'b3', 'b4', 'z'],
      ]);
    });

    test('each community in its own area; the areas do not overlap', () {
      final layout =
          layoutGraph(drawn, LayoutKind.communities, communities: communities);
      expectInside(drawn, layout);
      final a = boxOf(layout, ['a1', 'a2', 'a3', 'a4']);
      final b = boxOf(layout, ['b1', 'b2', 'b3', 'b4']);
      final z = boxOf(layout, ['z']);
      expect(a.intersects(b), isFalse);
      expect(a.intersects(z), isFalse);
      expect(b.intersects(z), isFalse);
      expect(closest(layout), greaterThan(10));
    });

    test('the same graph gives the same layout', () {
      final first =
          layoutGraph(drawn, LayoutKind.communities, communities: communities);
      final again =
          layoutGraph(drawn, LayoutKind.communities, communities: communities);
      expect(again.positions, first.positions);
    });

    test('one community: the force-directed layout of it', () {
      final one = {for (final id in ids) id: 0};
      final grouped =
          layoutGraph(drawn, LayoutKind.communities, communities: one);
      final force = layoutGraph(drawn, LayoutKind.force);
      for (final id in ids) {
        expect(grouped.positions[id]!.x,
            closeTo(force.positions[id]!.x, 1e-6), reason: id);
        expect(grouped.positions[id]!.y,
            closeTo(force.positions[id]!.y, 1e-6), reason: id);
      }
    });

    test('isolated nodes are placed, also without communities given', () {
      final lonely = whole(['x', 'y', 'z'], []);
      final layout = layoutGraph(lonely, LayoutKind.communities);
      expectInside(lonely, layout);
      expect(closest(layout), greaterThan(10));
    });

    test('without communities given, Louvain on the drawn graph', () {
      final groups = communityGroups(drawn, drawnCommunities(drawn));
      expect(groups.take(2).map((g) => g.toSet()).toSet(), {
        {'a1', 'a2', 'a3', 'a4'},
        {'b1', 'b2', 'b3', 'b4'},
      });
      expect(groups.last, ['z']);
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
