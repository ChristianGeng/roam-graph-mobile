import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/agent_tools.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_images.dart';
import 'package:roam_graph_mobile/ai/ai_providers.dart';
import 'package:roam_graph_mobile/ai/ai_settings.dart';
import 'package:roam_graph_mobile/ai/ai_tools.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/image_screen.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';

import '../edit/note_editor_test.dart' show MemoryNoteStore;
import 'ai_chat_test.dart'
    show FakeServer, anthropic, anthropicReply, deepseek, openAiReply;
import 'ai_visibility_test.dart' show graphOf, notes;

/// The first bytes of a PNG file, enough for [imageExtension].
final png = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);

/// Synthetic notes: the shared ones, and one with nothing hidden.
final start = {
  ...notes,
  'open.org': ':PROPERTIES:\n:ID: open\n:END:\n#+title: Open\n'
      'Training hours: 2021 40, 2022 55.\n',
};

void main() {
  const private = AiVisibility({'private'});
  final time = DateTime(2026, 10, 17, 12);

  group('create_image', () {
    late MemoryNoteStore store;
    late Map<String, Uint8List> images;
    late MemoryAgentLog log;
    late List<String> prompts;
    Object? failWith;

    AgentWriter make({int limit = 1, int maxPrompt = 4000}) {
      store = MemoryNoteStore(Map.of(start));
      images = {};
      log = MemoryAgentLog();
      prompts = [];
      failWith = null;
      return AgentWriter(
        writer: NoteWriter(
          create: (name, text) async => Created(name),
          allowWriting: () async {},
          editor: NoteEditor(store: store, history: MemoryEditHistory()),
          createFile: (path, bytes) async {
            if (images.containsKey(path)) return const FileExists();
            images[path] = bytes;
            return Created(path);
          },
        ),
        visibleGraph: () => private.visibleGraph(graphOf(store.files)),
        hiddenIds: () => private.hiddenIds(graphOf(store.files)),
        visibility: private,
        folder: () => 'content://tree/org',
        limit: 30,
        log: log,
        now: () => time,
        random: Random(1),
        images: ImageMaker(
          make: (prompt) async {
            prompts.add(prompt);
            if (failWith case final error?) throw error;
            return MadeImage(png, 'png');
          },
          model: 'mistral-medium-latest at Mistral, in the EU',
          folder: 'images',
          maxPrompt: maxPrompt,
          limit: limit,
        ),
      );
    }

    ToolCall call(String id, String prompt,
            {String caption = 'Hours per year', String callId = 'c1'}) =>
        ToolCall(callId, 'create_image',
            {'id': id, 'prompt': prompt, 'caption': caption});

    test('the image goes into the image folder and below the note, logged',
        () async {
      final agent = make();
      agent.startMessage(prompt: 'Make an infographic');
      final result = await agent.run(call('open', 'Bar chart: 2021 40, 2022 55'));
      final path = imagePath('images', time, 'Open', 'png');
      expect(result, contains('Added the image to "Open"'));
      expect(result, contains('Made by mistral-medium-latest at Mistral'));
      expect(images.keys, [path]);
      expect(prompts, ['Bar chart: 2021 40, 2022 55']);
      expect(
          store.files['open.org'],
          '${start['open.org']}'
          '# image prompt: Bar chart: 2021 40, 2022 55\n'
          '#+caption: Hours per year\n'
          '[[file:$path]]\n');
      expect(agent.changes.changes.single.tool, 'create_image');
      expect(log.entries.single.tool, 'create_image');
      expect(agent.imageFor(const ToolCall('c1', 'create_image', {}))?.bytes,
          png);
      expect(agent.imageFor(const ToolCall('c2', 'create_image', {})), isNull);

      // Undo takes it out of the note; the image file stays.
      await agent.changes.undoAll(agent.writer.editor!);
      expect(store.files['open.org'], start['open.org']);
    });

    test('one image per message by default', () async {
      final agent = make();
      agent.startMessage();
      await agent.run(call('open', 'One'));
      final second = await agent.run(call('plan', 'Two', callId: 'c2'));
      expect(second, startsWith('Error: the limit of 1 image'));
      expect(prompts, ['One']);
      // A new message may make one again.
      agent.startMessage();
      expect(await agent.run(call('plan', 'Three', callId: 'c3')),
          contains('Added the image to "Plan"'));
    });

    test('a second image for the same note replaces the first', () async {
      final agent = make(limit: 2);
      agent.startMessage();
      await agent.run(call('open', 'Wrong 2022'));
      final result = await agent.run(
          call('open', 'Right 2022', caption: 'Corrected', callId: 'c2'));
      expect(result, contains('Replaced the image of this message'));
      final text = store.files['open.org']!;
      expect(text, isNot(contains('Wrong 2022')));
      expect(RegExp(r'#\+caption:').allMatches(text), hasLength(1));
      expect(text, contains('#+caption: Corrected\n'));
      expect(images, hasLength(2));
    });

    test('a hidden note gets no image, and nothing is asked', () async {
      final agent = make();
      agent.startMessage();
      final result = await agent.run(call('diary', 'Anything'));
      expect(result, startsWith('Error: There is no note with the ID diary'));
      expect(prompts, isEmpty);
      expect(images, isEmpty);
    });

    test('a failed image model changes nothing and does not count',
        () async {
      final agent = make();
      agent.startMessage();
      failWith = const AiError('No credit left.');
      expect(await agent.run(call('open', 'One')),
          'Error: the image model failed: No credit left.');
      expect(store.files['open.org'], start['open.org']);
      failWith = null;
      expect(await agent.run(call('open', 'One', callId: 'c2')),
          contains('Added the image'));
    });

    test('a prompt too long for the provider is refused', () async {
      final agent = make(maxPrompt: 10);
      agent.startMessage();
      expect(await agent.run(call('open', 'A very long prompt')),
          contains('at most 10'));
      expect(prompts, isEmpty);
    });

    test('the tool says which model draws, and the limit', () {
      final agent = make(limit: 2);
      final tool = agent.tools.last;
      expect(tool.name, 'create_image');
      expect(tool.description,
          contains('mistral-medium-latest at Mistral, in the EU'));
      expect(tool.description, contains('At most 2 images'));
      expect(maxImagePrompt(ImageApi.dashscope), 800);
      // Without an image model, no such tool.
      final none = AgentWriter(
        writer: agent.writer,
        visibleGraph: agent.visibleGraph,
        hiddenIds: agent.hiddenIds,
        visibility: private,
        folder: () => '',
        limit: 30,
      );
      expect(none.tools.map((t) => t.name), isNot(contains('create_image')));
    });
  });

  group('create_image kind "infographic" (#183)', () {
    late MemoryNoteStore store;
    late Map<String, Uint8List> images;
    late List<String> drawnBy;

    AgentWriter make({int limit = 2, bool ownInfographics = true}) {
      store = MemoryNoteStore(Map.of(start));
      images = {};
      drawnBy = [];
      return AgentWriter(
        writer: NoteWriter(
          create: (name, text) async => Created(name),
          allowWriting: () async {},
          editor: NoteEditor(store: store, history: MemoryEditHistory()),
          createFile: (path, bytes) async {
            if (images.containsKey(path)) return const FileExists();
            images[path] = bytes;
            return Created(path);
          },
        ),
        visibleGraph: () => private.visibleGraph(graphOf(store.files)),
        hiddenIds: () => private.hiddenIds(graphOf(store.files)),
        visibility: private,
        folder: () => 'content://tree/org',
        limit: 30,
        log: MemoryAgentLog(),
        now: () => time,
        random: Random(1),
        images: ImageMaker(
          make: (prompt) async {
            drawnBy.add('mistral');
            return MadeImage(png, 'png');
          },
          model: 'mistral-medium-latest at Mistral, in the EU',
          folder: 'images',
          limit: limit,
          infographics: ownInfographics
              ? ImageModel(
                  make: (prompt) async {
                    drawnBy.add('vercel');
                    return MadeImage(png, 'png');
                  },
                  name: 'openai/gpt-image-2 at Vercel AI Gateway, outside '
                      'the EU',
                  maxPrompt: 50,
                )
              : null,
        ),
      );
    }

    const data = {
      'columns': ['Year', 'Hours'],
      'rows': [
        ['2021', 40],
        ['2022', '55'],
      ],
      'source': {'name': 'Training log', 'url': 'https://example.org/log'},
      'retrieved': '2026-10-17',
    };

    ToolCall call(Map<String, Object?> extra, {String callId = 'c1'}) =>
        ToolCall(callId, 'create_image', {
          'id': 'open',
          'prompt': 'Bar chart, 2021 40 h',
          'caption': 'Hours per year',
          ...extra,
        });

    test('infographic, illustration and no kind go to their own models',
        () async {
      final agent = make(limit: 5);
      agent.startMessage();
      final result =
          await agent.run(call({'kind': 'infographic', 'data': data}));
      expect(result, contains('Made by openai/gpt-image-2 at Vercel'));
      await agent.run(call({'kind': 'illustration'}, callId: 'c2'));
      await agent.run(call({}, callId: 'c3'));
      expect(drawnBy, ['vercel', 'mistral', 'mistral']);
      expect(await agent.run(call({'kind': 'chart'}, callId: 'c4')),
          startsWith('Error: kind must be'));
    });

    test('without "Infographics with:": the illustration model', () async {
      final agent = make(ownInfographics: false);
      agent.startMessage();
      expect(await agent.run(call({'kind': 'infographic', 'data': data})),
          contains('Made by mistral-medium-latest'));
      expect(drawnBy, ['mistral']);
    });

    test('the Org table and the source line go below the image; undo '
        'removes them with it', () async {
      final agent = make();
      agent.startMessage();
      await agent.run(call({'kind': 'infographic', 'data': data}));
      final path = imagePath('images', time, 'Open', 'png');
      expect(
          store.files['open.org'],
          '${start['open.org']}'
          '# image prompt: Bar chart, 2021 40 h\n'
          '#+caption: Hours per year\n'
          '[[file:$path]]\n'
          '\n'
          '| Year | Hours |\n'
          '|------+-------|\n'
          '| 2021 | 40    |\n'
          '| 2022 | 55    |\n'
          'Source: [[https://example.org/log][Training log]], retrieved '
          '2026-10-17\n');
      await agent.changes.undoAll(agent.writer.editor!);
      expect(store.files['open.org'], start['open.org']);
    });

    test('the result asks for a check, once more at most', () async {
      final agent = make(limit: 5);
      agent.startMessage();
      final first =
          await agent.run(call({'kind': 'infographic', 'data': data}));
      expect(first, contains('Compare every number and label'));
      expect(first, contains('make the image once more'));
      final second = await agent.run(
          call({'kind': 'infographic', 'data': data}, callId: 'c2'));
      expect(second, contains('Replaced the image of this message'));
      expect(second, contains('do not make it again'));
      // The second table replaced the first.
      expect(RegExp(r'Source:').allMatches(store.files['open.org']!),
          hasLength(1));
      expect(
          await agent.run(
              call({'kind': 'infographic', 'data': data}, callId: 'c3')),
          contains('made twice'));
      expect(drawnBy, ['vercel', 'vercel']);
    });

    test('with one image per message, the result says the limit', () async {
      final agent = make(limit: 1);
      agent.startMessage();
      expect(await agent.run(call({'kind': 'infographic', 'data': data})),
          contains('limit of 1 image for this message is reached'));
    });

    test('data is needed and checked; links stay out of the prompt',
        () async {
      final agent = make(limit: 5);
      agent.startMessage();
      Future<String> run(Map<String, Object?> extra) =>
          agent.run(call({'kind': 'infographic', ...extra}));
      expect(await run({}), contains('needs data'));
      expect(await run({'data': {...data, 'rows': []}}),
          contains('data.rows is missing'));
      expect(
          await run({
            'data': {
              ...data,
              'rows': [
                ['1', '2', '3'],
              ],
            },
          }),
          contains('more values'));
      expect(
          await run({
            'data': {
              ...data,
              'source': {'name': 'X', 'url': 'javascript:alert(1)'},
            },
          }),
          contains('must be an https:// link'));
      expect(await run({'data': {...data, 'retrieved': 'yesterday'}}),
          contains('YYYY-MM-DD'));
      expect(
          await run({
            'data': {
              ...data,
              'source': {'name': 'X', 'url': 'id:diary'},
            },
          }),
          contains('no notes you may see'));
      expect(
          await run({'data': data, 'prompt': 'Chart, source www.ecb.eu'}),
          contains('the prompt has a link'));
      expect(await run({'data': data, 'prompt': 'x' * 51}),
          contains('at most 50'));
      expect(drawnBy, isEmpty);
      expect(store.files['open.org'], start['open.org']);
    });

    test('the tool description has the brief rules and "no links"', () {
      final tool = make().tools.last;
      final text = tool.description;
      expect(text, contains('kind "infographic" by openai/gpt-image-2'));
      expect(text, contains('kind "illustration" (the default) is drawn by '
          'mistral-medium-latest'));
      expect(text, contains('Use "infographic" for anything with numbers, '
          'labels or text'));
      expect(text, contains('do the research first'));
      expect(text, contains('layout brief: the title, the exact values with '
          'units and dates, the chart form, the labels, the colours, and a '
          'source line naming the source and the date the data was read'));
      expect(text, contains('No links and no running text in the prompt'));
      final properties = (tool.parameters['properties'] as Map);
      expect((properties['kind'] as Map)['enum'],
          ['illustration', 'infographic']);
      expect((properties['data'] as Map)['required'],
          ['columns', 'rows', 'source', 'retrieved']);
    });
  });

  test("today's date goes into the system prompt", () {
    expect(withToday('Prompt.', DateTime(2026, 3, 4)),
        'Prompt. Today is 2026-03-04.');
  });

  test('the setting: one image per message by default, saved', () {
    expect(const AiSettings().maxImagesPerMessage, 1);
    final saved = jsonDecode(jsonEncode(
        const AiSettings(maxImagesPerMessage: 3).toJson()));
    expect(AiSettings.fromJson(saved).maxImagesPerMessage, 3);
    expect(AiSettings.fromJson({'maxImagesPerMessage': 0}).maxImagesPerMessage,
        1);
  });

  group('the image goes back to the model', () {
    final graph = graphOf(notes);
    RoamTools tools() => RoamTools(graph,
        readNote: (path) async => notes[path],
        visibility: const AiVisibility({'private'}));
    const image = ToolImage([1, 2, 3], 'image/png');
    final b64 = base64Encode([1, 2, 3]);

    ChatSession session(ProviderConfig config, FakeServer server) =>
        ChatSession(
          tools: tools(),
          config: config,
          post: server.post,
          handlers: {'create_image': (call) async => 'Added the image.'},
          toolImage: (call) => call.name == 'create_image' ? image : null,
        );

    Map<String, Object?> anthropicCall() => anthropicReply([
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'create_image',
            'input': {'id': 'plan', 'prompt': 'x', 'caption': 'y'},
          },
        ], stop: 'tool_use');

    Map<String, Object?> openAiCall() => openAiReply({
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'create_image',
                'arguments': '{"id":"plan","prompt":"x","caption":"y"}',
              },
            },
          ],
        }, finish: 'tool_calls');

    test('Anthropic: in the tool result, for the current message only',
        () async {
      final server = FakeServer([
        anthropicCall(),
        anthropicReply([
          {'type': 'text', 'text': 'Done.'},
        ]),
        anthropicReply([
          {'type': 'text', 'text': 'Fine.'},
        ]),
      ]);
      final chat = session(anthropic, server);
      await chat.send('Make an image');
      final result = (server.requests[1].body['messages'] as List)[2]['content']
          [0] as Map;
      expect(result['type'], 'tool_result');
      expect(result['content'], [
        {'type': 'text', 'text': 'Added the image.'},
        {
          'type': 'image',
          'source': {'type': 'base64', 'media_type': 'image/png', 'data': b64},
        },
      ]);
      expect(chat.transcript.whereType<ToolResults>().single.results.single
          .image, image);

      await chat.send('Thanks');
      expect(jsonEncode(server.requests[2].body), isNot(contains(b64)));
    });

    test('OpenAI-style: in a message after the tool results', () async {
      final server = FakeServer([
        openAiCall(),
        openAiReply({'role': 'assistant', 'content': 'Done.'}),
      ]);
      await session(deepseek, server).send('Make an image');
      final messages = server.requests[1].body['messages'] as List;
      expect(messages[3], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'Added the image.',
      });
      expect(messages[4]['role'], 'user');
      expect(messages[4]['content'][1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,$b64'},
      });
    });

    test('a model that takes no images: sent again once without it',
        () async {
      final server = FakeServer([
        openAiCall(),
        const HttpReply(400, '{"error": {"message": "image input not '
            'supported"}}'),
        openAiReply({'role': 'assistant', 'content': 'Done.'}),
      ]);
      final chat = session(deepseek, server);
      await chat.send('Make an image');
      expect(server.requests, hasLength(3));
      final messages = server.requests[2].body['messages'] as List;
      expect(messages, hasLength(4));
      expect(messages[3]['content'], contains(imageNotShown));
      expect((chat.transcript.last as AssistantMessage).text, 'Done.');
    });

    test('another error is not hidden by the retry', () async {
      final server = FakeServer([
        openAiCall(),
        const HttpReply(429, '{"error": {"message": "slow down"}}'),
      ]);
      await expectLater(session(deepseek, server).send('Make an image'),
          throwsA(isA<AiError>().having((e) => e.status, 'status', 429)));
      expect(server.requests, hasLength(2));
    });
  });
}
