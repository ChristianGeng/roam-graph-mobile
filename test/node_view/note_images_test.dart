import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:roam_graph_mobile/folder/org_files.dart';
import 'package:roam_graph_mobile/node_view/node_screen.dart';
import 'package:roam_graph_mobile/node_view/note_images.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import 'node_screen_test.dart' show graphOf;

/// A synthetic 40 by 20 pixel PNG (decision 14: no real notes in tests).
final png = File('test/fixtures/images/red-40x20.png').readAsBytesSync();

/// The folder's files by path relative to roam/, as the folder screen
/// finds them; [unreadable] are listed but cannot be read.
class FakeNoteFiles implements NoteFiles {
  FakeNoteFiles(Iterable<String> paths, {this.unreadable = const {}})
      : files = {
          for (final path in paths)
            path: FolderFile(path: path, uri: 'content://$path', modified: 1),
        };

  final Map<String, FolderFile> files;
  final Set<String> unreadable;
  final reads = <String>[];

  /// Raised to make every image new, as a scan does for files without a
  /// modification time.
  int scan = 0;

  @override
  int version(FolderFile file) => file.modified != 0 ? file.modified : -scan;

  @override
  bool reaches(String path) => !path.startsWith('../');

  @override
  FolderFile? find(String path) => files[path];

  @override
  Future<Uint8List?> read(FolderFile file) async {
    reads.add(file.path);
    return unreadable.contains(file.path) ? null : png;
  }
}

/// The first link in [text].
OrgLink linkIn(OrgDocument document) {
  OrgLink? link;
  document.visit<OrgLink>((node) {
    link = node;
    return false;
  });
  return link!;
}

/// The text on screen; links to URLs may wrap anywhere, through
/// zero-width spaces, which are left out.
String shownText(WidgetTester tester) => [
      for (final text in tester.widgetList<RichText>(find.byType(RichText)))
        text.text.toPlainText().replaceAll('\u200b', ''),
    ].join('\n');

