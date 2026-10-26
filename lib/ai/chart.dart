/// Exact charts from data, drawn by the app (#184): the agent's
/// `create_chart` gives the values; this file checks them and draws the
/// picture with `dart:ui`, off screen, so every value is the one given and
/// no image model is asked.
library;

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' hide TextStyle;

import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle;

import '../capture/new_node.dart';
import 'agent_tools.dart' show InfographicData;
import 'ai_tools.dart' show ToolError;

/// The forms `create_chart` draws.
enum ChartType { line, bar, area }

/// One value of a series: [x] as the AI wrote it, a date or a category.
class ChartPoint {
  const ChartPoint(this.x, this.y);

  final String x;
  final double y;
}

class ChartSeries {
  const ChartSeries(this.name, this.points);

  final String name;
  final List<ChartPoint> points;
}

/// A labelled point, for example "rate cut".
class ChartMark {
  const ChartMark(this.x, this.y, this.label, {this.series});

  final String x;
  final double y;
  final String label;

  /// The index of the series the value came from; null when the mark gave
  /// its own y. A bar chart puts the mark on that series' bar.
  final int? series;
}

/// The checked arguments of `create_chart`.
class ChartSpec {
  const ChartSpec({
    required this.type,
    required this.title,
    required this.xLabel,
    required this.yLabel,
    required this.series,
    required this.xs,
    required this.xIsDate,
    required this.marks,
    required this.caption,
    required this.data,
  });

  /// The most series and points per series.
  static const maxSeries = 6, maxPoints = InfographicData.maxRows;

  final ChartType type;
  final String title, xLabel, yLabel, caption;
  final List<ChartSeries> series;

  /// Every x of every series, once, in the order of the axis: by date for
  /// dates, as first written for categories.
  final List<String> xs;
  final bool xIsDate;
  final List<ChartMark> marks;

  /// The table and the source line for the note.
  final InfographicData data;

