import 'dart:io';
import 'dart:ui' show PictureRecorder;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mermaid_flutter/mermaid_flutter.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/note_images.dart';
import 'package:roam_graph_mobile/node_view/plantuml.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;
import 'note_images_test.dart' show FakeNoteFiles, shownText;

// Synthetic diagrams (decision 14: no real notes in tests).
final _fixture = File('test/fixtures/plantuml.org').readAsStringSync();

/// The text under the top-level heading [title] of the fixture, without
/// the heading line.
String section(String title) {
  final start = _fixture.indexOf('\n* $title\n');
  expect(start, isNot(-1), reason: 'no section "$title" in the fixture');
  final body = start + '\n* $title\n'.length;
  final end = _fixture.indexOf('\n* ', body);
  return _fixture.substring(body, end == -1 ? null : end + 1);
}

/// The sources of the drawings [withPlantumlDrawings] adds to [text], in
/// order, with [shown] the image locations the node view shows.
List<String> drawingsIn(String text, {Set<String> shown = const {}}) {
  final document = withPlantumlDrawings(OrgDocument.parse(text),
      showsImage: shown.contains);
  final sources = <String>[];
  document.visit<OrgLink>((link) {
    final drawing = loadPlantumlDrawing(link);
    if (drawing is PlantumlDrawing) sources.add(drawing.source);
    return true;
  });
  return sources;
}

