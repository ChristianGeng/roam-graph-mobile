import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/capture/share_out.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/note_images.dart';
import 'package:roam_graph_mobile/node_view/share_note.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;
import 'note_images_test.dart' show FakeNoteFiles, png;

/// A synthetic note: a drawer, an ID, keywords, links, an infographic with
/// a caption, a data table and a source line, and a second picture.
const pics = ':PROPERTIES:\n:ID: pics\n:END:\n#+title: Pics\n'
    '#+filetags: :demo:\n'
    'Intro with [[id:other][another note]] and [[https://example.org]].\n'
    '# image prompt: a made-up chart\n'
    '#+caption: Visitors by year\n'
    '[[file:img/chart.png]]\n'
    '\n'
    '| Year | Visitors |\n'
    '|------+----------|\n'
    '| 2020 | 10       |\n'
    'Source: [[https://example.org/data][Example Office]], retrieved 2026-01-02\n'
    '\n'
    '* Part\n'
    ':PROPERTIES:\n:ID: part\n:END:\n'
    '- item one\n'
    '#+caption: A photo\n'
    '[[file:img/photo.jpg]]\n'
    'Again [[file:img/chart.png]].\n';

void main() {
  group('the text of a note', () {
    test('drawers, IDs, keywords and comments are left out', () {
      final text = noteAsText('Pics', pics, isFile: true);
      expect(text, startsWith('Pics\n\nIntro with another note and '
          'https://example.org.\n'));
      expect(text, isNot(contains(':PROPERTIES:')));
      expect(text, isNot(contains(':ID:')));
      expect(text, isNot(contains('#+title')));
      expect(text, isNot(contains('filetags')));
      expect(text, isNot(contains('image prompt')));
    });

    test('the caption stays, the image link goes, tables and lists stay', () {
      final text = noteAsText('Pics', pics, isFile: true);
      expect(text, contains('Visitors by year\n'));
      expect(text, isNot(contains('#+caption')));
      expect(text, isNot(contains('file:img/chart.png]]')));
      expect(text, contains('| 2020 | 10       |'));
      expect(text, contains('- item one'));
      expect(text, contains('* Part'));
      // The source line shows the link's description.
      expect(text, contains('Source: Example Office, retrieved 2026-01-02'));
    });

    test('a link without a description shows its target', () {
      expect(linksAsText('See [[id:abc]] and [[id:abc][the note]].'),
          'See id:abc and the note.');
    });

    test('a heading node gives its subtree under its title', () {
      const subtree = '* Part\n:PROPERTIES:\n:ID: part\n:END:\n'
          '- item one\nText [[id:x][x]].\n** Deeper\nMore.';
      expect(noteAsText('Part', subtree, isFile: false),
          'Part\n\n- item one\nText x.\n** Deeper\nMore.');
    });
  });

  group('the text of a picture', () {
    test('the caption of an image', () {
      expect(imageShareText(pics, 'file:img/photo.jpg'), 'A photo');
    });

    test('an infographic also gets the source line', () {
      expect(imageShareText(pics, 'file:img/chart.png'),
          'Visitors by year\nSource: Example Office, retrieved 2026-01-02');
    });

    test('nothing to say', () {
      expect(imageShareText('[[file:a.png]]\n', 'file:a.png'), isNull);
      expect(imageShareText(pics, 'file:img/none.png'), isNull);
    });
  });

  test('the images of a note, once each, with their MIME types', () async {
    final files = FakeNoteFiles(['img/chart.png', 'img/photo.jpg']);
    final found = await noteImageFiles(files, 'pics.org', pics);
    expect([for (final image in found.images) image.name],
        ['chart.png', 'photo.jpg']);
    expect([for (final image in found.images) image.mimeType],
        ['image/png', 'image/jpeg']);
    expect(found.unread, 0);

    final missing = await noteImageFiles(
        FakeNoteFiles(['img/chart.png'], unreadable: {'img/chart.png'}),
        'pics.org',
        pics);
    expect(missing.images, isEmpty);
    expect(missing.unread, 2);
  });

  group('in the node view', () {
    late List<(List<OutFile>, String?, String?)> sentFiles;
    late List<(String, String?)> sentTexts;

    Future<void> show(WidgetTester tester, {String id = 'pics'}) async {
      sentFiles = [];
      sentTexts = [];
      final files = FakeNoteFiles(['img/chart.png', 'img/photo.jpg']);
      await tester.pumpWidget(MaterialApp(
        home: NodeScreen(
          graph: ValueNotifier(graphOf({'pics.org': pics})),
          id: id,
          readNote: (path) async => pics,
          files: files,
          nodeMemory: MemoryNodeMemory(),
          shareText: (text, {subject}) async => sentTexts.add((text, subject)),
          shareFiles: (list, {text, subject}) async =>
              sentFiles.add((list, text, subject)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> chooseShare(WidgetTester tester, [String? kind]) async {
      await tester.tap(find.byTooltip('Share note…'));
      await tester.pumpAndSettle();
      expect(find.text('As text'), findsOneWidget);
      expect(find.text('As text with images'), findsOneWidget);
      expect(find.text('As Org file'), findsOneWidget);
      if (kind != null) await tester.tap(find.text(kind));
      await tester.pump();
      await tester.tap(find.text('Share').last);
      await tester.pumpAndSettle();
    }

    testWidgets('"As text" is the first choice and shares the text',
        (tester) async {
      await show(tester);
      await chooseShare(tester);
      final (text, subject) = sentTexts.single;
      expect(subject, 'Pics');
      expect(text, startsWith('Pics\n\nIntro with another note'));
      expect(text, isNot(contains(':ID:')));
      expect(sentFiles, isEmpty);
    });

    testWidgets('"As text with images" sends all images and the text',
        (tester) async {
      await show(tester);
      await chooseShare(tester, 'As text with images');
      final (images, text, subject) = sentFiles.single;
      expect([for (final image in images) image.name],
          ['chart.png', 'photo.jpg']);
      expect(images.first.bytes, png);
      expect(text, startsWith('Pics\n\n'));
      expect(subject, 'Pics');
      expect(sentTexts, isEmpty);
    });

    testWidgets('"As Org file" sends the file, named after the note',
        (tester) async {
      await show(tester);
      await chooseShare(tester, 'As Org file');
      final (list, text, _) = sentFiles.single;
      expect(list.single.name, 'Pics.org');
      expect(String.fromCharCodes(list.single.bytes), pics);
      expect(text, isNull);
    });

    testWidgets('a heading node shares its subtree only', (tester) async {
      await show(tester, id: 'part');
      await chooseShare(tester, 'As Org file');
      final file = sentFiles.single.$1.single;
      expect(file.name, 'Part.org');
      final org = String.fromCharCodes(file.bytes);
      expect(org, startsWith('* Part'));
      expect(org, isNot(contains('Intro with')));
    });

    testWidgets('the dialog can be cancelled', (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('Share note…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sentTexts, isEmpty);
      expect(sentFiles, isEmpty);
    });

    testWidgets('on the desktop, "As text" says it was copied',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await show(tester);
      await chooseShare(tester);
      expect(sentTexts, hasLength(1));
      expect(find.text('Copied'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a long press on an image offers Open and Share',
        (tester) async {
      await show(tester);
      await tester.longPress(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      final (images, text, _) = sentFiles.single;
      expect(images.single.name, 'chart.png');
      expect(images.single.mimeType, 'image/png');
      expect(images.single.bytes, png);
      // The caption, then the source line of the infographic.
      expect(text,
          'Visitors by year\nSource: Example Office, retrieved 2026-01-02');
    });

    testWidgets('the picture page has a share icon', (tester) async {
      await show(tester);
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(find.byType(ImagePage), findsOneWidget);
      await tester.tap(find.byTooltip('Share'));
      await tester.pumpAndSettle();
      expect(sentFiles.single.$1.single.name, 'chart.png');
    });

    testWidgets('a picture that cannot be sent says so', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: NodeScreen(
          graph: ValueNotifier(graphOf({'pics.org': pics})),
          id: 'pics',
          readNote: (path) async => pics,
          files: FakeNoteFiles(['img/chart.png', 'img/photo.jpg']),
          nodeMemory: MemoryNodeMemory(),
          shareFiles: (list, {text, subject}) async =>
              throw PlatformException(code: 'x', message: 'no app'),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(Image).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(find.text('Could not share the picture: no app'), findsOneWidget);
    });
  });
}