  /// `YYYY-MM-DD` or `YYYY-MM` as a date (the first day of the month); null
  /// when [text] is no real date.
  static DateTime? parseDate(String text) {
    final m = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$').firstMatch(text);
    if (m == null) return null;
    final year = int.parse(m[1]!);
    final month = int.parse(m[2]!);
    final day = m[3] == null ? 1 : int.parse(m[3]!);
    final date = DateTime.utc(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  /// A value as written in the table: no ".0" for whole numbers.
  static String number(double value) =>
      value == value.roundToDouble() && value.abs() < 1e15
          ? value.round().toString()
          : '$value';

  /// [json], the tool's arguments, checked; a [ToolError] says what is
  /// wrong.
  factory ChartSpec.from(Map<String, Object?> json) {
    String text(String key, {bool required = true}) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) return oneLine(value);
      if (required) throw ToolError('$key is missing.');
      return '';
    }

    final type = switch (json['type']) {
      'line' => ChartType.line,
      'bar' => ChartType.bar,
      'area' => ChartType.area,
      _ => throw const ToolError('type must be "line", "bar" or "area".'),
    };
    final title = text('title');
    final xLabel = text('x_label', required: false);
    final yLabel = text('y_label', required: false);
    final caption = text('caption', required: false);

    final rawSeries = json['series'];
    if (rawSeries is! List || rawSeries.isEmpty) {
      throw const ToolError('series is missing: give at least one series '
          'with a name and points.');
    }
    if (rawSeries.length > maxSeries) {
      throw const ToolError('more than $maxSeries series; keep the chart '
          'readable.');
    }
    final series = <ChartSeries>[];
    var dates = 0, categories = 0;
    for (final raw in rawSeries) {
      if (raw is! Map) throw const ToolError('each series must be an object.');
      final name = raw['name'] is String ? oneLine(raw['name'] as String) : '';
      if (name.isEmpty) throw const ToolError('each series needs a name.');
      final rawPoints = raw['points'];
      if (rawPoints is! List || rawPoints.isEmpty) {
        throw ToolError('the series "$name" has no points.');
      }
      if (rawPoints.length > maxPoints) {
        throw ToolError('the series "$name" has more than $maxPoints points; '
            'keep the chart small.');
      }
      final seen = <String>{};
      final points = <ChartPoint>[];
      for (final point in rawPoints) {
        if (point is! Map) {
          throw ToolError('each point of "$name" must be {x, y}.');
        }
        final x = point['x'] is String
            ? oneLine(point['x'] as String)
            : point['x'] is num
                ? '${point['x']}'
                : '';
        if (x.isEmpty) throw ToolError('a point of "$name" has no x.');
        final y = point['y'];
        if (y is! num || !y.isFinite) {
          throw ToolError('y must be a number; the point $x of "$name" has '
              '${y is String ? '"$y"' : '$y'}.');
        }
        if (!seen.add(x)) {
          throw ToolError('the series "$name" has x "$x" twice.');
        }
        if (parseDate(x) == null) {
          categories++;
        } else {
          dates++;
        }
        points.add(ChartPoint(x, y.toDouble()));
      }
      series.add(ChartSeries(name, points));
    }
    if (dates > 0 && categories > 0) {
      throw const ToolError('x mixes dates and categories; use only dates '
          '(YYYY-MM-DD or YYYY-MM) or only categories.');
    }
    final xIsDate = dates > 0;
    final xs = <String>[];
    for (final s in series) {
      for (final p in s.points) {
        if (!xs.contains(p.x)) xs.add(p.x);
      }
    }
    if (xIsDate) {
      xs.sort((a, b) {
        final byDate = parseDate(a)!.compareTo(parseDate(b)!);
        return byDate != 0 ? byDate : a.compareTo(b);
      });
      for (var i = 1; i < xs.length; i++) {
        if (parseDate(xs[i])! == parseDate(xs[i - 1])!) {
          throw ToolError('x "${xs[i - 1]}" and "${xs[i]}" are the same '
              'date; write each date the same way.');
        }
      }
    }

    final marks = <ChartMark>[];
    final rawMarks = json['marks'];
    if (rawMarks != null) {
      if (rawMarks is! List) throw const ToolError('marks must be a list.');
      if (rawMarks.length > 8) {
        throw const ToolError('at most 8 marks.');
      }
      for (final raw in rawMarks) {
        if (raw is! Map) {
          throw const ToolError('each mark must be {x, label}.');
        }
        final x = raw['x'] is String ? oneLine(raw['x'] as String) : '';
        final label =
            raw['label'] is String ? oneLine(raw['label'] as String) : '';
        if (label.isEmpty || !xs.contains(x)) {
          throw ToolError('a mark needs a label and an x that is one of the '
              'points ("$x" is not).');
        }
        double? y;
        int? from;
        if (raw['y'] is num && (raw['y'] as num).isFinite) {
          y = (raw['y'] as num).toDouble();
        } else if (raw['y'] != null) {
          throw ToolError('the y of the mark "$label" must be a number.');
        } else {
          for (var i = 0; i < series.length && y == null; i++) {
            for (final p in series[i].points) {
              if (p.x == x) {
                y = p.y;
                from = i;
              }
            }
          }
        }
        marks.add(ChartMark(x, y!, label, series: from));
      }
    }

    // The source, as the infographic's data has it.
    final source = json['source'];
    final sourceName = source is Map && source['name'] is String
        ? InfographicData.tableCell(source['name'] as String)
        : '';
    final sourceUrl = source is Map && source['url'] is String
        ? (source['url'] as String).trim()
        : '';
    if (sourceName.isEmpty || sourceUrl.isEmpty) {
      throw const ToolError('source needs a name and a url.');
    }
    if (!RegExp(r'^(https?://|id:)[^\s\[\]]+$').hasMatch(sourceUrl)) {
      throw const ToolError('source.url must be an https:// link, or '
          'id:<ID> for a note.');
    }
    final retrieved =
        json['retrieved'] is String ? (json['retrieved'] as String).trim() : '';
    if (parseDate(retrieved) == null || retrieved.length != 10) {
      throw const ToolError('retrieved must be the date the data was read, '
          'as YYYY-MM-DD.');
    }

    final columns = [
      InfographicData.tableCell(xLabel.isEmpty ? 'x' : xLabel),
      for (final s in series) InfographicData.tableCell(s.name),
    ];
    final rows = <List<String>>[
      for (final x in xs)
        [
          InfographicData.tableCell(x),
          for (final s in series)
            () {
              for (final p in s.points) {
                if (p.x == x) return number(p.y);
              }
              return '';
            }(),
        ],
    ];
    if (rows.length > InfographicData.maxRows) {
      throw const ToolError('the chart has more than '
          '${InfographicData.maxRows} different x values; keep it small.');
    }
    return ChartSpec(
      type: type,
      title: title,
      xLabel: xLabel,
      yLabel: yLabel,
      series: series,
      xs: xs,
      xIsDate: xIsDate,
      marks: marks,
      caption: caption,
      data: InfographicData(
        columns: columns,
        rows: rows,
        sourceName: sourceName,
        sourceUrl: sourceUrl,
        retrieved: retrieved,
      ),
    );
  }
}

