import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:roam_graph_mobile/ai/agent_tools.dart';
import 'package:roam_graph_mobile/ai/ai_chat.dart';
import 'package:roam_graph_mobile/ai/ai_visibility.dart';
import 'package:roam_graph_mobile/ai/chart.dart';
import 'package:roam_graph_mobile/capture/capture_screen.dart';
import 'package:roam_graph_mobile/edit/agent_changes.dart';
import 'package:roam_graph_mobile/edit/image_screen.dart';
import 'package:roam_graph_mobile/edit/note_editor.dart';

import '../edit/note_editor_test.dart' show MemoryNoteStore;
import 'ai_visibility_test.dart' show graphOf, notes;

/// Synthetic notes: the shared ones, and one with nothing hidden.
final start = {
  ...notes,
  'open.org': ':PROPERTIES:\n:ID: open\n:END:\n#+title: Open\n'
      'Synthetic rates.\n',
};

Map<String, Object?> chartArgs({
  String id = 'open',
  String type = 'line',
  List<Map<String, Object?>>? points,
  List<Map<String, Object?>>? marks,
}) =>
    {
      'id': id,
      'type': type,
      'title': 'Synthetic rate',
      'x_label': 'Month',
      'y_label': 'Rate (%)',
      'series': [
        {
          'name': 'Rate',
          'points': points ??
              [
                {'x': '2025-01', 'y': 4.5},
                {'x': '2025-02', 'y': 4.25},
                {'x': '2025-03', 'y': 4},
                {'x': '2025-04', 'y': 3.75},
              ],
        },
      ],
      'source': {'name': 'Example Bank', 'url': 'https://example.org/r'},
      'retrieved': '2026-10-20',
      'caption': 'The synthetic rate',
      'marks': ?marks,
    };

Future<ui.Image> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

