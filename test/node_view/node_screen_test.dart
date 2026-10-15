import 'package:material_ui/material_ui.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';

import '../graph/graph_scope_test.dart' show fixtureGraph;
import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;

/// A: a file node that links to B, to its own heading H, to a missing
/// note and to a web page. B: a file with a heading node P, and a link to
/// A under a heading that is no node. C: links to A at the top.
const notes = {
  'a.org': ':PROPERTIES:\n:ID: a\n:END:\n#+title: A\n'
      'Some text of A, [[id:b][to Bee]] and [[id:h][the heading]].\n'
      'Also [[id:gone][a lost note]] and [[https://example.com][the web]].\n'
      '* H\n:PROPERTIES:\n:ID: h\n:END:\nText under H.\n',
  'b.org': ':PROPERTIES:\n:ID: b\n:END:\n#+title: B\nTop text of B.\n'
      'Jump to [[*Part][the part]] or [[*Other][the other]].\n'
      '* Part\n:PROPERTIES:\n:ID: p\n:END:\nPart text.\n'
      '** Deeper\nDeeper text.\n'
      '* Other\nOther text, [[id:a][back to A]].\n',
  'c.org': ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\nSee [[id:a][A]].\n',
};

RoamGraph graphOf(Map<String, String> texts) => RoamGraph.fromFiles([
      for (final MapEntry(:key, :value) in texts.entries)
        parseRoamFile(key, value),
    ]);

/// Text inside the rendered Org, which is rich text.
Finder orgText(String text) => find.textContaining(text, findRichText: true);

Future<MemoryNodeMemory> open(
  WidgetTester tester,
  String id, {
  ValueNotifier<RoamGraph>? graph,
  Map<String, String> texts = notes,
  void Function(BuildContext, String)? onShowInGraph,
  NoteOpener? openInOrgro,
}) async {
  final memory = MemoryNodeMemory();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => NodeScreen.open(
              context,
              graph: graph ?? ValueNotifier(graphOf(notes)),
              id: id,
              readNote: (path) async => texts[path],
              nodeMemory: memory,
              onShowInGraph: onShowInGraph,
              openInOrgro: openInOrgro,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return memory;
}

/// The title in the app bar.
Finder title(String text) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(text));

