// Text and text files brought into the app (#220), through the folder
// screen: shared files, the capture screen's choices, drops, the
// clipboard and "Open files…". All notes and files are synthetic.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/capture/share_inbox.dart';
import 'package:roam_graph_mobile/capture/text_files.dart';
import 'package:roam_graph_mobile/platform/text_drop.dart';

import '../graph_view/graph_screen_test.dart' show MemoryNodeMemory;
import '../widget_test.dart'
    show FakeFolderAccess, FakeShareInbox, start, withNotes, writableOrg;

IncomingFile file(String name, String text) =>
    IncomingFile(name, bytes: Uint8List.fromList(utf8.encode(text)));

Future<FakeFolderAccess> startWith(WidgetTester tester, Share share,
    {Future<List<String>> Function()? pickTextFiles}) async {
  final access = withNotes(saved: writableOrg);
  await start(tester, access,
      shares: FakeShareInbox()..queue.add(share),
      memory: MemoryNodeMemory('a'),
      pickTextFiles: pickTextFiles);
  return access;
}

Future<void> choose(WidgetTester tester, String choice) async {
  await tester.tap(find.byTooltip('Other uses of the text'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(choice));
  await tester.pumpAndSettle();
}

String chatInput(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('chat-input')))
    .controller!
    .text;