void main() {
  const private = AiVisibility({'private'});
  final time = DateTime(2026, 10, 17, 12);

  group('ChartSpec', () {
    String? refused(Map<String, Object?> args) {
      try {
        ChartSpec.from(args);
      } on Object catch (e) {
        return '$e';
      }
      return null;
    }

    test('valid arguments give the series and the table', () {
      final spec = ChartSpec.from(chartArgs());
      expect(spec.xIsDate, isTrue);
      expect(spec.xs, ['2025-01', '2025-02', '2025-03', '2025-04']);
      expect(spec.data.columns, ['Month', 'Rate']);
      expect(spec.data.rows[2], ['2025-03', '4']);
      expect(spec.data.rows[1], ['2025-02', '4.25']);
    });

    test('dates are sorted; categories keep their order', () {
      final dates = ChartSpec.from(chartArgs(points: [
        {'x': '2025-03-01', 'y': 3},
        {'x': '2025-01', 'y': 1},
        {'x': '2025-02-15', 'y': 2},
      ]));
      expect(dates.xs, ['2025-01', '2025-02-15', '2025-03-01']);
      final categories = ChartSpec.from(chartArgs(type: 'bar', points: [
        {'x': 'Beta', 'y': 3},
        {'x': 'Alpha', 'y': 1},
      ]));
      expect(categories.xIsDate, isFalse);
      expect(categories.xs, ['Beta', 'Alpha']);
    });

    test('a mark takes its y from the series', () {
      final spec = ChartSpec.from(chartArgs(marks: [
        {'x': '2025-03', 'label': 'rate cut'},
      ]));
      expect(spec.marks.single.y, 4);
      expect(spec.marks.single.label, 'rate cut');
      expect(spec.marks.single.series, 0);
    });

    test('bad input is refused with a clear message', () {
      expect(refused(chartArgs(points: [])), contains('has no points'));
      expect(refused(chartArgs()..['series'] = []), contains('series is missing'));
      expect(
          refused(chartArgs(points: [
            {'x': '2025-01', 'y': 'high'},
          ])),
          contains('y must be a number'));
      expect(
          refused(chartArgs(points: [
            {'x': '2025-01', 'y': 1},
            {'x': 'Q2', 'y': 2},
          ])),
          contains('mixes dates and categories'));
      expect(
          refused(chartArgs(points: [
            {'x': '2025-13', 'y': 1},
            {'x': '2025-01', 'y': 2},
          ])),
          contains('mixes dates and categories'));
      expect(
          refused(chartArgs(points: [
            {'x': '2025-01', 'y': 1},
            {'x': '2025-01', 'y': 2},
          ])),
          contains('twice'));
      expect(
          refused(chartArgs(points: [
            {'x': '2025-01', 'y': 1},
            {'x': '2025-01-01', 'y': 2},
          ])),
          contains('same date'));
      expect(refused(chartArgs(type: 'pie')), contains('type must be'));
      expect(refused(chartArgs()..['title'] = ''), contains('title is missing'));
      expect(refused(chartArgs()..['source'] = {'name': 'A', 'url': 'x'}),
          contains('source.url'));
      expect(refused(chartArgs()..['retrieved'] = '20 Oct'),
          contains('retrieved'));
      expect(
          refused(chartArgs(marks: [
            {'x': '1999-01', 'label': 'nowhere'},
          ])),
          contains('mark'));
    });
  });

  group('axis', () {
    test('a nice step and ticks', () {
      expect(niceStep(10), 2);
      expect(niceStep(0.5), 0.1);
      final axis = yAxis(3.7, 4.6, fromZero: false);
      expect(axis.first, lessThanOrEqualTo(3.7));
      expect(axis.first + axis.step * (axis.count - 1),
          greaterThanOrEqualTo(4.6));
      final bars = yAxis(12, 95, fromZero: true);
      expect(bars.first, 0);
    });

    test('equal values still give an axis', () {
      final axis = yAxis(5, 5, fromZero: false);
      expect(axis.count, greaterThan(1));
    });
  });

  group('renderChart', () {
    for (final type in ['line', 'bar', 'area']) {
      test('$type: a PNG of the expected size with something drawn', () async {
        final spec = ChartSpec.from(chartArgs(type: type, marks: [
          {'x': '2025-03', 'label': 'rate cut'},
        ]));
        final bytes = await renderChart(spec);
        final image = await decode(bytes);
        expect(image.width, chartWidth);
        expect(image.height, chartHeight);
        final data = (await image.toByteData())!;
        // The corner is the white background; something else is drawn.
        expect(data.getUint32(0), 0xFFFFFFFF);
        var drawn = 0;
        for (var i = 0; i < data.lengthInBytes; i += 4 * 97) {
          if (data.getUint32(i) != 0xFFFFFFFF) drawn++;
        }
        expect(drawn, greaterThan(50));
      });
    }

    test('two series with a gap, in the first series colour', () async {
      final spec = ChartSpec.from({
        ...chartArgs(type: 'line'),
        'series': [
          {
            'name': 'A',
            'points': [
              {'x': 'a', 'y': -2},
              {'x': 'b', 'y': 3},
              {'x': 'c', 'y': 5},
            ],
          },
          {
            'name': 'B',
            'points': [
              {'x': 'a', 'y': 1},
              {'x': 'c', 'y': 2},
            ],
          },
        ],
      });
      final image = await decode(await renderChart(spec));
      final data = (await image.toByteData())!;
      var blue = 0;
      for (var i = 0; i < data.lengthInBytes; i += 4) {
        // The first default colour, 0xFF1F6FB2, as RGBA.
        if (data.getUint32(i) == 0x1F6FB2FF) blue++;
      }
      expect(blue, greaterThan(100));
    });
  });

  group('create_chart', () {
    late MemoryNoteStore store;
    late Map<String, Uint8List> files;
    late MemoryAgentLog log;

    AgentWriter make({int limit = 1, String? folder = 'images'}) {
      store = MemoryNoteStore(Map.of(start));
      files = {};
      log = MemoryAgentLog();
      return AgentWriter(
        writer: NoteWriter(
          create: (name, text) async => Created(name),
          allowWriting: () async {},
          editor: NoteEditor(store: store, history: MemoryEditHistory()),
          createFile: (path, bytes) async {
            if (files.containsKey(path)) return const FileExists();
            files[path] = bytes;
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
        chartFolder: folder,
        chartLimit: limit,
      );
    }

    ToolCall call(Map<String, Object?> args, {String callId = 'c1'}) =>
        ToolCall(callId, 'create_chart', args);

    test('the chart, the table and the source go below the note; undo '
        'removes them', () async {
      final agent = make();
      agent.startMessage(prompt: 'Chart the rate');
      final result = await agent.run(call(chartArgs()));
      final path = imagePath('images', time, 'Open', 'png');
      expect(result, contains('Added the chart to "Open"'));
      expect(files.keys, [path]);
      final image = await decode(files[path]!);
      expect(image.width, chartWidth);
      expect(store.files['open.org'], '${start['open.org']}'
          '#+caption: The synthetic rate\n'
          '[[file:$path]]\n'
          '\n'
          '| Month   | Rate |\n'
          '|---------+------|\n'
          '| 2025-01 | 4.5  |\n'
          '| 2025-02 | 4.25 |\n'
          '| 2025-03 | 4    |\n'
          '| 2025-04 | 3.75 |\n'
          'Source: [[https://example.org/r][Example Bank]], '
          'retrieved 2026-10-20\n');
      expect(agent.changes.changes.single.tool, 'create_chart');
      expect(log.entries.single.tool, 'create_chart');
      expect(agent.imageFor(const ToolCall('c1', 'create_chart', {}))?.bytes,
          files[path]);

      await agent.changes.undoAll(agent.writer.editor!);
      expect(store.files['open.org'], start['open.org']);
    });

    test('the limit counts, and a second chart replaces the first', () async {
      final agent = make();
      agent.startMessage();
      await agent.run(call(chartArgs()));
      expect(await agent.run(call(chartArgs(), callId: 'c2')),
          startsWith('Error: the limit of 1 chart'));
      final two = make(limit: 2);
      two.startMessage();
      await two.run(call(chartArgs()));
      final result = await two.run(call(
          chartArgs(points: [
            {'x': '2025-01', 'y': 9},
          ]),
          callId: 'c2'));
      expect(result, contains('Replaced the chart of this message'));
      final text = store.files['open.org']!;
      expect(RegExp(r'#\+caption:').allMatches(text), hasLength(1));
      expect(text, contains('| 2025-01 | 9    |'));
      expect(text, isNot(contains('4.25')));
      // A new message may make one again.
      two.startMessage();
      expect(await two.run(call(chartArgs(id: 'plan'), callId: 'c3')),
          contains('Added the chart to "Plan"'));
    });

    test('bad input changes nothing and does not count', () async {
      final agent = make();
      agent.startMessage();
      expect(await agent.run(call(chartArgs(points: []))),
          startsWith('Error: the series "Rate" has no points'));
      expect(store.files['open.org'], start['open.org']);
      expect(files, isEmpty);
      expect(await agent.run(call(chartArgs(), callId: 'c2')),
          contains('Added the chart'));
    });

    test('a hidden note gets no chart', () async {
      final agent = make();
      agent.startMessage();
      final result = await agent.run(call(chartArgs(id: 'diary')));
      expect(result, startsWith('Error: There is no note with the ID diary'));
      expect(files, isEmpty);
    });

    test('the tool is offered only where charts can be saved', () {
      expect(make().tools.map((t) => t.name), contains('create_chart'));
      expect(make(folder: null).tools.map((t) => t.name),
          isNot(contains('create_chart')));
      final tool = make().tools.last;
      expect(tool.description, contains('exact data'));
      expect(tool.description, contains('kind "infographic"'));
    });
  });
}
