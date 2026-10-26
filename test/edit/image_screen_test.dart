import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
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
      {Set<String> taken = const {},
      String provider = 'vercel',
      AiSettings? settings,
      HttpPost? post}) async {
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
        store: MemoryAiSettingsStore(settings ?? AiSettings(provider: provider)),
        keys: MemoryKeyStore()..keys[provider] = 'v-key',
        child: MaterialApp(
          home: ImageScreen(
            writer: writer,
            node: node,
            now: () => DateTime(2026, 10, 18, 9, 5, 7),
            post: post ??
                (url, headers, body) async {
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
    expect(
        find.byKey(const ValueKey('image-where')),
        findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('image-error')))
            .data,
        contains('cannot make images in the app'));
  });

  testWidgets('an image error can be copied with the provider\'s answer (#180)',
      (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester, 'fox',
        post: (url, headers, body) async => HttpReply(
            400,
            jsonEncode({
              'error': {'message': 'The prompt was refused.'},
              'debug': 'Authorization: Bearer sk-live-abcdef123456',
              'echo': 'v-key',
            })));
    await tester.enterText(find.byKey(const ValueKey('image-prompt')), 'x');
    await tester.tap(find.byKey(const ValueKey('image-make')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The prompt was refused.'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('image-error-copy')));
    await tester.pumpAndSettle();
    final text = copied.single;
    expect(text, contains('Vercel AI Gateway'));
    expect(text, contains('Provider: Vercel AI Gateway'));
    expect(text, contains('\nAPI: '));
    expect(text, contains('HTTP status: 400'));
    expect(text, contains('\nAnswer:\n'));
    expect(text, contains('"The prompt was refused."'));
    expect(text, isNot(contains('sk-live')));
    expect(text, isNot(contains('v-key')));
    expect(find.text('Copied'), findsOneWidget);
  });

  final openScreen = open;
  String where(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('image-where'))).data!;

  testWidgets('the line above "Make image": provider, model, region (#127)',
      (tester) async {
    // A new screen each time, not the one before with new settings.
    Future<void> open(WidgetTester tester, String id,
        {String provider = 'vercel', AiSettings? settings}) async {
      await tester.pumpWidget(const SizedBox());
      await openScreen(tester, id, provider: provider, settings: settings);
    }

    await open(tester, 'fox', provider: 'mistral');
    expect(where(tester), 'Made by Mistral with mistral-medium-latest, in the EU.');
    await open(tester, 'fox');
    expect(where(tester),
        'Made by Vercel AI Gateway with openai/gpt-image-2, outside the EU.');
    await open(tester, 'fox',
        settings: AiSettings(provider: 'vercel', providers: {
          'vercel': ProviderSettings.fromJson(
              {'euOnly': true}, presetById('vercel')),
        }));
    expect(where(tester),
        'Made by Vercel AI Gateway with google/gemini-2.5-flash-image, in the EU.');
    await open(tester, 'fox', provider: 'openrouter');
    expect(where(tester), endsWith(', region not known.'));
    // Another provider than the chat's.
    await open(tester, 'fox',
        settings: const AiSettings(provider: 'anthropic', imageProvider: 'qwen'));
    expect(where(tester),
        'Made by Qwen (Alibaba Cloud) with qwen-image-2.0, outside the EU.');
  });

  testWidgets('"Make this one outside the EU": once, the setting stays on',
      (tester) async {
    final bodies = <Map<String, Object?>>[];
    await open(tester, 'fox',
        settings: AiSettings(provider: 'vercel', providers: {
          'vercel': ProviderSettings.fromJson(
              {'euOnly': true, 'imageModel': 'bfl/flux-2-pro'},
              presetById('vercel')),
        }),
        post: (url, headers, body) async {
          final json = jsonDecode(body) as Map<String, Object?>;
          bodies.add(json);
          if (json.containsKey('providerOptions')) {
            return HttpReply(
                400,
                jsonEncode({
                  'error': {
                    'message': 'No provider for bfl/flux-2-pro supports the '
                        'requested inference region.',
                  },
                }));
          }
          return HttpReply(
              200,
              jsonEncode({
                'data': [
                  {'b64_json': png},
                ],
              }));
        });
    final outside = find.byKey(const ValueKey('image-outside-eu'));
    await tester.enterText(
        find.byKey(const ValueKey('image-prompt')), 'A red fox');
    await tester.tap(find.byKey(const ValueKey('image-make')));
    await tester.pumpAndSettle();
    expect(find.textContaining('has no EU route'), findsOneWidget);
    expect(find.text('Make this one outside the EU'), findsOneWidget);

    await tester.tap(outside);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-preview')), findsOneWidget);
    expect(outside, findsNothing);
    expect(bodies, hasLength(2));
    expect(bodies[1].containsKey('providerOptions'), isFalse);
    // Only the description and the title.
    expect(bodies[1]['prompt'],
        'A red fox\n\nThe image is for a note titled "Red fox".');
    expect(where(tester), endsWith(', in the EU.'));

    // "EU only" is still on: the next image asks in the EU again.
    await tester.tap(find.byKey(const ValueKey('image-make')));
    await tester.pumpAndSettle();
    expect(bodies, hasLength(3));
    expect(bodies[2].containsKey('providerOptions'), isTrue);
    expect(outside, findsOneWidget);
  });
}
