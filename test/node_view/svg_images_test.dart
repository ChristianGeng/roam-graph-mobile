import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/note_images.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;
import 'note_images_test.dart' show FakeNoteFiles;

/// Synthetic SVGs (decision 14): black lines on a transparent 40 by 20
/// drawing, and one cut off in the middle.
Uint8List fixture(String name) =>
    File('test/fixtures/images/$name').readAsBytesSync();

void main() {
  /// Shows a note with [text] whose folder holds [files], and waits until
  /// its SVGs are compiled, which happens on another isolate.
  Future<void> show(WidgetTester tester, String text, FakeNoteFiles files,
      {Brightness brightness = Brightness.light}) async {
    final note = ':PROPERTIES:\n:ID: n\n:END:\n#+title: N\n$text';
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: NodeScreen(
        graph: ValueNotifier(graphOf({'n.org': note})),
        id: 'n',
        readNote: (path) async => note,
        files: files,
        nodeMemory: MemoryNodeMemory(),
      ),
    ));
    await tester.pumpAndSettle();
    // Until each SVG is drawn or shown as broken, at most 10 seconds.
    bool pending() =>
        find.byType(FolderSvg).evaluate().length >
        find.byType(FittedBox).evaluate().length +
            find.byType(BrokenImage).evaluate().length;
    for (var i = 0; i < 200 && pending(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  // Other URIs in each test: a drawing still pending in one test's fake
  // async zone would never finish in the next.
  var tests = 0;
  FakeNoteFiles svgFiles(String name) => FakeNoteFiles(['img/$name'],
      contents: {'img/$name': fixture(name)},
      uriPrefix: 'content://${tests++}/');

  testWidgets('an SVG is drawn at its own size', (tester) async {
    final files = svgFiles('lines-40x20.svg');
    await show(tester, '[[file:./img/lines-40x20.svg]]\n', files);
    expect(files.reads, ['img/lines-40x20.svg']);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(BrokenImage), findsNothing);
    expect(tester.getSize(find.byType(FittedBox)), const Size(40, 20));
  });

  testWidgets(':width 120px draws it 120 pixels wide, in proportion',
      (tester) async {
    final files = svgFiles('lines-40x20.svg');
    await show(tester,
        '#+ATTR_ORG: :width 120px\n[[file:./img/lines-40x20.svg]]\n', files);
    expect(tester.getSize(find.byType(FittedBox)), const Size(120, 60));
  });

  testWidgets('never wider than the text column', (tester) async {
    final files = svgFiles('lines-40x20.svg');
    await show(tester,
        '#+ATTR_ORG: :width 5000\n[[file:./img/lines-40x20.svg]]\n', files);
    final size = tester.getSize(find.byType(FittedBox));
    expect(size.width, lessThan(tester.view.physicalSize.width));
    expect(size.width / size.height, closeTo(2, 0.01));
  });

  testWidgets('a broken SVG shows the link with an icon', (tester) async {
    final files = svgFiles('broken.svg');
    await show(tester, '[[file:./img/broken.svg]]\n', files);
    expect(find.byType(BrokenImage), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });

  testWidgets('in dark mode, an SVG is on a light background',
      (tester) async {
    bool onWhite() => find
        .ancestor(
          of: find.byType(FittedBox),
          matching: find.byWidgetPredicate(
              (w) => w is ColoredBox && w.color == Colors.white),
        )
        .evaluate()
        .isNotEmpty;

    await show(tester, '[[file:./img/lines-40x20.svg]]\n',
        svgFiles('lines-40x20.svg'),
        brightness: Brightness.dark);
    expect(onWhite(), isTrue);
    await show(tester, '[[file:./img/lines-40x20.svg]]\n',
        svgFiles('lines-40x20.svg'));
    expect(onWhite(), isFalse);
  });

  testWidgets('tapping an SVG shows it alone, with zoom', (tester) async {
    final files = svgFiles('lines-40x20.svg');
    await show(tester, '[[file:./img/lines-40x20.svg]]\n', files);
    await tester.tap(find.byType(SvgPicture));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(InteractiveViewer),
            matching: find.byType(SvgPicture)),
        findsOneWidget);
  });

  testWidgets('an SVG is compiled once, and again when it changes',
      (tester) async {
    final files = FakeNoteFiles(['img/c.svg'],
        contents: {'img/c.svg': fixture('lines-40x20.svg')});
    const unknown = FolderFile(path: 'img/c.svg', uri: 'content://c');
    await tester.runAsync(() async {
      await compiledSvg(unknown, files);
      await compiledSvg(unknown, files);
      expect(files.reads, ['img/c.svg']);
      // A scan, for a file without a modification time.
      files.scan++;
      await compiledSvg(unknown, files);
      expect(files.reads, ['img/c.svg', 'img/c.svg']);
    });
  });

  testWidgets('an SVG that could not be read is read again', (tester) async {
    final files = FakeNoteFiles(['img/u.svg'],
        unreadable: {'img/u.svg'},
        contents: {'img/u.svg': fixture('lines-40x20.svg')});
    final file = files.files['img/u.svg']!;
    await tester.runAsync(() async {
      await expectLater(compiledSvg(file, files), throwsStateError);
      files.unreadable.clear();
      expect(await compiledSvg(file, files), isNotNull);
    });
  });
}