void main() {
  testWidgets('a file node shows the whole file, and is remembered',
      (tester) async {
    final memory = await open(tester, 'a');

    expect(title('A'), findsOneWidget);
    expect(orgText('Some text of A'), findsOneWidget);
    expect(orgText('Text under H.'), findsOneWidget);
    expect(memory.id, 'a');
  });

  testWidgets('a heading node shows its heading and subtree only',
      (tester) async {
    await open(tester, 'p');

    expect(title('Part'), findsOneWidget);
    expect(orgText('Part text.'), findsOneWidget);
    expect(orgText('Deeper text.'), findsOneWidget);
    expect(orgText('Top text of B.'), findsNothing);
    expect(orgText('Other text'), findsNothing);
  });

  testWidgets('an id: link opens its node, and Back returns', (tester) async {
    final memory = await open(tester, 'a');

    await tester.tapOnText(find.textRange.ofSubstring('to Bee'));
    await tester.pumpAndSettle();
    expect(title('B'), findsOneWidget);
    expect(orgText('Top text of B.'), findsOneWidget);
    expect(memory.id, 'b');

    // And on from B, back to A through its link under Other.
    await tester.tapOnText(find.textRange.ofSubstring('back to A'));
    await tester.pumpAndSettle();
    expect(title('A'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title('B'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title('A'), findsOneWidget);
  });

  testWidgets('a link to a heading of the same file opens that node',
      (tester) async {
    await open(tester, 'a');

    await tester.tapOnText(find.textRange.ofSubstring('the heading'));
    await tester.pumpAndSettle();
    expect(title('H'), findsOneWidget);
    expect(orgText('Text under H.'), findsOneWidget);
    expect(orgText('Some text of A'), findsNothing);
  });

  testWidgets('a [[*Heading]] link opens the heading if it is a node',
      (tester) async {
    await open(tester, 'b');

    await tester.tapOnText(find.textRange.ofSubstring('the other'));
    await tester.pump();
    expect(find.text('This heading is no node, so the app cannot open it.'),
        findsOneWidget);
    expect(title('B'), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('the part'));
    await tester.pumpAndSettle();
    expect(title('Part'), findsOneWidget);
  });

  testWidgets('a link to a missing note or a web page says so',
      (tester) async {
    await open(tester, 'a');

    await tester.tapOnText(find.textRange.ofSubstring('a lost note'));
    await tester.pump();
    expect(find.text('There is no node with the ID gone.'), findsOneWidget);
    expect(title('A'), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('the web'));
    await tester.pump();
    expect(
      find.text('This app opens only id: links, not "https://example.com".'),
      findsOneWidget,
    );
  });

  testWidgets('the backlinks, as org-roam lists them, open their nodes',
      (tester) async {
    await open(tester, 'a');

    expect(find.text('Backlinks: 2'), findsOneWidget);
    // Sorted by title; B's link is under the heading Other.
    expect(
      tester.widget<ListTile>(find.byKey(const ValueKey('backlink-0'))).title,
      isA<Text>().having((t) => t.data, 'title', 'B'),
    );
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Top'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('backlink-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backlink-1')));
    await tester.pumpAndSettle();
    expect(title('C'), findsOneWidget);
    expect(find.text('No backlinks'), findsOneWidget);
  });

  testWidgets('"Show in graph" hands over the node', (tester) async {
    String? shown;
    await open(tester, 'b', onShowInGraph: (_, id) => shown = id);

    await tester.tap(find.byTooltip('Show in graph'));
    expect(shown, 'b');
  });

  testWidgets('without the graph view, there is no "Show in graph"',
      (tester) async {
    await open(tester, 'b');
    expect(find.byTooltip('Show in graph'), findsNothing);
  });

  group('"Open in Orgro"', () {
    testWidgets('a file node opens its file, without a message',
        (tester) async {
      final opened = <String>[];
      await open(tester, 'b', openInOrgro: (path) async {
        opened.add(path);
        return OpenResult.opened;
      });
      await tester.tap(find.byTooltip('Open in Orgro'));
      await tester.pump();
      expect(opened, ['b.org']);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a heading node opens its file at the top, and says so',
        (tester) async {
      final opened = <String>[];
      await open(tester, 'p', openInOrgro: (path) async {
        opened.add(path);
        return OpenResult.opened;
      });
      await tester.tap(find.byTooltip('Open in Orgro'));
      await tester.pump();
      expect(opened, ['b.org']);
      expect(
          find.text('Orgro opens b.org at the top; '
              'it cannot jump to the heading.'),
          findsOneWidget);
    });

    testWidgets('a file that is not in the folder', (tester) async {
      await open(tester, 'a',
          openInOrgro: (path) async => OpenResult.noFile);
      await tester.tap(find.byTooltip('Open in Orgro'));
      await tester.pump();
      expect(find.text('Could not find a.org in the folder.'), findsOneWidget);
    });

    testWidgets('no button without a way to open files', (tester) async {
      await open(tester, 'a');
      expect(find.byTooltip('Open in Orgro'), findsNothing);
    });
  });

  testWidgets('a file that cannot be read', (tester) async {
    await open(tester, 'a', texts: const {});
    expect(find.text('Could not read a.org.'), findsOneWidget);
    expect(find.text('Backlinks: 2'), findsOneWidget);
  });

  testWidgets('a new graph: the file is read again, or the node is gone',
      (tester) async {
    final graph = ValueNotifier(graphOf(notes));
    final texts = Map.of(notes);
    await open(tester, 'c', graph: graph, texts: texts);
    expect(orgText('See A'), findsOneWidget);

    texts['c.org'] = ':PROPERTIES:\n:ID: c\n:END:\n#+title: C\nChanged.\n';
    graph.value = graphOf(texts);
    await tester.pumpAndSettle();
    expect(orgText('Changed.'), findsOneWidget);

    graph.value = graphOf({'a.org': notes['a.org']!});
    await tester.pumpAndSettle();
    expect(find.text('This node no longer exists.'), findsOneWidget);
  });

  testWidgets('every node of the sample files renders', (tester) async {
    final graph = fixtureGraph();
    final texts = {
      for (final path in graph.files)
        path: File('test/fixtures/roam/$path').readAsStringSync(),
    };
    for (final node in graph.nodes.values) {
      await tester.pumpWidget(MaterialApp(
        home: NodeScreen(
          key: ValueKey(node.id),
          graph: ValueNotifier(graph),
          id: node.id,
          readNote: (path) async => texts[path],
          nodeMemory: MemoryNodeMemory(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: node.file);
      expect(find.textContaining('Could not read'), findsNothing);
      // org_parser finds every heading node that org-roam found.
      expect(find.textContaining('is no longer in'), findsNothing,
          reason: node.id);
    }
  });
}