void main() {
  group('capture screen choices', () {
    testWidgets('offers every choice for an Org file, and no import for text',
        (tester) async {
      await startWith(tester, SharedFiles([file('plan.org', 'Plan.')]));
      await tester.tap(find.byTooltip('Other uses of the text'));
      await tester.pumpAndSettle();
      for (final label in [
        'Add to a node',
        "Replace a node's text",
        'Ask AI',
        'Add to a chat…',
        'Import as a note as it is',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
    });

    testWidgets('shared text has no import choice', (tester) async {
      await startWith(tester, const SharedText('A thought.'));
      await tester.tap(find.byTooltip('Other uses of the text'));
      await tester.pumpAndSettle();
      expect(find.text('Ask AI'), findsOneWidget);
      expect(find.text('Import as a note as it is'), findsNothing);
    });

    testWidgets('Ask AI: a new chat with the text in the message field, '
        'not sent', (tester) async {
      await startWith(tester, const SharedText('Line one\nLine two'));
      await choose(tester, 'Ask AI');
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(chatInput(tester), 'Shared text:\n> Line one\n> Line two\n\n');
      // Nothing was sent: no message is shown above the field.
      expect(find.text('Line one'), findsNothing);
    });

    testWidgets('Add to a chat…: the list asks for a chat, which gets the text',
        (tester) async {
      await startWith(tester, SharedFiles([file('idea.txt', 'An idea.')]));
      await choose(tester, 'Add to a chat…');
      expect(find.byKey(const ValueKey('chat-choose')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-new')));
      await tester.pumpAndSettle();
      expect(chatInput(tester), 'Shared text (idea.txt):\n> An idea.\n\n');
    });

    testWidgets('Add to a node, with a shared file', (tester) async {
      final access =
          await startWith(tester, SharedFiles([file('n.txt', 'Added text.')]));
      final before = access.texts['roam/a.org']!;
      await choose(tester, 'Add to a node');
      await tester.tap(find.byKey(const ValueKey('picker-proposed')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(access.texts['roam/a.org'], '${before}Added text.\n');
    });
  });

  group('shared files', () {
    testWidgets('without a title line, the file name is the title',
        (tester) async {
      final access = await startWith(
          tester, SharedFiles([file('Reading list.txt', 'Book one.\n')]));
      expect(find.widgetWithText(TextField, 'Reading list'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final (_, name) = access.created.single;
      expect(access.texts['roam/$name'],
          contains('#+title: Reading list\n\nBook one.\n'));
    });

    testWidgets('a title line is the title', (tester) async {
      await startWith(tester,
          SharedFiles([file('x.md', '# Weekly review\nDone: three.\n')]));
      expect(find.widgetWithText(TextField, 'Weekly review'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Done: three.'), findsOneWidget);
    });

    testWidgets('several files, one note per file: one after the other',
        (tester) async {
      final access = await startWith(tester,
          SharedFiles([file('first.txt', 'One.'), file('second.txt', 'Two.')]));
      expect(find.text('2 text files'), findsOneWidget);
      await tester.tap(find.text('One note per file'));
      await tester.pumpAndSettle();
      expect(find.text('File 1 of 2: first.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      // The next capture opens above the new node.
      expect(find.text('File 2 of 2: second.txt'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'second'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(access.created.length, 2);
    });

    testWidgets('several files, one note: a heading for each file',
        (tester) async {
      final access = await startWith(tester,
          SharedFiles([file('first.txt', 'One.'), file('second.txt', 'Two.')]));
      await tester.tap(find.text('One note'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'first, second'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final (_, name) = access.created.single;
      expect(access.texts['roam/$name'],
          contains('* first.txt\nOne.\n\n* second.txt\nTwo.\n'));
    });

    testWidgets('files over the limits are refused by name', (tester) async {
      await startWith(
          tester,
          SharedFiles([
            file('ok.txt', 'Fine.'),
            IncomingFile('huge.txt', bytes: Uint8List(maxFileBytes + 1)),
            file('photo.jpg', 'x'),
          ]));
      expect(
          find.text('Not taken: huge.txt (larger than 1 MB), photo.jpg (not '
              'a text file: .txt, .md, .markdown or .org).'),
          findsOneWidget);
      expect(find.widgetWithText(TextField, 'ok'), findsOneWidget);
    });

    testWidgets('only refused files: a message, no capture', (tester) async {
      await startWith(tester, SharedFiles([file('photo.jpg', 'x')]));
      expect(find.text('New node'), findsNothing);
      expect(find.textContaining('Not taken: photo.jpg'), findsOneWidget);
    });

    testWidgets('a file that is not UTF-8 is read as Latin-1, with a note',
        (tester) async {
      await startWith(
          tester,
          SharedFiles([
            IncomingFile('caf.txt',
                bytes: Uint8List.fromList(latin1.encode('Caf\u00e9 au lait'))),
          ]));
      expect(find.text('caf.txt is not UTF-8; it was read as Latin-1.'),
          findsOneWidget);
      expect(find.widgetWithText(TextField, 'Caf\u00e9 au lait'), findsOneWidget);
    });
  });

  group('Org import as it is', () {
    testWidgets('a file with an ID is copied unchanged', (tester) async {
      const text = ':PROPERTIES:\n:ID: own-id\n:END:\n#+title: Own\nBody.\n';
      final access = await startWith(tester, SharedFiles([file('own.org', text)]));
      await choose(tester, 'Import as a note as it is');
      expect(access.texts['roam/own.org'], text);
      expect(find.text('Imported own.org.'), findsOneWidget);
      // The imported node is open.
      expect(
          find.descendant(of: find.byType(AppBar), matching: find.text('Own')),
          findsOneWidget);
    });

    testWidgets('a file without an ID gets one', (tester) async {
      final access = await startWith(
          tester, SharedFiles([file('bare.org', '#+title: Bare\nBody.\n')]));
      await choose(tester, 'Import as a note as it is');
      expect(access.texts['roam/bare.org'],
          matches(RegExp(r'^:PROPERTIES:\n:ID:       [0-9a-f-]{36}\n:END:\n'
              r'#\+title: Bare\nBody\.\n$')));
    });

    testWidgets('an existing name is never replaced', (tester) async {
      final access = await startWith(
          tester, SharedFiles([file('a.org', '#+title: Other A\n')]));
      final before = access.texts['roam/a.org'];
      await choose(tester, 'Import as a note as it is');
      expect(access.texts['roam/a.org'], before);
      expect(find.textContaining('Not imported: roam/a.org exists already'),
          findsOneWidget);
    });
  });

  group('desktop', () {
    final linux = TargetPlatformVariant.only(TargetPlatform.linux);

    void clipboard(WidgetTester tester, String? text) =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return text == null ? null : {'text': text};
          }
          return null;
        });

    testWidgets('"New note from clipboard" opens the capture screen',
        (tester) async {
      clipboard(tester, '# From the clipboard\nCopied text.');
      await start(tester, withNotes(saved: writableOrg));
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl+Shift+V'), findsOneWidget);
      await tester.tap(find.text('New note from clipboard'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'From the clipboard'),
          findsOneWidget);
    }, variant: linux);

    testWidgets('Ctrl+Shift+V does the same; an empty clipboard says so',
        (tester) async {
      clipboard(tester, null);
      await start(tester, withNotes(saved: writableOrg));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('The clipboard has no text.'), findsOneWidget);

      clipboard(tester, 'Pasted.');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Pasted.'), findsOneWidget);
    }, variant: linux);

    testWidgets('"Open files…" reads the chosen files', (tester) async {
      final dir = Directory.systemTemp.createTempSync('bring_in_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/todo.md').writeAsStringSync('Buy milk.\n');
      await start(tester, withNotes(saved: writableOrg),
          pickTextFiles: () async => ['${dir.path}/todo.md']);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open files…'));
      await tester.pumpAndSettle();
      // The files are read with real file operations.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'todo'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Buy milk.'), findsOneWidget);
    }, variant: linux);

    testWidgets('a drop onto the window opens the capture screen',
        (tester) async {
      await start(tester, withNotes(saved: writableOrg));
      TextDrop.deliver(const SharedText('Dropped text.'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Dropped text.'), findsOneWidget);
    }, variant: linux);

    testWidgets('a drop onto a chat goes into its message field',
        (tester) async {
      await startWith(tester, const SharedText('First share.'));
      await choose(tester, 'Ask AI');
      await tester.enterText(
          find.byKey(const ValueKey('chat-input')), 'My question?');
      TextDrop.deliver(SharedFiles([file('notes.txt', 'From a file.')]));
      await tester.pumpAndSettle();
      expect(chatInput(tester), 'Shared text (notes.txt):\n> From a file.\n\n'
          'My question?');
      // No capture screen opened for it.
      expect(find.text('New node'), findsNothing);
    }, variant: linux);

    test('shareFromDrop: files, or else the text', () async {
      final dir = Directory.systemTemp.createTempSync('bring_in_drop');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/a.txt').writeAsStringSync('A');
      final files = await shareFromDrop(['${dir.path}/a.txt'], null);
      expect((files! as SharedFiles).files.single.name, 'a.txt');
      // desktop_drop gives URLs as paths on Linux: they are text.
      final text = await shareFromDrop(['https://example.com'],
          'https://example.com');
      expect((text! as SharedText).text, 'https://example.com');
      expect(await shareFromDrop([], '  '), isNull);
    });
  });
}
