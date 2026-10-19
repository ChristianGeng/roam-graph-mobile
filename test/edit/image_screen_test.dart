import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/image_screen.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';
import 'package:roam_graph_mobile/graph/org_roam_parser.dart';
import 'package:roam_graph_mobile/settings/view_settings.dart';

import '../ai/ai_images_test.dart' show png;
import '../ai/ai_settings_test.dart' show MemoryAiSettingsStore, MemoryKeyStore;
import 'note_editor_test.dart' show MemoryNoteStore;

const notes = {
  'sub/fox.org': ':PROPERTIES:\n:ID: fox\n:END:\n#+title: Red fox\nText.\n',
  'diary.org': ':PROPERTIES:\n:ID: diary\n:END:\n#+title: Diary\n'
      '#+filetags: :private:\nSecret.\n',
};

void main() {
  test('the image path, the link from the note, the addition', () {
    final time = DateTime(2026, 10, 18, 9, 5, 7);
    expect(imagePath('img', time, 'Red fox', 'png'),
        'img/20261018090507-red_fox.png');
    expect(imagePath('.', time, '', 'jpg'), '20261018090507-image.jpg');
    expect(relativeLink('fox.org', 'img/a.png'), 'img/a.png');
    expect(relativeLink('sub/fox.org', 'img/a.png'), '../img/a.png');
    expect(relativeLink('sub/fox.org', 'sub/img/a.png'), 'img/a.png');
    expect(relativeLink('a/b/fox.org', 'a.png'), '../../a.png');
    expect(imagePrompt('A fox', 'Red fox'),
        'A fox\n\nThe image is for a note titled "Red fox".');
    expect(imagePrompt('A fox', null), 'A fox');
    expect(imageAddition('A fox\n in snow', 'img/a.png'),
        '#+caption: A fox in snow\n[[file:img/a.png]]\n');
  });

  test('the image folder must be inside roam/', () {
    expect(cleanImageFolder('img'), 'img');
    expect(cleanImageFolder(' /media//pics/ '), 'media/pics');
    expect(cleanImageFolder('.'), '.');
    for (final bad in ['', '/', '../img', 'a/../../b', 'a:b', '.hidden']) {
      expect(cleanImageFolder(bad), isNull, reason: bad);
    }
    expect(ViewSettings.fromJson({'imageFolder': '../x'}).imageFolder, 'img');
    expect(ViewSettings.fromJson({'imageFolder': 'pics'}).imageFolder, 'pics');
  });

  Future<(MemoryNoteStore, Map<String, Uint8List>, List<String>)> open(
      WidgetTester tester, String id,
      {Set<String> taken = const {}, String provider = 'vercel'}) async {
    final store = MemoryNoteStore(Map.of(notes));
    final written = <String, Uint8List>{};
    final prompts = <String>[];
    final writer = NoteWriter(
      create: (name, text) async => Created(name),
      allowWriting: () async {},
      editor: NoteEditor(store: store, history: MemoryEditHistory()),
      createFile: (path, bytes) async {
        if (taken.contains(path) || written.containsKey(path)) {
          return const FileExists();
        }
        written[path] = bytes;
        return Created(path);
      },
    );
    final node = [
      for (final MapEntry(:key, :value) in notes.entries)
        ...parseRoamFile(key, value).nodes,
    ].firstWhere((n) => n.id == id);
    await tester.pumpWidget(ViewSettingsHost(
      store: MemoryViewSettingsStore(const ViewSettings(imageFolder: 'img')),
      child: AiSettingsHost(
        store: MemoryAiSettingsStore(AiSettings(provider: provider)),
        keys: MemoryKeyStore()..keys[provider] = 'v-key',
        child: MaterialApp(
          home: ImageScreen(
            writer: writer,
            node: node,
            now: () => DateTime(2026, 10, 18, 9, 5, 7),
            post: (url, headers, body) async {
              prompts.add((jsonDecode(body) as Map)['prompt'] as String);
              return HttpReply(
                  200,
                  jsonEncode({
                    'data': [
                      {'b64_json': png},
                    ],
                  }));
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (store, written, prompts);
  }

  testWidgets('the image is shown first, then saved and linked (#112)',
      (tester) async {
    final (store, written, prompts) = await open(tester, 'fox',
        taken: {'img/20261018090507-red_fox.png'});
    await tester.enterText(
        find.byKey(const ValueKey('image-prompt')), 'A red fox in snow');
    await tester.tap(find.byKey(const ValueKey('image-make')));
    await tester.pumpAndSettle();
    // With the note's title, as the box is ticked by default.
    expect(prompts,
        ['A red fox in snow\n\nThe image is for a note titled "Red fox".']);
    expect(find.byKey(const ValueKey('image-preview')), findsOneWidget);
    // Nothing is saved yet.
    expect(written, isEmpty);
    expect(store.files['sub/fox.org'], notes['sub/fox.org']);

    await tester.tap(find.byKey(const ValueKey('image-save')));
    await tester.pumpAndSettle();
    // The first name was taken: a second later.
    expect(written.keys, ['img/20261018090508-red_fox.png']);
    expect(written.values.single, base64.decode(png));
    expect(
        store.files['sub/fox.org'],
        '${notes['sub/fox.org']}#+caption: A red fox in snow\n'
        '[[file:../img/20261018090508-red_fox.png]]\n');
  });

  testWidgets('a note hidden from AI: nothing is sent', (tester) async {
    final (_, written, prompts) = await open(tester, 'diary');
    await tester.enterText(find.byKey(const ValueKey('image-prompt')), 'x');
    await tester.tap(find.byKey(const ValueKey('image-make')));
    await tester.pumpAndSettle();
    expect(prompts, isEmpty);
    expect(written, isEmpty);
    expect(find.text('This note is hidden from AI; nothing was sent.'),
        findsOneWidget);
  });

  testWidgets('a provider without images says so', (tester) async {
    final (_, _, prompts) = await open(tester, 'fox', provider: 'anthropic');
    await tester.enterText(find.byKey(const ValueKey('image-prompt')), 'x');
    await tester.tap(find.byKey(const ValueKey('image-make')));
    await tester.pumpAndSettle();
    expect(prompts, isEmpty);
    expect(find.textContaining('cannot make images in the app'),
        findsOneWidget);
  });
}
