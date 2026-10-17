import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mermaid_flutter/mermaid_flutter.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/mermaid.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/note_images.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;
import 'note_images_test.dart' show FakeNoteFiles, shownText;

// Synthetic diagrams (decision 14: no real notes in tests).
const flowchart = 'graph TD\n  A[Start] --> B[Stop]\n';

String block(String source, {String header = ''}) =>
    '#+begin_src mermaid$header\n$source#+end_src\n';

/// The sources of the drawings [withMermaidDrawings] adds to [text], in
/// order, with [shown] the image locations the node view shows.
List<String> drawingsIn(String text, {Set<String> shown = const {}}) {
  final document = withMermaidDrawings(OrgDocument.parse(text),
      showsImage: shown.contains);
  final sources = <String>[];
  document.visit<OrgLink>((link) {
    final drawing = loadMermaidDrawing(link);
    if (drawing is MermaidDrawing) sources.add(drawing.source);
    return true;
  });
  return sources;
}

void main() {
  group('which blocks are drawn', () {
    test('a block with a result image is not drawn', () {
      final text = '${block(flowchart, header: ' :file ./img/a.png')}\n'
          '#+RESULTS:\n[[file:./img/a.png]]\n';
      expect(drawingsIn(text, shown: {'file:./img/a.png'}), isEmpty);
      // A hash in the keyword, as with :cache yes.
      final cached = '${block(flowchart)}#+RESULTS[0f1e]:\n[[file:a.png]]\n';
      expect(drawingsIn(cached, shown: {'file:a.png'}), isEmpty);
    });

    test('a block without a result image is drawn', () {
      // Never run; run but its image is not in the folder; a result that
      // is no image; a result keyword not right after the block.
      expect(drawingsIn(block(flowchart)), [flowchart]);
      expect(
          drawingsIn('${block(flowchart)}\n#+RESULTS:\n[[file:./img/gone.png]]\n'),
          [flowchart]);
      expect(drawingsIn('${block(flowchart)}#+RESULTS:\n: some output\n'),
          [flowchart]);
      expect(
          drawingsIn('${block(flowchart)}Text.\n#+RESULTS:\n[[file:a.png]]\n',
              shown: {'file:a.png'}),
          [flowchart]);
    });

    test('the result image may follow another link in the paragraph', () {
      final text = '${block(flowchart)}#+RESULTS:\n'
          'See [[file:notes.org]] and [[file:a.png]]\n';
      expect(drawingsIn(text, shown: {'file:a.png'}), isEmpty);
    });

    test('a described result link is text, so the block is drawn', () {
      // org_flutter shows a link with a description as text, not as an
      // image.
      final text = '${block(flowchart)}#+RESULTS:\n[[file:a.png][diagram]]\n';
      expect(drawingsIn(text, shown: {'file:a.png'}), [flowchart]);
    });

    test('only mermaid blocks, by their name as written, as in Emacs', () {
      expect(drawingsIn('#+begin_src dot\ndigraph { a -> b }\n#+end_src\n'),
          isEmpty);
      expect(drawingsIn('#+begin_src Mermaid\n$flowchart#+end_src\n'), isEmpty);
    });

    test('several blocks, and Org\'s comma escapes removed', () {
      final escaped = 'graph TD\n  ,* A --> B\n';
      expect(drawingsIn('${block(flowchart)}\nText.\n\n${block(escaped)}'),
          [flowchart, 'graph TD\n  * A --> B\n']);
    });

    test('a link the note writes with the drawing\'s location stays a link',
        () {
      final document = OrgDocument.parse('[[mermaid-drawing.png]]\n');
      document.visit<OrgLink>((link) {
        expect(loadMermaidDrawing(link), isNull);
        return true;
      });
    });
  });

  Future<void> show(WidgetTester tester, String text,
      {NoteFiles? files, ThemeMode mode = ThemeMode.light}) async {
    final note = ':PROPERTIES:\n:ID: n\n:END:\n#+title: N\n$text';
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: mode,
      home: NodeScreen(
        graph: ValueNotifier(graphOf({'n.org': note})),
        id: 'n',
        readNote: (path) async => note,
        files: files,
        nodeMemory: MemoryNodeMemory(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Iterable<ScenePainter> painters(WidgetTester tester) => [
        for (final paint in tester.widgetList<CustomPaint>(find.byType(CustomPaint)))
          if (paint.painter case final ScenePainter painter) painter,
      ];

  testWidgets('the result image is shown, and no drawing', (tester) async {
    await show(
        tester,
        '${block(flowchart, header: ' :file ./img/a.png')}\n'
        '#+RESULTS:\n[[file:./img/a.png]]\n',
        files: FakeNoteFiles(['img/a.png']));
    expect(find.byType(Image), findsOneWidget);
    expect(painters(tester), isEmpty);
    expect(find.text('Drawn on the device'), findsNothing);
  });

  testWidgets('a block without a result image is drawn below it, marked',
      (tester) async {
    await show(tester, '${block(flowchart)}\nAfter.\n',
        files: FakeNoteFiles([]));
    expect(painters(tester), hasLength(1));
    expect(find.text('Drawn on the device'), findsOneWidget);
    // The source block stays, above the drawing.
    final text = shownText(tester);
    expect(text, contains('A[Start] --> B[Stop]'));
    expect(text.indexOf('A[Start]'), lessThan(text.indexOf('After.')));
  });

  testWidgets('drawn also without the folder\'s files', (tester) async {
    await show(tester, block(flowchart));
    expect(painters(tester), hasLength(1));
  });

  testWidgets('never wider than the text column', (tester) async {
    final wide = 'graph LR\n${[
      for (var i = 0; i < 30; i++) '  N$i[Node number $i] --> N${i + 1}[Node number ${i + 1}]\n',
    ].join()}';
    await show(tester, block(wide));
    final scene = painters(tester).single.scene;
    expect(scene.size.width, greaterThan(800));
    final shown = tester.getSize(find.byType(FittedBox).first);
    expect(shown.width, lessThanOrEqualTo(800));
  });

  testWidgets('a diagram that cannot be drawn shows one line with the error',
      (tester) async {
    await show(tester, '${block('graph TD\n  A -->\n')}\nAfter.\n');
    expect(painters(tester), isEmpty);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    final error = tester.widget<Text>(
        find.textContaining('Mermaid cannot draw this: '));
    expect(error.maxLines, 1);
    expect(shownText(tester), contains('After.'));
  });

  testWidgets('dark mode uses mermaid\'s dark theme, unless the block sets one',
      (tester) async {
    await show(tester, block(flowchart), mode: ThemeMode.dark);
    final dark = painters(tester).single.scene;
    expect(find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.white),
        findsNothing);
    await show(tester, block(flowchart), mode: ThemeMode.light);
    final light = painters(tester).single.scene;
    expect(identical(dark, light), isFalse);

    // Its own light theme: on white, so its dark lines can be read.
    await show(
        tester, block("%%{init: {'theme': 'default'}}%%\n$flowchart"),
        mode: ThemeMode.dark);
    expect(painters(tester), hasLength(1));
    expect(
        find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.white),
        findsOneWidget);
  });

  test('a drawing is laid out once for each source and theme', () {
    final first = drawMermaid(flowchart, dark: false);
    expect(identical(drawMermaid(flowchart, dark: false).scene, first.scene),
        isTrue);
    expect(identical(drawMermaid(flowchart, dark: true).scene, first.scene),
        isFalse);
  });

  testWidgets('tapping a drawing shows it alone, with zoom', (tester) async {
    await show(tester, block(flowchart));
    await tester.tap(find.byType(FittedBox).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Mermaid diagram'), findsOneWidget);
    expect(painters(tester), hasLength(1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