void main() {
  test('paths are normalized as Org resolves them', () {
    expect(normalizePath('./img/x.png'), 'img/x.png');
    expect(normalizePath('sub/../img//x.png'), 'img/x.png');
    expect(normalizePath('../include/./x.png'), '../include/x.png');
    expect(normalizePath('a/../../x.png'), '../x.png');
  });

  test('image links are relative to the note\'s directory', () {
    for (final (note, location, path) in [
      ('a.org', 'file:./img/x.png', 'img/x.png'),
      ('a.org', './img/x.png', 'img/x.png'),
      ('a.org', 'file:img/x.png', 'img/x.png'),
      ('a.org', 'file:./img/X.JPG', 'img/X.JPG'),
      ('sub/n.org', './img/x.png', 'sub/img/x.png'),
      ('sub/n.org', '../include/x.webp', 'include/x.webp'),
      ('a.org', '../include/x.png', '../include/x.png'),
    ]) {
      expect(linkedImagePath(note, location), path, reason: location);
    }
  });

  test('other image links stay links', () {
    for (final location in [
      'https://example.org/x.png', // the app is offline
      'attachment:x.png',
      'file:/home/x/img/x.png', // absolute
      '/home/x/img/x.png',
      'file:~/img/x.png',
      '~/img/x.png',
      'file:./img/x.svg', // #47
      'file:./img/x.avif',
      'data:image/png;base64,iVBORw0KGgo=',
      'id:4f2b',
    ]) {
      expect(linkedImagePath('a.org', location), isNull, reason: location);
    }
  });

  // Each width as Org 9.7.39's org-display-inline-image--width gives it
  // with org-image-actual-width nil (checked in Emacs); null is the
  // image's own width.
  test('the width from #+ATTR_ORG, as Org reads it', () {
    for (final (attributes, width) in <(String, OrgImageWidth?)>[
      ('#+ATTR_ORG: :width 120px\n', (pixels: 120, fraction: null)),
      ('#+ATTR_ORG: :width 300\n', (pixels: 300, fraction: null)),
      ('#+attr_org: :width 300px\n', (pixels: 300, fraction: null)),
      ('#+ATTR_ORG: :width 300.0\n', null),
      ('#+ATTR_ORG: :width t\n', null),
      ('#+ATTR_ORG: :width 50%\n', (pixels: null, fraction: 0.5)),
      ('#+ATTR_ORG: :width 0.5\n', (pixels: null, fraction: 0.5)),
      ('#+ATTR_ORG: :width foo\n#+ATTR_HTML: :width 200\n',
          (pixels: 200, fraction: null)),
      ('#+ATTR_HTML: :width 200\n', (pixels: 200, fraction: null)),
      ('#+ATTR_ORG: :align center\n#+ATTR_ORG: :width 150\n',
          (pixels: 150, fraction: null)),
      // Not affiliated with the paragraph: a blank line between.
      ('#+ATTR_ORG: :width 150\n\n', null),
      ('', null),
    ]) {
      final document = OrgDocument.parse('$attributes[[file:./img/x.png]]\n');
      expect(orgImageWidth(document, linkIn(document)), width,
          reason: attributes);
    }
  });

  test('a link inside a paragraph has its paragraph\'s width', () {
    final document = OrgDocument.parse(
        'Text before.\n\n#+ATTR_ORG: :width 150\nSee [[file:./img/x.png]] here.\n');
    expect(orgImageWidth(document, linkIn(document)),
        (pixels: 150, fraction: null));
  });

  Future<void> show(WidgetTester tester, String text, NoteFiles files,
      {String file = 'n.org'}) async {
    final note = ':PROPERTIES:\n:ID: n\n:END:\n#+title: N\n$text';
    await tester.pumpWidget(MaterialApp(
      home: NodeScreen(
        graph: ValueNotifier(graphOf({file: note})),
        id: 'n',
        readNote: (path) async => note,
        files: files,
        nodeMemory: MemoryNodeMemory(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Iterable<FolderImage> shownImages(WidgetTester tester) => [
        for (final image in tester.widgetList<Image>(find.byType(Image)))
          if (image.image case final FolderImage folderImage) folderImage,
      ];

  testWidgets('file: and plain links show the image from the folder',
      (tester) async {
    final files = FakeNoteFiles(['img/a.png', 'img/b.png']);
    await show(tester, '[[file:./img/a.png]]\n\n[[./img/b.png]]\n', files);
    expect([for (final image in shownImages(tester)) image.file.path],
        ['img/a.png', 'img/b.png']);
    expect(shownText(tester), isNot(contains('img/a.png')));
  });

  testWidgets('../ leads to the folder beside the note\'s', (tester) async {
    final files = FakeNoteFiles(['include/c.png']);
    await show(tester, '[[file:../include/c.png]]\n', files,
        file: 'sub/n.org');
    expect([for (final image in shownImages(tester)) image.file.path],
        ['include/c.png']);
  });

  testWidgets(':width 120px shows the image 120 pixels wide', (tester) async {
    final files = FakeNoteFiles(['img/a.png']);
    await show(tester, '#+ATTR_ORG: :width 120px\n[[file:./img/a.png]]\n',
        files);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 120);
    // Decoded at the shown size, in device pixels, and never larger than
    // the file.
    expect((image.image as FolderImage).width,
        (120 * tester.view.devicePixelRatio).ceil());
  });

  testWidgets('a missing image shows the link with an icon', (tester) async {
    await show(tester, '[[file:./img/gone.png]]\n', FakeNoteFiles([]));
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(shownText(tester), contains('file:./img/gone.png'));
  });

  testWidgets('an image that cannot be read shows the link with an icon',
      (tester) async {
    // Another file than in the other tests: Flutter's image cache keeps
    // images between tests.
    final files = FakeNoteFiles(['img/u.png'], unreadable: {'img/u.png'});
    await show(tester, '[[file:./img/u.png]]\n', files);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(files.reads, ['img/u.png']);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(shownText(tester), contains('file:./img/u.png'));
  });

  testWidgets('described and web image links stay links', (tester) async {
    final files = FakeNoteFiles(['img/a.png']);
    await show(
        tester,
        '[[file:./img/a.png][a picture]]\n\n'
        '[[https://example.org/w.png]]\n',
        files);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(shownText(tester), contains('a picture'));
    expect(shownText(tester), contains('https://example.org/w.png'));
    expect(files.reads, isEmpty);
  });

  testWidgets('without the folder\'s files, image links are text',
      (tester) async {
    final note = ':PROPERTIES:\n:ID: n\n:END:\n#+title: N\n'
        '[[file:./img/a.png]]\n';
    await tester.pumpWidget(MaterialApp(
      home: NodeScreen(
        graph: ValueNotifier(graphOf({'n.org': note})),
        id: 'n',
        readNote: (path) async => note,
        nodeMemory: MemoryNodeMemory(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(shownText(tester), contains('file:./img/a.png'));
  });

  testWidgets(':width 10% is decoded at a tenth of the screen',
      (tester) async {
    final files = FakeNoteFiles(['img/f.png']);
    await show(tester, '#+ATTR_ORG: :width 10%\n[[file:./img/f.png]]\n',
        files);
    final view = tester.view;
    final screen = view.physicalSize.width / view.devicePixelRatio;
    expect((tester.widget<Image>(find.byType(Image)).image as FolderImage).width,
        (screen * 0.1 * view.devicePixelRatio).ceil());
  });

  test('the zoom page decodes at most 4096 pixels wide', () {
    expect(
        ImagePage.decodeWidth(
            const MediaQueryData(size: Size(400, 900), devicePixelRatio: 3)),
        4096);
    expect(
        ImagePage.decodeWidth(
            const MediaQueryData(size: Size(300, 200), devicePixelRatio: 1)),
        1200);
  });

  testWidgets('tapping an image shows it alone, with zoom', (tester) async {
    final files = FakeNoteFiles(['img/a.png']);
    await show(tester, '[[file:./img/a.png]]\n', files);
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final zoomed = tester.widget<Image>(find.descendant(
        of: find.byType(InteractiveViewer), matching: find.byType(Image)));
    expect((zoomed.image as FolderImage).width, isNotNull);
    expect(find.text('a.png'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  test('the cache key is the file\'s URI and modification time', () {
    final files = FakeNoteFiles([]);
    const a = FolderFile(path: 'img/a.png', uri: 'content://a', modified: 1);
    const same = FolderFile(path: 'img/a.png', uri: 'content://a', modified: 1);
    const changed =
        FolderFile(path: 'img/a.png', uri: 'content://a', modified: 2);
    expect(FolderImage(a, files), FolderImage(same, files));
    expect(FolderImage(a, files), isNot(FolderImage(changed, files)));
    // Without a modification time, each scan makes it new.
    const unknown = FolderFile(path: 'img/a.png', uri: 'content://a');
    final before = FolderImage(unknown, files);
    files.scan++;
    expect(FolderImage(unknown, files), isNot(before));
  });

  testWidgets('an image is decoded smaller, never larger', (tester) async {
    final files = FakeNoteFiles(['img/a.png']);
    Future<(int, int)> decoded(int? width) async {
      final stream = FolderImage(files.files['img/a.png']!, files, width: width)
          .resolve(ImageConfiguration.empty);
      final info = Completer<ImageInfo>();
      stream.addListener(ImageStreamListener((i, _) => info.complete(i)));
      final image = (await info.future).image;
      return (image.width, image.height);
    }

    await tester.runAsync(() async {
      expect(await decoded(null), (40, 20));
      expect(await decoded(10), (10, 5));
      expect(await decoded(400), (40, 20));
    });
  });

  testWidgets('an image that could not be read is read again',
      (tester) async {
    final files = FakeNoteFiles(['img/v.png'], unreadable: {'img/v.png'});
    final provider = FolderImage(files.files['img/v.png']!, files);
    Future<bool> loads() async {
      final done = Completer<bool>();
      provider.resolve(ImageConfiguration.empty).addListener(
          ImageStreamListener((_, _) => done.complete(true),
              onError: (_, _) => done.complete(false)));
      return done.future;
    }

    await tester.runAsync(() async {
      expect(await loads(), isFalse);
      await Future<void>.delayed(Duration.zero);
      files.unreadable.clear();
      expect(await loads(), isTrue);
    });
    expect(files.reads, ['img/v.png', 'img/v.png']);
  });
}
