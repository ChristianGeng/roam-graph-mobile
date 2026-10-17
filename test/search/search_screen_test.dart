import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';
import 'package:roam_graph_mobile/graph/roam_db.dart' show TextHit;
import 'package:roam_graph_mobile/graph/roam_graph.dart';
import 'package:roam_graph_mobile/node_view/note_images.dart' show NoteFiles;
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/search/search_screen.dart';

import '../graph/node_search_test.dart' show graph;
import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../node_view/note_images_test.dart' show FakeNoteFiles;

Future<MemoryNodeMemory> open(
  WidgetTester tester, {
  RoamGraph? of,
  void Function(BuildContext, String)? onShowInGraph,
  TextSharer? shareText,
  NoteFiles? files,
}) async {
  final memory = MemoryNodeMemory();
  await tester.pumpWidget(MaterialApp(
    home: SearchScreen(
      graph: ValueNotifier(of ?? graph),
      readNote: (path) async => 'Text of $path.',
      nodeMemory: memory,
      onShowInGraph: onShowInGraph,
      shareText: shareText ?? (text, {subject}) async {},
      files: files,
    ),
  ));
  await tester.pumpAndSettle();
  return memory;
}

/// The titles of the results, in order.
List<String> results(WidgetTester tester) => [
      for (final tile in tester.widgetList<ListTile>(find.descendant(
          of: find.byKey(const ValueKey('hits')),
          matching: find.byType(ListTile))))
        (tile.title! as Text).data!,
    ];

void main() {
  testWidgets('"In the text" finds words in the notes (#98)', (tester) async {
    await open(tester);
    // Without the folder's index there is no text search.
    expect(find.byKey(const ValueKey('search-in-text')), findsNothing);

    final files = FakeNoteFiles(const [])
      ..hits = const [
        TextHit('flutter.org', 'widgets  and\n state'),
        TextHit('gone.org', 'not in the graph'),
      ];
    await open(tester, files: files);
    await tester.tap(find.byKey(const ValueKey('search-in-text')));
    await tester.pump();
    expect(find.text('Type words to find in the notes.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'state');
    await tester.pumpAndSettle();
    expect(find.text('1 note'), findsOneWidget);
    expect(find.text('Flutter and Dart'), findsOneWidget);
    expect(find.text('widgets and state'), findsOneWidget);
    expect(find.text('not in the graph'), findsNothing);
  });

  testWidgets('finds as you type, and the field has the focus',
      (tester) async {
    await open(tester);
    expect(find.text('6 results'), findsOneWidget);

    // No tap on the field first: it has the focus.
    await tester.enterText(find.byType(TextField), 'li');
    await tester.pump();
    expect(results(tester), ['Emacs Lisp basics', 'Old notes on lisp']);

    await tester.enterText(find.byType(TextField), 'lisp OLD');
    await tester.pump();
    expect(results(tester), ['Old notes on lisp']);
    expect(find.text('1 result'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.text('6 results'), findsOneWidget);
  });

  testWidgets('an alias says whose it is', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'zettel');
    await tester.pump();
    expect(results(tester), ['Zettelkasten']);
    expect(find.text('Alias of Org-roam setup · emacs'), findsOneWidget);
  });

  testWidgets('tag chips filter the results', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'code'));
    await tester.pump();
    expect(results(tester), ['Emacs Lisp basics', 'Flutter and Dart']);

    await tester.tap(find.widgetWithText(FilterChip, 'emacs'));
    await tester.pump();
    expect(results(tester), ['Emacs Lisp basics']);

    await tester.tap(find.widgetWithText(FilterChip, 'code'));
    await tester.pump();
    expect(results(tester),
        ['Emacs Lisp basics', 'Org-roam setup', 'Zettelkasten']);
  });

  testWidgets('a result opens the node view and is remembered',
      (tester) async {
    final memory = await open(tester);
    await tester.enterText(find.byType(TextField), 'flutter');
    await tester.pump();
    await tester.tap(find.text('Flutter and Dart'));
    await tester.pumpAndSettle();

    expect(find.byType(NodeScreen), findsOneWidget);
    expect(
        find.textContaining('Text of flutter.org.', findRichText: true),
        findsOneWidget);
    expect(memory.id, 'flutter');
  });

  testWidgets('Enter opens the first result', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'setup');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text('Org-roam setup')),
        findsOneWidget);
  });

  testWidgets('"Show in graph" hands over the node and remembers it',
      (tester) async {
    String? shown;
    final memory = await open(tester, onShowInGraph: (_, id) => shown = id);
    await tester.enterText(find.byType(TextField), 'zettel');
    await tester.pump();
    await tester.tap(find.byTooltip('Show in graph'));
    expect(shown, 'roam');
    expect(memory.id, 'roam');
  });

  testWidgets('without the graph view, no "Show in graph"', (tester) async {
    await open(tester);
    expect(find.byTooltip('Show in graph'), findsNothing);
  });

  testWidgets('long-press selects nodes; they are shared together (#41)',
      (tester) async {
    final shared = <String>[];
    await open(tester,
        shareText: (text, {subject}) async => shared.add(text));
    expect(find.byTooltip('Share with AI'), findsNothing);

    await tester.longPress(find.text('Flutter and Dart'));
    await tester.pump();
    // While selecting, a tap adds a node instead of opening it.
    await tester.tap(find.text('Emacs Lisp basics'));
    await tester.pump();
    expect(find.byType(NodeScreen), findsNothing);
    await tester.tap(find.byTooltip('Share with AI'));
    await tester.pump();

    final text = shared.single;
    expect(text, startsWith('# 2 notes from my org-roam graph'));
    expect(text, contains('## Flutter and Dart'));
    expect(text, contains('## Emacs Lisp basics'));
    expect(text, contains('Text of flutter.org.'));

    // A long press again unselects.
    await tester.longPress(find.text('Flutter and Dart'));
    await tester.longPress(find.text('Emacs Lisp basics'));
    await tester.pump();
    expect(find.byTooltip('Share with AI'), findsNothing);
  });
}