void main() {
  group('which blocks are drawn', () {
    test('blocks without a result image, each with its own source', () {
      final sources = [
        for (final title in ['Sequence', 'State', 'Mindmap'])
          ...drawingsIn(section(title)),
      ];
      expect(sources, hasLength(3));
      expect(sources[0], startsWith('@startuml\nactor User\n'));
      expect(sources[1], contains('[*] --> Idle'));
      // Org's comma escapes are removed, as ob-plantuml does.
      expect(sources[2], '@startmindmap\n* Garden\n** Vegetables\n'
          '*** Beans\n** Flowers\n@endmindmap\n');
    });

    test('a block whose result image is in the folder is not drawn', () {
      expect(
          drawingsIn(section('Result image present'),
              shown: {'file:./img/sequence.png'}),
          isEmpty);
    });

    test('a block whose result image is missing is drawn', () {
      expect(drawingsIn(section('Result image missing')), hasLength(1));
    });

    test('only plantuml blocks, by their name as written, as in Emacs', () {
      expect(drawingsIn(section('Other spellings')), isEmpty);
      // Mermaid blocks are left to the Mermaid pass.
      expect(drawingsIn(section('Both languages')),
          ['@startuml\nAlice -> Bob : hello\n@enduml\n']);
    });

    test('a link the note writes with the drawing\'s location stays a link',
        () {
      final document = OrgDocument.parse('[[plantuml-drawing.png]]\n');
      document.visit<OrgLink>((link) {
        expect(loadPlantumlDrawing(link), isNull);
        return true;
      });
    });
  });

  group('the source PlantUML gets', () {
    test('@startuml and @enduml are added when the block has no @start line',
        () {
      expect(plantumlSource('A -> B\n'), '@startuml\nA -> B\n@enduml\n');
      expect(plantumlSource('A -> B'), '@startuml\nA -> B\n@enduml\n');
      const own = '@startuml\nA -> B\n@enduml\n';
      expect(plantumlSource(own), own);
      // Any @start line, in any case, as org-babel-plantuml-make-body.
      const mindmap = '@StartMindmap\n* A\n@endmindmap\n';
      expect(plantumlSource(mindmap), mindmap);
    });

    test('a source that cannot be drawn gives an error, not a crash', () {
      final drawn = drawPlantuml(drawingsIn(section('Broken')).single);
      expect(drawn.scene, isNull);
      expect(drawn.error, isNotNull);
      expect(drawPlantuml('').scene, isNull);
    });

    test('a source that is too large is not drawn, and says so', () {
      final huge = 'A -> B : x\n' * (maxPlantumlSource ~/ 10);
      final drawn = drawPlantuml(huge);
      expect(drawn.scene, isNull);
      expect('${drawn.error}', contains('too large'));
    });

    test('a source whose macros expand too far is not drawn', () {
      final body = 'A -> B : x ' * 200;
      final source = '@startuml\n!define BIG $body\n'
          '${'BIG\n' * 100}@enduml\n';
      expect(source.length, lessThan(maxPlantumlSource));
      final drawn = drawPlantuml(source);
      expect(drawn.scene, isNull);
      expect('${drawn.error}', contains('after its macros are expanded'));
    });

    test('an error line gives the line in the block, or none', () {
      // No directive: the parser's line is the block's line.
      expect(errorLineOf('@startuml\nA -> B\n/\''), endsWith('(line 3)'));
      // A directive line is removed before the lexer counts: no number.
      expect(errorLineOf('@startuml\n!define UNUSED 1\n/\''),
          isNot(contains('(line')));
    });

    test('a drawing is laid out once for each source', () {
      final source = drawingsIn(section('State')).single;
      final first = drawPlantuml(source);
      expect(first.scene, isNotNull);
      expect(identical(drawPlantuml(source).scene, first.scene), isTrue);
    });
  });

  testWidgets('the painter paints the diagram', (tester) async {
    final scene = drawPlantuml(drawingsIn(section('State')).single).scene!;
    final width = scene.size.width.ceil(), height = scene.size.height.ceil();
    final painted = await tester.runAsync(() async {
      final recorder = PictureRecorder();
      PlantumlPainter(scene).paint(Canvas(recorder), scene.size);
      final image = await recorder.endRecording().toImage(width, height);
      final bytes = await image.toByteData();
      image.dispose();
      return bytes!;
    });
    // Some pixel is not transparent: lines, boxes or text were drawn.
    final pixels = painted!.buffer.asUint32List();
    expect(pixels.any((pixel) => pixel != 0), isTrue);
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

  Finder plantumlPaints() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is PlantumlPainter);
  Finder mermaidPaints() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ScenePainter);
  Finder lightCard() => find.byWidgetPredicate((w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).color == plantumlCardColor &&
      (w.decoration as BoxDecoration).borderRadius != null);

  testWidgets('a block without a result image is drawn below it, marked',
      (tester) async {
    await show(tester, section('Sequence'), files: FakeNoteFiles([]));
    expect(plantumlPaints(), findsOneWidget);
    expect(find.text('Drawn on the device'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    // The source block stays, above the drawing and the text after it.
    final text = shownText(tester);
    expect(text, contains('User -> W : open page'));
    expect(text.indexOf('open page'),
        lessThan(text.indexOf('After the sequence.')));
    final block = tester.getTopLeft(find.textContaining('open page').first);
    expect(tester.getTopLeft(plantumlPaints()).dy, greaterThan(block.dy));
  });

  testWidgets('state and mindmap diagrams are drawn too', (tester) async {
    for (final title in ['State', 'Mindmap']) {
      await show(tester, section(title));
      expect(plantumlPaints(), findsOneWidget, reason: title);
      expect(find.byIcon(Icons.error_outline), findsNothing, reason: title);
    }
  });

  testWidgets('the result image is shown, and no drawing', (tester) async {
    await show(tester, section('Result image present'),
        files: FakeNoteFiles(['img/sequence.png']));
    expect(find.byType(Image), findsOneWidget);
    expect(plantumlPaints(), findsNothing);
    expect(find.text('Drawn on the device'), findsNothing);
  });

  testWidgets('a result image that is not in the folder: drawn',
      (tester) async {
    await show(tester, section('Result image missing'),
        files: FakeNoteFiles([]));
    expect(find.byType(Image), findsNothing);
    expect(plantumlPaints(), findsOneWidget);
  });

  testWidgets('a diagram that cannot be drawn shows one line with the error',
      (tester) async {
    await show(tester, section('Broken'));
    expect(plantumlPaints(), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    final error = tester
        .widget<Text>(find.textContaining('PlantUML cannot draw this: '));
    expect(error.maxLines, 1);
    // puml_canvas's message, with the line in the block.
    expect(error.data, contains('(line '));
    expect(shownText(tester), contains('After the broken one.'));
  });

  testWidgets('a block without @startuml is drawn, as Emacs runs it',
      (tester) async {
    await show(tester, section('Without startuml'));
    expect(plantumlPaints(), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('in the dark theme the drawing is on a light card',
      (tester) async {
    await show(tester, section('Sequence'), mode: ThemeMode.dark);
    expect(lightCard(), findsOneWidget);
    expect(find.descendant(of: lightCard(), matching: plantumlPaints()),
        findsOneWidget);
    // The card has a margin around the drawing.
    final card = tester.getSize(lightCard());
    final drawing = tester.getSize(plantumlPaints());
    expect(card.width, greaterThan(drawing.width));
    expect(card.height, greaterThan(drawing.height));

    await show(tester, section('Sequence'), mode: ThemeMode.light);
    expect(plantumlPaints(), findsOneWidget);
    expect(lightCard(), findsNothing);
  });

  testWidgets('a mermaid and a plantuml block in one note are both drawn',
      (tester) async {
    await show(tester, section('Both languages'), files: FakeNoteFiles([]));
    expect(mermaidPaints(), findsOneWidget);
    expect(plantumlPaints(), findsOneWidget);
    expect(find.text('Drawn on the device'), findsNWidgets(2));
    // Each below its own block: the mermaid drawing first.
    expect(tester.getTopLeft(mermaidPaints()).dy,
        lessThan(tester.getTopLeft(plantumlPaints()).dy));
    // Mermaid still uses its own dark theme, not the card.
    await show(tester, section('Both languages'), mode: ThemeMode.dark);
    expect(lightCard(), findsOneWidget);
    expect(find.descendant(of: lightCard(), matching: mermaidPaints()),
        findsNothing);
  });

  testWidgets('tapping a drawing shows it alone, with zoom', (tester) async {
    await show(tester, section('Sequence'));
    await tester.tap(plantumlPaints());
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('PlantUML diagram'), findsOneWidget);
    expect(plantumlPaints(), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