/// The colours of the series when the theme gives none.
const defaultChartColors = [
  Color(0xFF1F6FB2),
  Color(0xFFD9822B),
  Color(0xFF3A9D5D),
  Color(0xFFB0413E),
  Color(0xFF7A5BB5),
  Color(0xFF3D8E96),
];

/// The size of a chart picture.
const chartWidth = 1600, chartHeight = 1000;

/// A step for an axis with about five intervals: 1, 2, 5 times a power of
/// ten.
double niceStep(double range) {
  final raw = range / 5;
  final magnitude = pow(10, (log(raw) / ln10).floor()).toDouble();
  final fraction = raw / magnitude;
  final nice = fraction <= 1
      ? 1
      : fraction <= 2
          ? 2
          : fraction <= 5
              ? 5
              : 10;
  return nice * magnitude;
}

/// The y axis for values from [low] to [high]: the first tick, the step
/// and the number of ticks. Bars and areas start at or below zero.
({double first, double step, int count}) yAxis(double low, double high,
    {required bool fromZero}) {
  var lo = fromZero ? min(low, 0.0) : low;
  var hi = fromZero ? max(high, 0.0) : high;
  if (hi == lo) {
    final pad = lo == 0 ? 1.0 : lo.abs() * 0.1;
    lo -= fromZero && lo == 0 ? 0.0 : pad;
    hi += pad;
  }
  final step = niceStep(hi - lo);
  final first = (lo / step).floor() * step;
  final last = (hi / step).ceil() * step;
  return (first: first, step: step, count: ((last - first) / step).round() + 1);
}

String _tick(double value, double step) {
  final decimals = step >= 1 ? 0 : min(6, max(0, (-log(step) / ln10).ceil()));
  final text = value.toStringAsFixed(decimals);
  return text.startsWith('-') && double.parse(text) == 0
      ? text.substring(1)
      : text;
}

TextPainter _text(String text, double size,
    {Color color = const Color(0xFF222222),
    bool bold = false,
    double? width,
    int lines = 1}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: lines,
    ellipsis: '…',
  );
  painter.layout(maxWidth: width ?? double.infinity);
  return painter;
}

