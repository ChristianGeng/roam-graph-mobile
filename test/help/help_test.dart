import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/graph_view/graph_screen.dart';
import 'package:roam_graph_mobile/help/help.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph/graph_scope_test.dart' show fixtureGraph;
import '../graph_view/graph_screen_test.dart'
    show MemoryNodeMemory, algorithmsHere, layoutHere;

RoamGraph helpGraphFromDisk() => RoamGraph.fromFiles([
  for (final file in helpFiles)
    parseRoamFile(file, File('assets/help/$file').readAsStringSync()),
]);

/// The target of an `[[id:…][…]]` link in an Org text.
final idLink = RegExp(r'\[\[id:([^\]]+)\]');

/// The value of a `:ID:` property line.
final idLine = RegExp(r'^:ID:\s+(\S+)\s*$', multiLine: true);

/// Waits for a help page to open: its pages are read from the asset
/// bundle, which is real I/O outside the test's clock.
Future<void> settleHelp(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }
}

/// The title in the app bar.
Finder title(String text) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(text));

void main() {
  group('the pages', () {
    test('every file in assets/help is listed, and each is one node', () {
      final onDisk = [
        for (final f in Directory('assets/help').listSync())
          f.uri.pathSegments.last,
      ]..sort();
      expect(onDisk, [...helpFiles]..sort());
      for (final file in helpFiles) {
        final data = parseRoamFile(
          file,
          File('assets/help/$file').readAsStringSync(),
        );
        expect(data.error, isNull, reason: file);
        final pages = data.nodes.where((n) => n.isFile).toList();
        expect(pages, hasLength(1), reason: file);
        expect(pages.single.title, isNotEmpty, reason: file);
        // Headings with an ID are nodes too, so tasks can be linked to.
        // None has a UUID, so none can be the ID of one of my notes.
        for (final node in data.nodes) {
          expect(node.id, startsWith('roam-graph-help-'), reason: file);
        }
      }
    });

    test('every id: link points to a help page, and every page is linked', () {
      final help = helpGraphFromDisk();
      expect(
        help.nodes.values.where((n) => n.isFile),
        hasLength(helpFiles.length),
      );
      expect(
        help.danglingLinks,
        isEmpty,
        reason: [
          for (final l in help.danglingLinks) '${l.file}: ${l.dest}',
        ].join(', '),
      );
      final linked = {for (final l in help.links) l.dest};
      for (final id in help.nodes.keys) {
        if (id != helpStart) expect(linked, contains(id), reason: id);
      }
      for (final id in [helpStart, helpLayouts, helpViews]) {
        expect(help.nodes, contains(id));
      }
    });

    test('every [[id:…]] link in the text points to an ID that exists', () {
      final ids = <String>{};
      final dests = <String, List<String>>{};
      for (final file in helpFiles) {
        final text = File('assets/help/$file').readAsStringSync();
        ids.addAll([for (final m in idLine.allMatches(text)) m[1]!]);
        dests[file] = [for (final m in idLink.allMatches(text)) m[1]!];
      }
      for (final MapEntry(key: file, value: targets) in dests.entries) {
        for (final target in targets) {
          expect(ids, contains(target), reason: '$file links to $target');
        }
      }
    });

    test('the start page links to every page', () {
      final text = File('assets/help/start.org').readAsStringSync();
      final linked = {for (final m in idLink.allMatches(text)) m[1]!};
      final pages = helpGraphFromDisk().nodes.values.where((n) => n.isFile);
      for (final page in pages) {
        if (page.id != helpStart) {
          expect(linked, contains(page.id), reason: page.id);
        }
      }
    });

    test('the help is not part of my graph', () {
      final mine = fixtureGraph();
      expect(
        mine.nodes.keys.where((id) => id.startsWith('roam-graph-help-')),
        isEmpty,
      );
      expect(mine.files.where((f) => f.startsWith('assets/')), isEmpty);
    });
  });

  group('opening the help', () {
    Future<void> pumpGraph(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GraphScreen(
            graph: ValueNotifier(helpGraphFromDisk()),
            readNote: (path) async => null,
            nodeMemory: MemoryNodeMemory(helpStart),
            computeLayout: layoutHere,
            computeAlgorithms: algorithmsHere,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('"About the layouts" in the View menu; links work', (
      tester,
    ) async {
      await pumpGraph(tester);
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      // Near the end of the menu, below the screen of 800 by 600.
      await tester.ensureVisible(find.text('About the layouts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About the layouts'));
      await settleHelp(tester);
      expect(
        title('Layouts: circular, force-directed, radial, grouped, hierarchical'),
        findsOneWidget,
      );
      // A help page has no search and no AI menu.
      final page = find.byType(NodeScreen).last;
      expect(
        find.descendant(of: page, matching: find.byTooltip('Search')),
        findsNothing,
      );
      expect(
        find.descendant(of: page, matching: find.byTooltip('AI')),
        findsNothing,
      );
      // The link is at the end of the page.
      await tester.ensureVisible(
        find.textContaining('Back to the graph view', findRichText: true),
      );
      await tester.pumpAndSettle();
      await tester.tapOnText(find.textRange.ofSubstring('the graph view'));
      await tester.pumpAndSettle();
      expect(title('The graph view'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        title('Layouts: circular, force-directed, radial, grouped, hierarchical'),
        findsOneWidget,
      );
    });

    testWidgets('"About the views" in the View menu; Help in More', (
      tester,
    ) async {
      await pumpGraph(tester);
      await tester.tap(find.byTooltip('View'));
      await tester.pumpAndSettle();
      // The last item of the menu, below the screen of 800 by 600.
      await tester.ensureVisible(find.text('About the views'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About the views'));
      await settleHelp(tester);
      expect(
        title('Graph views: communities, importance, paths'),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Help'));
      await settleHelp(tester);
      expect(title('Roam Graph help'), findsOneWidget);
    });
  });
}