/// Draws [spec] at [chartWidth] x [chartHeight] on white, and returns the
/// PNG file. [colors] are the series' colours, from the theme.
Future<Uint8List> renderChart(ChartSpec spec,
    {List<Color> colors = defaultChartColors}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder,
      Rect.fromLTWH(0, 0, chartWidth.toDouble(), chartHeight.toDouble()));
  _draw(canvas, spec, colors.isEmpty ? defaultChartColors : colors);
  final picture = recorder.endRecording();
  final image = await picture.toImage(chartWidth, chartHeight);
  try {
    final data = await image.toByteData(format: ImageByteFormat.png);
    if (data == null) throw const ToolError('the chart could not be drawn.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void _draw(Canvas canvas, ChartSpec spec, List<Color> colors) {
  const ink = Color(0xFF222222);
  const grey = Color(0xFF666666);
  const gridColor = Color(0xFFDDDDDD);
  final w = chartWidth.toDouble(), h = chartHeight.toDouble();
  canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFFFFFFF));

  // The title, the legend, and the footer.
  final title = _text(spec.title, 44, bold: true, width: w - 120, lines: 2);
  title.paint(canvas, const Offset(60, 24));
  var top = 24 + title.height + 16;
  if (spec.series.length > 1) {
    var x = 60.0;
    var y = top;
    for (var i = 0; i < spec.series.length; i++) {
      final name = _text(spec.series[i].name, 28, width: 420);
      if (x + 40 + name.width > w - 60) {
        x = 60;
        y += 40;
      }
      canvas.drawRect(Rect.fromLTWH(x, y + 6, 24, 24),
          Paint()..color = colors[i % colors.length]);
      name.paint(canvas, Offset(x + 34, y));
      x += 34 + name.width + 36;
    }
    top = y + 52;
  } else {
    top += 10;
  }
  final footer = _text(
      'Source: ${spec.data.sourceName}, retrieved ${spec.data.retrieved}', 24,
      color: grey, width: w - 120);
  footer.paint(canvas, Offset(60, h - 24 - footer.height));

  // The plot area: room for the y labels on the left, and the x labels and
  // the x axis label below.
  const left = 170.0;
  final right = w - 60;
  final bottom = h - 24 - footer.height - 24 - 40 - 20 - 50;
  final plot = Rect.fromLTRB(left, top, right, bottom);

  final fromZero = spec.type != ChartType.line;
  var low = double.infinity, high = -double.infinity;
  for (final s in spec.series) {
    for (final p in s.points) {
      low = min(low, p.y);
      high = max(high, p.y);
    }
  }
  for (final m in spec.marks) {
    low = min(low, m.y);
    high = max(high, m.y);
  }
  final axis = yAxis(low, high, fromZero: fromZero);
  final axisLow = axis.first;
  final axisHigh = axis.first + axis.step * (axis.count - 1);
  double yOf(double value) =>
      plot.bottom - (value - axisLow) / (axisHigh - axisLow) * plot.height;

  final line = Paint()
    ..color = gridColor
    ..strokeWidth = 2;
  for (var i = 0; i < axis.count; i++) {
    final value = axis.first + axis.step * i;
    final y = yOf(value);
    canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), line);
    final label = _text(_tick(value, axis.step), 26, color: grey);
    label.paint(
        canvas, Offset(plot.left - 14 - label.width, y - label.height / 2));
  }
  if (spec.yLabel.isNotEmpty) {
    final label = _text(spec.yLabel, 28, width: plot.height);
    canvas.save();
    canvas.translate(40, plot.top + (plot.height + label.width) / 2);
    canvas.rotate(-pi / 2);
    label.paint(canvas, Offset.zero);
    canvas.restore();
  }

  // Positions along x. Bars always sit in bands; lines and areas with
  // dates sit by time.
  final count = spec.xs.length;
  final byTime = spec.xIsDate && spec.type != ChartType.bar && count > 1;
  final times = [
    for (final x in spec.xs)
      if (spec.xIsDate) ChartSpec.parseDate(x)!.millisecondsSinceEpoch,
  ];
  double xOf(String x) {
    final index = spec.xs.indexOf(x);
    if (byTime) {
      final span = times.last - times.first;
      if (span == 0) return plot.left + plot.width / 2;
      return plot.left +
          (times[index] - times.first) / span * (plot.width - 40) +
          20;
    }
    return plot.left + (index + 0.5) / count * plot.width;
  }

  final axisPaint = Paint()
    ..color = ink
    ..strokeWidth = 3;
  canvas.drawLine(
      Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), axisPaint);
  if (axisLow < 0) {
    canvas.drawLine(Offset(plot.left, yOf(0)), Offset(plot.right, yOf(0)),
        Paint()
          ..color = grey
          ..strokeWidth = 2);
  }

  // The x labels: all of them when they fit, else about every k-th.
  final labelSlots = max(1, min(count, (plot.width / 150).floor()));
  final every = (count / labelSlots).ceil();
  final slotWidth = every * plot.width / count;
  for (var i = 0; i < count; i += every) {
    final label = _text(spec.xs[i], 24,
        color: grey, width: max(60.0, min(slotWidth - 8, 200.0)));
    final x = xOf(spec.xs[i]);
    label.paint(canvas,
        Offset(x - label.width / 2, plot.bottom + 12));
    canvas.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 8),
        axisPaint);
  }
  if (spec.xLabel.isNotEmpty) {
    final label = _text(spec.xLabel, 28, width: plot.width);
    label.paint(canvas,
        Offset(plot.left + (plot.width - label.width) / 2, plot.bottom + 12 + 34 + 16));
  }

  // The series.
  final n = spec.series.length;
  for (var i = 0; i < n; i++) {
    final color = colors[i % colors.length];
    final points = spec.series[i].points;
    if (spec.type == ChartType.bar) {
      final band = plot.width / count;
      final barWidth = band * 0.8 / n;
      for (final p in points) {
        final x = plot.left +
            spec.xs.indexOf(p.x) * band +
            band * 0.1 +
            barWidth * i;
        canvas.drawRect(
            Rect.fromPoints(Offset(x, yOf(p.y)), Offset(x + barWidth, yOf(0))),
            Paint()..color = color);
      }
      continue;
    }
    // Runs of consecutive x values; a missing value breaks the line.
    final runs = <List<ChartPoint>>[];
    var run = <ChartPoint>[];
    int? last;
    final byX = {for (final p in points) p.x: p};
    for (var k = 0; k < count; k++) {
      final p = byX[spec.xs[k]];
      if (p == null) continue;
      if (last != null && k != last + 1) {
        runs.add(run);
        run = [];
      }
      run.add(p);
      last = k;
    }
    if (run.isNotEmpty) runs.add(run);
    for (final r in runs) {
      final path = Path()..moveTo(xOf(r.first.x), yOf(r.first.y));
      for (final p in r.skip(1)) {
        path.lineTo(xOf(p.x), yOf(p.y));
      }
      if (spec.type == ChartType.area) {
        final fill = Path.from(path)
          ..lineTo(xOf(r.last.x), yOf(max(0.0, axisLow)))
          ..lineTo(xOf(r.first.x), yOf(max(0.0, axisLow)))
          ..close();
        canvas.drawPath(fill, Paint()..color = color.withAlpha(70));
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round);
    }
    if (points.length <= 40) {
      for (final p in points) {
        canvas.drawCircle(
            Offset(xOf(p.x), yOf(p.y)), 7, Paint()..color = color);
      }
    }
  }

  // The marks: a ring on the point and its label above, kept inside.
  for (final m in spec.marks) {
    // On a bar chart, the middle of the bar the value belongs to.
    final band = plot.width / count;
    final x = spec.type == ChartType.bar
        ? plot.left +
            spec.xs.indexOf(m.x) * band +
            band * 0.1 +
            (m.series case final from?
                ? band * 0.8 / n * (from + 0.5)
                : band * 0.4)
        : xOf(m.x);
    final y = yOf(m.y);
    canvas.drawCircle(
        Offset(x, y),
        13,
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4);
    final label = _text(m.label, 26, bold: true, width: 360);
    final boxWidth = label.width + 20, boxHeight = label.height + 12;
    final boxLeft = (x - boxWidth / 2).clamp(plot.left, plot.right - boxWidth).toDouble();
    final boxTop = max(plot.top, y - 24 - boxHeight);
    final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(boxLeft, boxTop, boxWidth, boxHeight),
        const Radius.circular(8));
    canvas.drawRRect(box, Paint()..color = const Color(0xE6FFFFFF));
    canvas.drawRRect(
        box,
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    label.paint(canvas, Offset(boxLeft + 10, boxTop + 6));
  }
}
